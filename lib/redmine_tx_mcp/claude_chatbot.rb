require 'net/http'
require 'json'
require 'uri'
require_relative 'tools/base_tool'
require_relative 'tools/issue_tool'
require_relative 'tools/project_tool'

module RedmineTxMcp
  class ClaudeChatbot
    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'

    def initialize(api_key: nil, model: nil)
      @api_key = api_key || ENV['ANTHROPIC_API_KEY']
      @model = model || 'claude-sonnet-4-6'
      @conversation_history = []

      raise ArgumentError, "Claude API key is required" unless @api_key
    end

    def chat(user_message, user: nil)
      # Set current user for MCP operations
      User.current = user || User.find(1)

      begin
        # Add user message to conversation
        add_to_conversation('user', user_message)

        # Create system message with MCP tools information
        system_message = build_system_message

        # Clean and prepare conversation history
        clean_messages = clean_conversation_history(@conversation_history.last(10))

        # Prepare Claude API request
        request_body = {
          model: @model,
          max_tokens: 4000,
          system: system_message,
          messages: clean_messages,
          tools: available_mcp_tools
        }

        # Call Claude API
        response = call_claude_api(request_body)

        # Process tool calls if any (with recursion limit)
        tool_call_depth = 0
        max_tool_calls = Setting.plugin_redmine_tx_mcp['max_tool_call_depth'].to_i || 10

        while response['content'] && response['content'].any? { |c| c['type'] == 'tool_use' } && tool_call_depth < max_tool_calls
          Rails.logger.info "Processing tool calls (depth: #{tool_call_depth + 1}/#{max_tool_calls})..."
          response = handle_tool_calls(response)
          tool_call_depth += 1
        end

        if tool_call_depth >= max_tool_calls
          Rails.logger.warn "Max tool call depth (#{max_tool_calls}) reached, stopping recursion"
        end

        # Extract assistant response
        assistant_message = extract_text_content(response)

        # Ensure we have a valid response
        if assistant_message.blank?
          assistant_message = "죄송합니다. 응답을 생성하는 중 문제가 발생했습니다."
        end

        add_to_conversation('assistant', assistant_message)

        {
          success: true,
          message: assistant_message,
          conversation_id: conversation_id
        }

      rescue => e
        Rails.logger.error "Claude Chatbot Error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        {
          success: false,
          error: e.message
        }
      end
    end

    # Streaming version: yields events during the agentic loop
    def chat_stream(user_message, user: nil)
      User.current = user || User.find(1)

      begin
        add_to_conversation('user', user_message)

        system_message = build_system_message
        clean_messages = clean_conversation_history(@conversation_history.last(10))

        request_body = {
          model: @model,
          max_tokens: 4000,
          system: system_message,
          messages: clean_messages,
          tools: available_mcp_tools
        }

        yield({ type: 'thinking', message: 'Thinking...' })
        response = call_claude_api(request_body)

        tool_call_depth = 0
        max_tool_calls = (Setting.plugin_redmine_tx_mcp['max_tool_call_depth'].to_i rescue 10) || 10

        while response['content']&.any? { |c| c['type'] == 'tool_use' } && tool_call_depth < max_tool_calls
          tool_results = []

          response['content'].each do |content|
            next unless content['type'] == 'tool_use'
            tool_name = content['name']
            tool_input = content['input']

            yield({ type: 'tool_call', tool: tool_name, input: tool_input })

            result = execute_mcp_tool(tool_name, tool_input)

            yield({ type: 'tool_result', tool: tool_name })

            tool_results << {
              type: 'tool_result',
              tool_use_id: content['id'],
              content: result.is_a?(String) ? result : JSON.generate(result)
            }
          end

          if tool_results.any?
            add_to_conversation('assistant', response['content'])
            add_to_conversation('user', tool_results)

            clean_messages = clean_conversation_history(@conversation_history)

            request_body = {
              model: @model,
              max_tokens: 4000,
              system: build_system_message,
              messages: clean_messages,
              tools: available_mcp_tools
            }

            yield({ type: 'thinking', message: 'Analyzing results...' })
            response = call_claude_api(request_body)
          end

          tool_call_depth += 1
        end

        assistant_message = extract_text_content(response)
        assistant_message = "죄송합니다. 응답을 생성하는 중 문제가 발생했습니다." if assistant_message.blank?

        add_to_conversation('assistant', assistant_message)

        yield({ type: 'answer', message: assistant_message })
        yield({ type: 'done' })

        { success: true, message: assistant_message, conversation_id: conversation_id }

      rescue => e
        Rails.logger.error "Claude Chatbot Stream Error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        yield({ type: 'error', message: e.message })
        yield({ type: 'done' })

        { success: false, error: e.message }
      end
    end

    def reset_conversation
      @conversation_history = []
    end

    def conversation_id
      @conversation_id ||= SecureRandom.hex(8)
    end

    private

    def build_system_message
      # Built-in prompt is always included (tool docs, workflow, reporting guidelines)
      plugin_defaults = Redmine::Plugin.find(:redmine_tx_mcp).settings[:default] rescue {}
      base_prompt = (plugin_defaults[:system_prompt] || plugin_defaults['system_prompt'] || '').to_s

      # User's custom prompt is appended as additional instructions
      settings = Setting.plugin_redmine_tx_mcp || {}
      custom_prompt = settings['system_prompt']

      parts = [base_prompt]
      if custom_prompt.present?
        parts << "## Additional Instructions\n#{custom_prompt.gsub('\\n', "\n")}"
      end
      parts << "Current user: #{User.current&.name || 'Anonymous'}"

      parts.join("\n\n")
    end

    # All tool classes available to the chatbot
    TOOL_CLASSES = [
      RedmineTxMcp::Tools::IssueTool,
      RedmineTxMcp::Tools::ProjectTool,
      RedmineTxMcp::Tools::UserTool,
      RedmineTxMcp::Tools::VersionTool,
      RedmineTxMcp::Tools::EnumerationTool
    ].freeze

    def available_mcp_tools
      @available_mcp_tools ||= TOOL_CLASSES.flat_map { |klass|
        klass.available_tools.map { |tool|
          schema = deep_dup(tool[:inputSchema] || tool[:input_schema] || { type: "object", properties: {} })
          sanitize_schema!(schema)
          {
            name: tool[:name],
            description: tool[:description],
            input_schema: schema
          }
        }
      }
    end

    # Remove 'required: true' from inside properties (invalid in JSON Schema 2020-12).
    # Only the top-level 'required' array is valid.
    def sanitize_schema!(schema)
      props = schema[:properties] || schema['properties']
      return schema unless props.is_a?(Hash)

      props.each_value do |v|
        next unless v.is_a?(Hash)
        v.delete(:required)
        v.delete('required')
      end
      schema
    end

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end

    def call_claude_api(request_body)
      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = JSON.generate(request_body)

      # Log the request for debugging
      Rails.logger.debug "Claude API Request: #{request_body.inspect}"

      response = http.request(request)

      unless response.code == '200'
        Rails.logger.error "Claude API Error: #{response.code} - #{response.body}"
        Rails.logger.error "Request body: #{JSON.pretty_generate(request_body)}"
        raise "Claude API Error: #{response.code} - #{response.body}"
      end

      JSON.parse(response.body)
    end

    def handle_tool_calls(response)
      begin
        # Process each tool call in the response
        tool_results = []

        response['content'].each do |content|
          if content['type'] == 'tool_use'
            tool_name = content['name']
            tool_input = content['input']

            Rails.logger.info "Executing tool: #{tool_name} with input: #{tool_input.inspect}"

            # Execute the tool
            result = execute_mcp_tool(tool_name, tool_input)

            Rails.logger.info "Tool result: #{result.inspect}"

            tool_results << {
              type: 'tool_result',
              tool_use_id: content['id'],
              content: result.is_a?(String) ? result : JSON.generate(result)
            }
          end
        end

        # If we had tool calls, make another API call with the results
        if tool_results.any?
          Rails.logger.info "Making follow-up API call with tool results..."

          # Add the assistant's response with tool calls to conversation history
          add_to_conversation('assistant', response['content'])

          # Add tool results as user message to conversation history
          add_to_conversation('user', tool_results)

          # Use the updated conversation history for the follow-up call
          clean_messages = clean_conversation_history(@conversation_history)

          request_body = {
            model: @model,
            max_tokens: 4000,
            system: build_system_message,
            messages: clean_messages,
            tools: available_mcp_tools
          }

          final_response = call_claude_api(request_body)
          Rails.logger.info "Follow-up API call completed"
          final_response
        else
          response
        end
      rescue => e
        Rails.logger.error "Error in handle_tool_calls: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        # Return a fallback response
        {
          'content' => [
            {
              'type' => 'text',
              'text' => "도구 실행 중 오류가 발생했습니다: #{e.message}"
            }
          ]
        }
      end
    end

    def execute_mcp_tool(tool_name, tool_input)
      # Find the tool class that handles this tool
      klass = TOOL_CLASSES.find { |k| k.available_tools.any? { |t| t[:name] == tool_name } }

      if klass
        # Convert symbol keys to string keys for consistency
        params = tool_input.is_a?(Hash) ? tool_input.transform_keys(&:to_s) : {}
        klass.call_tool(tool_name, params)
      else
        { error: "Unknown tool: #{tool_name}" }
      end
    rescue => e
      Rails.logger.error "MCP Tool execution error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { error: "Tool execution failed: #{e.message}" }
    end

    def extract_text_content(response)
      return "" unless response && response['content']

      text_parts = response['content'].select { |c| c['type'] == 'text' }
      result = text_parts.map { |part| part['text'] }.join("\n").strip

      Rails.logger.info "Extracted text content: #{result[0...200]}#{'...' if result.length > 200}"
      result
    end

    def add_to_conversation(role, content)
      # Ensure role is valid for Claude API
      if ['user', 'assistant'].include?(role)
        # For assistant messages with tool calls or user messages with tool results,
        # preserve the array structure. For simple text, convert to string.
        formatted_content = if content.is_a?(Array) || (content.is_a?(Hash) && content.key?('content'))
          content
        else
          content.to_s
        end

        @conversation_history << {
          role: role,
          content: formatted_content
        }
      else
        Rails.logger.warn "Invalid role '#{role}' in conversation. Skipping."
      end
    end

    def clean_conversation_history(messages)
      # Clean and validate conversation history for Claude API
      cleaned = []

      messages.each do |msg|
        next unless msg.is_a?(Hash)
        next unless ['user', 'assistant'].include?(msg[:role] || msg['role'])

        role = (msg[:role] || msg['role']).to_s
        content = msg[:content] || msg['content']

        # Skip empty messages (but allow complex content structures)
        if content.nil?
          next
        elsif content.is_a?(String) && content.strip.empty?
          next
        elsif content.is_a?(Array) && content.empty?
          next
        end

        cleaned << {
          role: role,
          content: content
        }
      end

      # Ensure conversation starts with a plain text user message.
      # Drop orphaned tool_result (user with array content) and
      # tool_use (assistant with array content) from the beginning.
      while cleaned.any?
        first = cleaned.first
        break if first[:role] == 'user' && first[:content].is_a?(String)
        cleaned.shift
      end

      # Validate tool_use/tool_result pairing: each tool_result (user array)
      # must be preceded by a tool_use (assistant array). Drop orphaned pairs.
      validated = []
      cleaned.each do |msg|
        if msg[:role] == 'user' && msg[:content].is_a?(Array)
          # tool_result — only keep if previous message is assistant with tool_use
          prev = validated.last
          if prev && prev[:role] == 'assistant' && prev[:content].is_a?(Array)
            validated << msg
          else
            # Orphaned tool_result — skip it
            Rails.logger.warn "[ClaudeChatbot] Dropping orphaned tool_result message"
          end
        elsif msg[:role] == 'assistant' && msg[:content].is_a?(Array)
          # tool_use — only keep if next message will be tool_result (we check later)
          # For now, add it; if no tool_result follows, it's still valid (Claude can
          # return tool_use that we'll handle in the loop)
          validated << msg
        else
          validated << msg
        end
      end

      validated
    end
  end
end