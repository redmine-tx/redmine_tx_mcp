require 'net/http'
require 'json'
require 'uri'
require_relative 'tools/base_tool'
require_relative 'tools/issue_tool'
require_relative 'tools/project_tool'

module RedmineTxMcp
  class ClaudeChatbot
    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'

    # Layer 1: Max chars for tool results stored in conversation history (~1K tokens)
    MAX_TOOL_RESULT_CHARS = 4_000

    # Layer 3: Total char budget for conversation history sent to API (~20K tokens)
    MAX_HISTORY_CHARS = 80_000

    # Layer 4: Dynamic tool selection — profiles and keyword mapping
    TOOL_PROFILES = {
      version_progress: %w[version_list version_get version_overview version_statistics issue_children_summary],
      issue_search: %w[issue_list issue_get],
      bug_analysis: %w[bug_statistics issue_list],
      issue_management: %w[issue_create issue_update enum_statuses enum_trackers enum_priorities enum_categories],
      project_info: %w[project_list project_get],
      user_info: %w[user_list user_get],
    }.freeze

    PROFILE_KEYWORDS = {
      version_progress: %w[버전 version 마일스톤 milestone 진행 진척 현황 릴리즈 release 스프린트 sprint],
      issue_search: %w[일감 이슈 issue 검색 찾 목록 조회 상태 overdue 지연],
      bug_analysis: %w[버그 bug 결함 defect],
      issue_management: %w[생성 만들 수정 변경 삭제 create update delete 등록 할당],
      project_info: %w[프로젝트 project],
      user_info: %w[사용자 user 담당자 멤버 member 누구],
    }.freeze

    BASE_TOOLS = %w[issue_list issue_get].freeze

    def initialize(api_key: nil, model: nil, project_id: nil, provider: 'anthropic', endpoint_url: nil)
      @provider = provider.to_s
      @endpoint_url = endpoint_url
      @model = model || 'claude-sonnet-4-6'
      @project_id = project_id
      @conversation_history = []
      @selected_tool_names = nil
      reset_metrics

      if @provider == 'openai'
        @api_key = api_key  # May be nil for local LLMs
      else
        @api_key = api_key || ENV['ANTHROPIC_API_KEY']
        raise ArgumentError, "Claude API key is required" unless @api_key
      end
    end

    def chat(user_message, user: nil)
      # Set current user for MCP operations
      User.current = user || User.find(1)
      session_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reset_metrics

      begin
        # Add user message to conversation
        add_to_conversation('user', user_message)

        # Layer 4: Select tools based on user query keywords
        select_tools_for_query(user_message)

        # Create system message with MCP tools information
        system_message = build_system_message

        # Layer 3: Budget-managed conversation history
        clean_messages = clean_conversation_history(budget_conversation_history(@conversation_history))

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
        @metrics[:tool_call_depth] = 0

        while response['content'] && response['content'].any? { |c| c['type'] == 'tool_use' } && tool_call_depth < max_tool_calls
          tool_call_depth += 1
          @metrics[:tool_call_depth] = tool_call_depth
          Rails.logger.info "Processing tool calls (depth: #{tool_call_depth}/#{max_tool_calls})..."
          response = handle_tool_calls(response)
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

        log_session_summary(session_start)

        {
          success: true,
          message: assistant_message,
          conversation_id: conversation_id
        }

      rescue => e
        Rails.logger.error "Claude Chatbot Error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        log_session_summary(session_start)

        {
          success: false,
          error: e.message
        }
      end
    end

    # Streaming version: yields events during the agentic loop
    def chat_stream(user_message, user: nil)
      User.current = user || User.find(1)
      session_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reset_metrics

      begin
        add_to_conversation('user', user_message)

        # Layer 4: Select tools based on user query keywords
        select_tools_for_query(user_message)

        system_message = build_system_message
        clean_messages = clean_conversation_history(budget_conversation_history(@conversation_history))

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
        @metrics[:tool_call_depth] = 0

        while response['content']&.any? { |c| c['type'] == 'tool_use' } && tool_call_depth < max_tool_calls
          tool_call_depth += 1
          @metrics[:tool_call_depth] = tool_call_depth
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
            # Layer 1: Store truncated results in history, use full results for current API call
            truncated_results = truncate_tool_results(tool_results)

            add_to_conversation('assistant', response['content'])
            add_to_conversation('user', truncated_results)

            # Layer 3: Budget-managed history for API call
            clean_messages = clean_conversation_history(budget_conversation_history(@conversation_history))

            # Replace the last user message (truncated) with full results for this call only
            if clean_messages.last && clean_messages.last[:role] == 'user'
              clean_messages.last[:content] = tool_results
            end

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
        end

        assistant_message = extract_text_content(response)
        assistant_message = "죄송합니다. 응답을 생성하는 중 문제가 발생했습니다." if assistant_message.blank?

        add_to_conversation('assistant', assistant_message)

        log_session_summary(session_start)

        yield({ type: 'answer', message: assistant_message })
        yield({ type: 'done' })

        { success: true, message: assistant_message, conversation_id: conversation_id }

      rescue => e
        Rails.logger.error "Claude Chatbot Stream Error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        log_session_summary(session_start)

        yield({ type: 'error', message: e.message })
        yield({ type: 'done' })

        { success: false, error: e.message }
      end
    end

    def reset_conversation
      @conversation_history = []
      @selected_tool_names = nil
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
      if @project_id
        project = Project.find(@project_id)
        parts << "Current project: #{project.name} (ID: #{project.id})"
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

    # Full tool definitions (memoized)
    def all_mcp_tools
      @all_mcp_tools ||= TOOL_CLASSES.flat_map { |klass|
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

    # Layer 4: Return filtered tools if @selected_tool_names is set, otherwise all
    def available_mcp_tools
      if @selected_tool_names
        all_mcp_tools.select { |t| @selected_tool_names.include?(t[:name]) }
      else
        all_mcp_tools
      end
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
      api_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      parsed = if @provider == 'openai'
        call_openai_api(request_body)
      else
        call_anthropic_api(request_body)
      end

      api_duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - api_start) * 1000).round

      # Track metrics and log detail
      @metrics[:api_calls] += 1
      usage = parsed['usage'] || {}
      input_tokens = usage['input_tokens'] || 0
      output_tokens = usage['output_tokens'] || 0
      @metrics[:input_tokens] += input_tokens
      @metrics[:output_tokens] += output_tokens

      system_prompt = request_body[:system] || request_body['system'] || ''
      messages = request_body[:messages] || request_body['messages'] || []
      tools = request_body[:tools] || request_body['tools'] || []
      max_depth = (Setting.plugin_redmine_tx_mcp['max_tool_call_depth'].to_i rescue 10) || 10

      ChatbotLogger.log_api_call(
        session_id: conversation_id,
        user_name: User.current&.name || 'Anonymous',
        model: @model,
        loop_depth: @metrics[:tool_call_depth],
        max_depth: max_depth,
        stop_reason: parsed['stop_reason'],
        system_prompt_chars: system_prompt.length,
        message_count: messages.size,
        raw_message_count: @conversation_history.size,
        budget_message_count: @metrics[:last_budget_message_count],
        tools_count: tools.size,
        tool_names: @selected_tool_names&.join(', '),
        input_tokens: input_tokens,
        output_tokens: output_tokens
      )

      parsed
    end

    def call_anthropic_api(request_body)
      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = JSON.generate(request_body)

      Rails.logger.debug "Claude API Request: #{request_body.inspect}"

      response = http.request(request)

      unless response.code == '200'
        Rails.logger.error "Claude API Error: #{response.code} - #{response.body}"
        Rails.logger.error "Request body: #{JSON.pretty_generate(request_body)}"
        raise "Claude API Error: #{response.code} - #{response.body}"
      end

      JSON.parse(response.body)
    end

    def call_openai_api(request_body)
      Rails.logger.debug "OpenAI-compatible API Request: #{request_body.inspect}"
      OpenaiAdapter.call(request_body, api_key: @api_key, endpoint_url: @endpoint_url)
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

          # Layer 1: Store truncated results in history, use full results for current call
          truncated_results = truncate_tool_results(tool_results)

          # Add the assistant's response with tool calls to conversation history
          add_to_conversation('assistant', response['content'])

          # Add truncated tool results to conversation history
          add_to_conversation('user', truncated_results)

          # Layer 3: Budget-managed history
          clean_messages = clean_conversation_history(budget_conversation_history(@conversation_history))

          # Replace the last user message (truncated) with full results for this API call only
          if clean_messages.last && clean_messages.last[:role] == 'user'
            clean_messages.last[:content] = tool_results
          end

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

    # Layer 2: Inject _chatbot_context flag so tools can return lightweight responses
    def execute_mcp_tool(tool_name, tool_input)
      tool_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Find the tool class that handles this tool
      klass = TOOL_CLASSES.find { |k| k.available_tools.any? { |t| t[:name] == tool_name } }

      result = if klass
        # Convert symbol keys to string keys for consistency
        params = tool_input.is_a?(Hash) ? tool_input.transform_keys(&:to_s) : {}
        params['_chatbot_context'] = true
        # Auto-inject project_id if tool supports it and it wasn't explicitly provided
        if @project_id && !params.key?('project_id')
          tool_def = klass.available_tools.find { |t| t[:name] == tool_name }
          if tool_def&.dig(:inputSchema, :properties, :project_id)
            params['project_id'] = @project_id
          end
        end
        klass.call_tool(tool_name, params)
      else
        { error: "Unknown tool: #{tool_name}" }
      end

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - tool_start) * 1000).round
      result_str = result.is_a?(String) ? result : JSON.generate(result)

      # Calculate what the truncated size would be (for logging)
      truncated_str = truncate_tool_result(result_str)
      truncated_chars = truncated_str.length < result_str.length ? truncated_str.length : nil

      @metrics[:tool_executions] += 1
      ChatbotLogger.log_tool_execution(
        tool_name: tool_name,
        tool_input: tool_input.inspect,
        result_chars: result_str.length,
        truncated_chars: truncated_chars,
        duration_ms: duration_ms
      )

      result
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

    def reset_metrics
      @metrics = {
        api_calls: 0, tool_executions: 0,
        input_tokens: 0, output_tokens: 0,
        tool_call_depth: 0, last_budget_message_count: nil
      }
    end

    def log_session_summary(session_start)
      total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - session_start) * 1000).round
      history_chars = @conversation_history.sum { |m| message_chars(m) }
      ChatbotLogger.log_session_summary(
        session_id: conversation_id,
        api_calls: @metrics[:api_calls],
        tool_executions: @metrics[:tool_executions],
        input_tokens: @metrics[:input_tokens],
        output_tokens: @metrics[:output_tokens],
        total_duration_ms: total_ms,
        history_message_count: @conversation_history.size,
        history_chars: history_chars
      )
    end

    # ─── Layer 1: Tool result truncation ─────────────────────────

    # Truncate each tool_result's content for history storage
    def truncate_tool_results(tool_results)
      tool_results.map do |tr|
        tr = deep_dup(tr)
        content_key = tr.key?(:content) ? :content : 'content'
        if tr[content_key].is_a?(String)
          tr[content_key] = truncate_tool_result(tr[content_key])
        end
        tr
      end
    end

    def truncate_tool_result(content_string)
      return content_string if content_string.length <= MAX_TOOL_RESULT_CHARS

      # Try to parse as JSON and slim down
      begin
        data = JSON.parse(content_string)
        slim_json_data!(data)
        result = JSON.generate(data)
        if result.length > MAX_TOOL_RESULT_CHARS
          result[0...MAX_TOOL_RESULT_CHARS] + "\n... [truncated, #{content_string.length} chars total]"
        else
          result
        end
      rescue JSON::ParserError
        content_string[0...MAX_TOOL_RESULT_CHARS] + "\n... [truncated, #{content_string.length} chars total]"
      end
    end

    # Recursively slim down JSON data: remove verbose fields, truncate arrays
    def slim_json_data!(data)
      case data
      when Hash
        # Remove verbose fields that are not essential for follow-up reasoning
        %w[description project category parent_issue author
           created_on updated_on closed_on begin_time end_time confirm_time].each do |f|
          data.delete(f)
        end
        data.each do |key, value|
          if value.is_a?(Array) && value.size > 10
            total = value.size
            data[key] = value.first(10)
            data[key] << { "_truncated" => "#{total - 10} more items omitted" }
          end
          slim_json_data!(value)
        end
      when Array
        data.each { |item| slim_json_data!(item) }
      end
    end

    # ─── Layer 3: Conversation history budget management ─────────

    def budget_conversation_history(messages)
      return messages if messages.empty?

      # Always keep the first user message (original question)
      first_user_idx = messages.index { |m|
        role = m[:role] || m['role']
        content = m[:content] || m['content']
        role == 'user' && content.is_a?(String)
      }
      return messages unless first_user_idx

      first_msg = messages[first_user_idx]
      first_msg_chars = message_chars(first_msg)
      budget = MAX_HISTORY_CHARS - first_msg_chars

      # Build from newest, working backwards, keeping paired tool_use/tool_result together
      selected = []
      i = messages.length - 1
      while i > first_user_idx
        msg = messages[i]
        role = msg[:role] || msg['role']
        content = msg[:content] || msg['content']

        # tool_result (user with array) must be kept with preceding tool_use (assistant with array)
        if role == 'user' && content.is_a?(Array) && i > first_user_idx
          prev_msg = messages[i - 1]
          prev_role = prev_msg[:role] || prev_msg['role']
          prev_content = prev_msg[:content] || prev_msg['content']

          if prev_role == 'assistant' && prev_content.is_a?(Array)
            pair_chars = message_chars(msg) + message_chars(prev_msg)
            if budget >= pair_chars
              selected.unshift(msg)
              selected.unshift(prev_msg)
              budget -= pair_chars
              i -= 2
            else
              break
            end
            next
          end
        end

        chars = message_chars(msg)
        if budget >= chars
          selected.unshift(msg)
          budget -= chars
        else
          break
        end
        i -= 1
      end

      result = [first_msg] + selected

      @metrics[:last_budget_message_count] = result.size

      if result.size < messages.size
        Rails.logger.info "[ClaudeChatbot] Budget trimmed history: #{messages.size} -> #{result.size} messages (#{MAX_HISTORY_CHARS} char budget)"
      end

      result
    end

    def message_chars(msg)
      content = msg[:content] || msg['content']
      case content
      when String then content.length
      when Array then JSON.generate(content).length rescue 0
      when Hash then JSON.generate(content).length rescue 0
      else 0
      end
    end

    # ─── Layer 4: Dynamic tool selection ─────────────────────────

    def select_tools_for_query(user_message)
      msg_lower = user_message.to_s.downcase
      matched_tools = Set.new(BASE_TOOLS)

      matched_any = false
      PROFILE_KEYWORDS.each do |profile, keywords|
        if keywords.any? { |kw| msg_lower.include?(kw) }
          matched_any = true
          matched_tools.merge(TOOL_PROFILES[profile])
        end
      end

      unless matched_any
        @selected_tool_names = nil  # fallback: use all tools
        Rails.logger.info "[ClaudeChatbot] No keyword match, using all #{all_mcp_tools.size} tools"
        return
      end

      @selected_tool_names = matched_tools.to_a
      Rails.logger.info "[ClaudeChatbot] Selected #{@selected_tool_names.size} tools: #{@selected_tool_names.join(', ')}"
    end

    # ─── Conversation history cleaning ───────────────────────────

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
