require 'net/http'
require 'json'
require 'uri'
require 'securerandom'

module RedmineTxMcp
  class OpenaiAdapter
    class << self
      # Accepts an Anthropic-format request body and returns an Anthropic-format response hash.
      # Internally converts to OpenAI format, calls the endpoint, and converts back.
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

        # Text content
        if message['content'].present?
          content_blocks << { 'type' => 'text', 'text' => message['content'] }
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
