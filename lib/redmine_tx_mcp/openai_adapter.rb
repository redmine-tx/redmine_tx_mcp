require 'net/http'
require 'json'
require 'uri'
require 'securerandom'

module RedmineTxMcp
  class OpenaiAdapter
    class << self
      # Accepts an Anthropic-format request body and returns an Anthropic-format response hash.
      # Internally converts to OpenAI format, calls the endpoint, and converts back.
      # Non-streaming call: waits for full response.
      def call(anthropic_request, api_key: nil, endpoint_url:)
        openai_body = convert_request(anthropic_request)

        uri = URI(endpoint_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = 30
        http.read_timeout = 120

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{api_key}" if api_key.present?
        request.body = JSON.generate(openai_body)

        Rails.logger.debug "[OpenaiAdapter] Request: #{openai_body.inspect}"

        response = http.request(request)

        unless response.code == '200'
          Rails.logger.error "[OpenaiAdapter] API Error: #{response.code} - #{response.body}"
          raise "OpenAI-compatible API Error: #{response.code} - #{response.body}"
        end

        openai_response = JSON.parse(response.body)
        convert_response(openai_response)
      end

      # Streaming call: uses stream=true, yields :chunk events as tokens arrive,
      # then returns the final assembled Anthropic-format response.
      #
      # Usage:
      #   result = OpenaiAdapter.call_streaming(req, endpoint_url: url) do |event|
      #     # event = { type: :chunk } — a new token arrived (for keep-alive / progress)
      #   end
      def call_streaming(anthropic_request, api_key: nil, endpoint_url:, &block)
        openai_body = convert_request(anthropic_request).merge(stream: true)

        uri = URI(endpoint_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = 30
        http.read_timeout = 300

        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{api_key}" if api_key.present?
        request.body = JSON.generate(openai_body)

        Rails.logger.debug "[OpenaiAdapter] Streaming request: model=#{openai_body[:model]}"

        # Accumulators for assembling the final response
        content_text = +""
        reasoning_text = +""
        tool_calls_map = {}  # index → { id:, name:, arguments: }
        finish_reason = nil
        model = nil
        msg_id = nil

        http.request(request) do |response|
          unless response.code == '200'
            body = response.body
            Rails.logger.error "[OpenaiAdapter] Stream API Error: #{response.code} - #{body}"
            raise "OpenAI-compatible API Error: #{response.code} - #{body}"
          end

          buffer = +""
          response.read_body do |chunk|
            buffer << chunk
            while (idx = buffer.index("\n\n"))
              line = buffer.slice!(0, idx + 2).strip
              next if line.empty?
              next unless line.start_with?('data: ')

              data_str = line.sub(/\Adata: /, '')
              break if data_str == '[DONE]'

              begin
                data = JSON.parse(data_str)
                msg_id ||= data['id']
                model ||= data['model']

                choice = (data['choices'] || []).first
                next unless choice

                delta = choice['delta'] || {}
                finish_reason = choice['finish_reason'] if choice['finish_reason']

                # Accumulate text content
                content_text << delta['content'].to_s if delta['content']
                reasoning_text << delta['reasoning'].to_s if delta['reasoning']

                # Accumulate tool calls (may arrive across multiple chunks)
                if delta['tool_calls'].is_a?(Array)
                  delta['tool_calls'].each do |tc_delta|
                    tc_idx = tc_delta['index'] || 0
                    entry = (tool_calls_map[tc_idx] ||= { id: nil, name: +"", arguments: +"" })
                    entry[:id] = tc_delta['id'] if tc_delta['id']
                    if tc_delta['function']
                      entry[:name] << tc_delta['function']['name'].to_s if tc_delta['function']['name']
                      entry[:arguments] << tc_delta['function']['arguments'].to_s if tc_delta['function']['arguments']
                    end
                  end
                end

                # Notify caller that a chunk arrived (for progress indication)
                block&.call({ type: :chunk })
              rescue JSON::ParserError => e
                Rails.logger.debug "[OpenaiAdapter] Skipping unparseable chunk: #{e.message}"
              end
            end
          end
        end

        # Assemble into Anthropic-format response
        assemble_streaming_response(
          msg_id: msg_id, model: model, finish_reason: finish_reason,
          content_text: content_text, reasoning_text: reasoning_text,
          tool_calls_map: tool_calls_map
        )
      end

      private

      # ─── Anthropic request → OpenAI request ─────────────────────

      def convert_request(anthropic_req)
        messages = []

        # System message
        system_text = anthropic_req[:system] || anthropic_req['system']
        if system_text.present?
          messages << { role: 'system', content: system_text }
        end

        # Conversation messages
        src_messages = anthropic_req[:messages] || anthropic_req['messages'] || []
        src_messages.each do |msg|
          role = (msg[:role] || msg['role']).to_s
          content = msg[:content] || msg['content']

          if role == 'user' && content.is_a?(Array)
            # Tool results array → individual tool messages
            content.each do |item|
              item_type = item[:type] || item['type']
              if item_type == 'tool_result'
                tool_use_id = item[:tool_use_id] || item['tool_use_id']
                tool_content = item[:content] || item['content']
                messages << {
                  role: 'tool',
                  tool_call_id: tool_use_id,
                  content: tool_content.to_s
                }
              else
                messages << { role: 'user', content: item.to_s }
              end
            end
          elsif role == 'assistant' && content.is_a?(Array)
            # Assistant message with possible tool_use blocks
            text_parts = []
            tool_calls = []

            content.each do |block|
              block_type = block[:type] || block['type']
              if block_type == 'text'
                text_parts << (block[:text] || block['text']).to_s
              elsif block_type == 'tool_use'
                tool_id = block[:id] || block['id'] || "call_#{SecureRandom.hex(12)}"
                tool_name = block[:name] || block['name']
                tool_input = block[:input] || block['input'] || {}
                tool_calls << {
                  id: tool_id,
                  type: 'function',
                  function: {
                    name: tool_name,
                    arguments: tool_input.is_a?(String) ? tool_input : JSON.generate(tool_input)
                  }
                }
              end
            end

            assistant_msg = { role: 'assistant' }
            combined_text = text_parts.join("\n").strip
            assistant_msg[:content] = combined_text.present? ? combined_text : nil
            assistant_msg[:tool_calls] = tool_calls if tool_calls.any?
            messages << assistant_msg
          else
            messages << { role: role, content: content.to_s }
          end
        end

        # Tools
        tools = nil
        src_tools = anthropic_req[:tools] || anthropic_req['tools']
        if src_tools.present?
          tools = src_tools.map do |tool|
            name = tool[:name] || tool['name']
            description = tool[:description] || tool['description']
            schema = tool[:input_schema] || tool['input_schema'] || tool[:inputSchema] || tool['inputSchema'] || {}
            {
              type: 'function',
              function: {
                name: name,
                description: description,
                parameters: schema
              }
            }
          end
        end

        body = {
          model: anthropic_req[:model] || anthropic_req['model'],
          messages: messages,
          max_tokens: anthropic_req[:max_tokens] || anthropic_req['max_tokens'] || 4000
        }
        body[:tools] = tools if tools.present?
        body
      end

      # ─── OpenAI response → Anthropic response ──────────────────

      def convert_response(openai_resp)
        choice = (openai_resp['choices'] || []).first
        return empty_response unless choice

        message = choice['message'] || {}
        content_blocks = []

        # Text content — prefer content; fall back to reasoning (Qwen puts answers there)
        # Only use reasoning fallback when model finished normally (not truncated by token limit)
        text = message['content'].presence
        text = strip_thinking(text) if text.present?
        if text.blank? && message['reasoning'].present? && choice['finish_reason'] != 'length'
          text = strip_thinking(message['reasoning'])
        end
        if text.present?
          content_blocks << { 'type' => 'text', 'text' => text }
        end

        # Tool calls
        if message['tool_calls'].is_a?(Array)
          message['tool_calls'].each do |tc|
            func = tc['function'] || {}
            tool_id = tc['id'] || "toolu_#{SecureRandom.hex(12)}"
            arguments = func['arguments']

            parsed_args = if arguments.is_a?(String)
              begin
                JSON.parse(arguments)
              rescue JSON::ParserError
                { '_raw' => arguments }
              end
            elsif arguments.is_a?(Hash)
              arguments
            else
              {}
            end

            content_blocks << {
              'type' => 'tool_use',
              'id' => tool_id,
              'name' => func['name'],
              'input' => parsed_args
            }
          end
        end

        # Ensure at least an empty text block if nothing else
        if content_blocks.empty?
          content_blocks << { 'type' => 'text', 'text' => '' }
        end

        # Map finish_reason → stop_reason
        stop_reason = case choice['finish_reason']
                      when 'stop' then 'end_turn'
                      when 'tool_calls' then 'tool_use'
                      when 'length' then 'max_tokens'
                      else choice['finish_reason'] || 'end_turn'
                      end

        # Usage mapping
        usage = openai_resp['usage'] || {}
        anthropic_usage = {
          'input_tokens' => usage['prompt_tokens'] || 0,
          'output_tokens' => usage['completion_tokens'] || 0
        }

        {
          'id' => openai_resp['id'] || "msg_#{SecureRandom.hex(12)}",
          'type' => 'message',
          'role' => 'assistant',
          'content' => content_blocks,
          'model' => openai_resp['model'],
          'stop_reason' => stop_reason,
          'usage' => anthropic_usage
        }
      end

      def assemble_streaming_response(msg_id:, model:, finish_reason:, content_text:, reasoning_text:, tool_calls_map:)
        content_blocks = []

        # Text content — prefer content; fall back to reasoning (Qwen puts answers there)
        # Only use reasoning fallback when model finished normally (not truncated by token limit)
        text = content_text.presence
        text = strip_thinking(text) if text.present?
        if text.blank? && reasoning_text.present? && finish_reason != 'length'
          text = strip_thinking(reasoning_text)
        end
        content_blocks << { 'type' => 'text', 'text' => text } if text.present?

        # Tool calls
        tool_calls_map.sort_by { |idx, _| idx }.each do |_, tc|
          tool_id = tc[:id] || "toolu_#{SecureRandom.hex(12)}"
          parsed_args = begin
            JSON.parse(tc[:arguments])
          rescue JSON::ParserError
            tc[:arguments].present? ? { '_raw' => tc[:arguments] } : {}
          end

          content_blocks << {
            'type' => 'tool_use',
            'id' => tool_id,
            'name' => tc[:name],
            'input' => parsed_args
          }
        end

        content_blocks << { 'type' => 'text', 'text' => '' } if content_blocks.empty?

        stop_reason = case finish_reason
                      when 'stop' then 'end_turn'
                      when 'tool_calls' then 'tool_use'
                      when 'length' then 'max_tokens'
                      else finish_reason || 'end_turn'
                      end

        {
          'id' => msg_id || "msg_#{SecureRandom.hex(12)}",
          'type' => 'message',
          'role' => 'assistant',
          'content' => content_blocks,
          'model' => model,
          'stop_reason' => stop_reason,
          'usage' => { 'input_tokens' => 0, 'output_tokens' => 0 }
        }
      end

      # Strip reasoning blocks emitted by thinking models like Qwen.
      # Handles both <think> tags and untagged "Thinking Process:" patterns.
      def strip_thinking(text)
        return text unless text
        # 1. Strip <think>...</think> tags
        result = text.gsub(/<think>.*?<\/think>/m, '')
        # 2. Strip untagged thinking: "Thinking Process:" or "**Thinking" followed by
        #    reasoning text, then the actual answer (heuristic: first Korean sentence block)
        if result.strip.empty? || result =~ /\A\s*(Thinking Process|<?\*?\*?Thinking)/i
          # Try to find where the actual answer starts (Korean text block)
          if (match = text.match(/([가-힣].{20,})/m))
            result = match[0]
          end
        end
        result.strip
      end

      def empty_response
        {
          'id' => "msg_#{SecureRandom.hex(12)}",
          'type' => 'message',
          'role' => 'assistant',
          'content' => [{ 'type' => 'text', 'text' => '' }],
          'stop_reason' => 'end_turn',
          'usage' => { 'input_tokens' => 0, 'output_tokens' => 0 }
        }
      end
    end
  end
end
