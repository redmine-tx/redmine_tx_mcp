require 'net/http'
require 'json'
require 'uri'
require 'set'
# Tool classes are loaded by init.rb (to_prepare block handles dev-mode reloading)

module RedmineTxMcp
  class ClaudeChatbot
    CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'

    # Layer 1: Max chars for tool results stored in conversation history (~1K tokens)
    MAX_TOOL_RESULT_CHARS = 4_000

    # Layer 3: Total char budget for conversation history sent to API (~20K tokens)
    MAX_HISTORY_CHARS = 80_000
    MAX_PERSISTED_MESSAGES = 60
    MAX_GUARD_RETRIES = 2

    PLAN_UPDATE_TOOL = {
      name: 'plan_update',
      description: 'Use this for multi-step work. Keep 2-4 concrete tool steps, mark exactly one step as in_progress, and update the whole plan as work progresses.',
      input_schema: {
        type: 'object',
        properties: {
          steps: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                title: { type: 'string', description: 'Concrete action step tied to one tool call' },
                status: {
                  type: 'string',
                  enum: %w[pending in_progress completed skipped],
                  description: 'Current step status'
                }
              },
              required: %w[title status]
            }
          },
          summary: { type: 'string', description: 'Short progress summary' }
        },
        required: ['steps']
      }
    }.freeze

    PLANNER_KEYWORDS = /
      비교|분석|조사|연구|리서치|정리해|요약해|단계별|step[\s-]*by[\s-]*step|
      원인|왜|어떻게|계획|플랜|정리|리포트|보고|검토
    /ix

    BULK_OPERATION_KEYWORDS = /
      일괄|대량|bulk|batch|한꺼번에|한번에|여러\s*(?:개|건|이슈)|모두|전체|전부
    /ix

    # Layer 4: Dynamic tool selection — profiles and keyword mapping
    TOOL_PROFILES = {
      version_progress: %w[
        version_list version_get version_overview version_statistics issue_children_summary
        version_create version_update version_delete
      ],
      issue_search: %w[issue_list issue_get issue_relations_get],
      spreadsheet_work: %w[
        spreadsheet_list_uploads spreadsheet_list_sheets spreadsheet_preview_sheet
        spreadsheet_extract_rows spreadsheet_export_report
        issue_list issue_get issue_update insert_bulk_update issue_relation_create issue_relation_delete
        enum_statuses enum_trackers enum_priorities enum_categories
        user_list user_get version_list version_get
      ],
      bug_analysis: %w[bug_statistics issue_list issue_get version_list version_get],
      issue_management: %w[
        issue_get issue_relations_get issue_create issue_update insert_bulk_update
        issue_relation_create issue_relation_delete
        enum_statuses enum_trackers enum_priorities enum_categories
        version_list version_get
        user_list user_get
      ],
      project_info: %w[
        project_list project_get project_create project_update project_delete
        project_members project_add_member project_remove_member
        user_list user_get enum_roles
      ],
      user_info: %w[
        user_list user_get user_create user_update user_delete
        user_projects user_groups user_roles
        project_list project_get
      ],
    }.freeze

    PROFILE_KEYWORDS = {
      version_progress: %w[버전 version 마일스톤 milestone 진행 진척 현황 릴리즈 release 스프린트 sprint],
      issue_search: %w[일감 이슈 issue 검색 찾 목록 조회 상태 overdue 지연 선행 후행 관계 의존 의존성 blocker blocked duplicate 중복 링크 연결],
      spreadsheet_work: %w[엑셀 excel xlsx csv tsv 스프레드시트 spreadsheet 시트 sheet 워크북 workbook 업로드 첨부 파일 표 테이블 row rows column columns 컬럼],
      bug_analysis: %w[버그 bug 결함 defect],
      issue_management: %w[생성 만들 수정 변경 삭제 create update delete 등록 할당
                          바꿔 바꾸 편집 연기 미뤄 미루 당겨 당기 땡겨 땡기 고쳐 고치 반영 옮기
                          추가 세팅 설정 지정 재배정 재할당 배정 코멘트 댓글 메모 노트
                          종료 종결 완료 재오픈 reopen close comment assign assignee due
                          링크 연결 해제 unlink
                          priority 우선순위 일정 기한 마감 qa 검수],
      project_info: %w[프로젝트 project],
      user_info: %w[사용자 user 담당자 멤버 member 누구],
    }.freeze

    SPREADSHEET_STRONG_KEYWORDS = %w[
      엑셀 xlsx csv tsv 스프레드시트 시트 워크북 업로드 첨부
      excel spreadsheet sheet workbook upload attached attachment
    ].freeze

    SPREADSHEET_ENGLISH_REGEX = /\b(?:excel|xlsx|csv|tsv|spreadsheet|sheet|workbook|upload(?:ed)?|attach(?:ed|ment)?)\b/i

    BASE_TOOLS = %w[
      issue_list issue_get issue_relations_get issue_create issue_update insert_bulk_update issue_relation_create issue_relation_delete issue_children_summary
      version_list version_get version_overview bug_statistics
      enum_statuses enum_trackers enum_priorities enum_categories
      user_list user_get
    ].freeze

    READ_ONLY_TOOL_PATTERNS = [
      /\Aissue_(list|get|relations_get|children_summary)\z/,
      /\Abug_statistics\z/,
      /\Aversion_(list|get|overview|statistics)\z/,
      /\Aproject_(list|get|members)\z/,
      /\Auser_(list|get|projects|groups|roles)\z/,
      /\Aspreadsheet_(list_uploads|list_sheets|preview_sheet|extract_rows)\z/,
      /\Aenum_/
    ].freeze

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

    def set_workspace_context(context)
      @workspace_context = context.is_a?(Hash) ? deep_dup(context) : nil
    end

    def chat(user_message, user: nil)
      # Set current user for MCP operations
      User.current = user || User.find(1)
      session_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reset_metrics

      begin
        ChatbotLogger.log_user_query(
          session_id: conversation_id,
          user_name: User.current&.name || 'Anonymous',
          message: user_message
        )

        # Add user message to conversation
        add_to_conversation('user', user_message)

        # Layer 4: Select tools based on user query keywords
        select_tools_for_query(user_message)
        prepare_tool_call_budget(user_message)

        # Create system message with MCP tools information
        # Layer 3: Budget-managed conversation history
        clean_messages = clean_conversation_history(budget_conversation_history(@conversation_history))

        response = invoke_model(build_request_body(messages: clean_messages))
        response = resolve_response(response, user_message)

        # Extract assistant response
        assistant_message = extract_text_content(response)

        # Ensure we have a valid response
        if assistant_message.blank?
          assistant_message = "죄송합니다. 응답을 생성하는 중 문제가 발생했습니다."
        end

        add_to_conversation('assistant', assistant_message)

        ChatbotLogger.log_assistant_response(
          session_id: conversation_id,
          message: assistant_message
        )

        log_session_summary(session_start)

        {
          success: true,
          message: assistant_message,
          conversation_id: conversation_id
        }

      rescue => e
        ChatbotLogger.log_error(session_id: conversation_id, context: "chat", error_class: e.class, message: e.message, backtrace: e.backtrace)

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
        ChatbotLogger.log_user_query(
          session_id: conversation_id,
          user_name: User.current&.name || 'Anonymous',
          message: user_message
        )

        add_to_conversation('user', user_message)

        # Layer 4: Select tools based on user query keywords
        select_tools_for_query(user_message)
        prepare_tool_call_budget(user_message)
        execution_plan = build_execution_plan(user_message)

        clean_messages = clean_conversation_history(budget_conversation_history(@conversation_history))

        request_body = build_request_body(messages: clean_messages)

        if execution_plan
          ChatbotLogger.log_info(
            session_id: conversation_id,
            context: "PLAN",
            detail: execution_plan[:steps].join(" | ")
          )
          yield(execution_plan.merge(type: 'plan'))
        end

        response = invoke_model(
          request_body,
          thinking_message: execution_plan ? execution_plan[:status] : 'Thinking...',
          event_handler: proc { |event| yield(event) }
        )
        response = resolve_response(
          response,
          user_message,
          event_handler: proc { |event| yield(event) }
        )

        assistant_message = extract_text_content(response)
        assistant_message = "죄송합니다. 응답을 생성하는 중 문제가 발생했습니다." if assistant_message.blank?

        add_to_conversation('assistant', assistant_message)

        ChatbotLogger.log_assistant_response(
          session_id: conversation_id,
          message: assistant_message
        )

        log_session_summary(session_start)

        yield({ type: 'answer', message: assistant_message })
        yield({ type: 'done' })

        { success: true, message: assistant_message, conversation_id: conversation_id }

      rescue => e
        ChatbotLogger.log_error(session_id: conversation_id, context: "chat_stream", error_class: e.class, message: e.message, backtrace: e.backtrace)

        log_session_summary(session_start)

        yield({ type: 'error', message: e.message })
        yield({ type: 'done' })

        { success: false, error: e.message }
      end
    end

    def reset_conversation
      @conversation_history = []
      @selected_tool_names = nil
      reset_agent_state
    end

    def export_session_state
      {
        'conversation_id' => conversation_id,
        'conversation_history' => deep_dup(@conversation_history.last(MAX_PERSISTED_MESSAGES))
      }
    end

    def restore_session_state(snapshot)
      return unless snapshot.is_a?(Hash)

      restored_id = snapshot['conversation_id'] || snapshot[:conversation_id]
      @conversation_id = restored_id.to_s if restored_id.present?

      history = snapshot['conversation_history'] || snapshot[:conversation_history]
      @conversation_history = normalize_conversation_history(history)
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
      workspace_summary = workspace_context_summary
      parts << workspace_summary if workspace_summary.present?

      parts.join("\n\n")
    end

    # All tool classes available to the chatbot
    TOOL_CLASS_NAMES = %w[
      RedmineTxMcp::Tools::IssueTool
      RedmineTxMcp::Tools::ProjectTool
      RedmineTxMcp::Tools::UserTool
      RedmineTxMcp::Tools::VersionTool
      RedmineTxMcp::Tools::EnumerationTool
      RedmineTxMcp::Tools::SpreadsheetTool
    ].freeze

    def tool_classes
      TOOL_CLASS_NAMES.map(&:constantize)
    end

    # Full tool definitions (memoized)
    def all_mcp_tools
      @all_mcp_tools ||= tool_classes.flat_map { |klass|
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

    def internal_tools
      @planner_active ? [PLAN_UPDATE_TOOL] : []
    end

    def external_mcp_tools(force_all: false)
      if force_all || @selected_tool_names.nil?
        all_mcp_tools
      else
        all_mcp_tools.select { |t| @selected_tool_names.include?(t[:name]) }
      end
    end

    # Layer 4: Return filtered tools if @selected_tool_names is set, otherwise all
    def available_mcp_tools(force_all: false, include_internal_tools: true)
      tools = external_mcp_tools(force_all: force_all)
      include_internal_tools ? internal_tools + tools : tools
    end

    def build_request_body(messages:, force_all_tools: false, tool_choice: nil, include_internal_tools: true)
      body = {
        model: @model,
        max_tokens: 4000,
        system: build_system_message,
        messages: messages,
        tools: available_mcp_tools(force_all: force_all_tools, include_internal_tools: include_internal_tools)
      }
      body[:tool_choice] = tool_choice if tool_choice
      body
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

    def normalize_conversation_history(history)
      Array(history).filter_map do |msg|
        role = msg[:role] || msg['role']
        content = msg[:content] || msg['content']
        next unless %w[user assistant].include?(role.to_s)
        next if content.nil?

        {
          role: role.to_s,
          content: deep_dup(content)
        }
      end
    end

    def call_claude_api(request_body, &on_chunk)
      api_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      parsed = if @provider == 'openai'
        call_openai_api(request_body, &on_chunk)
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
      max_depth = max_tool_calls

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
      http.open_timeout = 30
      http.read_timeout = 300

      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = @api_key
      request['anthropic-version'] = '2023-06-01'
      request.body = JSON.generate(request_body)

      # API request debug logging omitted (verbose)

      response = http.request(request)

      unless response.code == '200'
        ChatbotLogger.log_error(session_id: conversation_id, context: "Claude API HTTP #{response.code}", error_class: "HttpError", message: response.body.to_s[0..500])
        raise "Claude API Error: #{response.code} - #{response.body}"
      end

      JSON.parse(response.body)
    end

    def call_openai_api(request_body, &on_chunk)
      # OpenAI request debug logging omitted (verbose)
      if block_given?
        OpenaiAdapter.call_streaming(request_body, api_key: @api_key, endpoint_url: @endpoint_url, &on_chunk)
      else
        OpenaiAdapter.call(request_body, api_key: @api_key, endpoint_url: @endpoint_url)
      end
    end

    def resolve_response(response, user_message, event_handler: nil)
      tool_call_depth = 0
      @metrics[:tool_call_depth] = 0

      loop do
        while response_has_tool_use?(response) && tool_call_depth < max_tool_calls
          tool_call_depth += 1
          @metrics[:tool_call_depth] = tool_call_depth
          ChatbotLogger.log_info(
            session_id: conversation_id,
            context: "TOOL LOOP",
            detail: "depth: #{tool_call_depth}/#{max_tool_calls}"
          )
          response = handle_tool_calls(response, event_handler: event_handler)
        end

        if response_has_tool_use?(response)
          ChatbotLogger.log_info(
            session_id: conversation_id,
            context: "TOOL LOOP",
            detail: "MAX DEPTH #{max_tool_calls} reached, stopping"
          )
          break
        end

        retry_info = guard_retry_instruction(response, user_message)
        break unless retry_info

        response = retry_response(response, retry_info, event_handler: event_handler)
      end

      response
    end

    def handle_tool_calls(response, event_handler: nil)
      begin
        # Process each tool call in the response
        tool_results = []

        response['content'].each do |content|
          next unless content['type'] == 'tool_use'

          tool_name = content['name']
          tool_input = content['input']

          if tool_name == 'plan_update'
            plan_result = execute_plan_update(tool_input)
            tool_results << {
              type: 'tool_result',
              tool_use_id: content['id'],
              content: plan_result[:content]
            }
            event_handler&.call(plan_result[:event].merge(type: 'plan'))
            next
          end

          if repeat_blocked?(tool_name, tool_input)
            warning = "같은 도구 호출이 반복되어 중단했습니다: #{tool_name}. 다른 조건으로 다시 시도하거나 현재 결과를 정리하세요."
            ChatbotLogger.log_info(session_id: conversation_id, context: "LOOP GUARD", detail: warning)
            tool_results << {
              type: 'tool_result',
              tool_use_id: content['id'],
              content: warning
            }
            next
          end

          event_handler&.call({ type: 'tool_call', tool: tool_name, input: tool_input })

          # Execute the tool (logging handled by execute_mcp_tool -> ChatbotLogger.log_tool_execution)
          result = execute_mcp_tool(tool_name, tool_input)
          record_tool_call!(tool_name, tool_input, result)
          @real_tool_calls += 1
          @tool_results_since_last_plan += 1 unless tool_error_result?(result)

          event_handler&.call({ type: 'tool_result', tool: tool_name })

          tool_results << {
            type: 'tool_result',
            tool_use_id: content['id'],
            content: encoded_tool_content(result)
          }
        end

        # If we had tool calls, make another API call with the results
        if tool_results.any?
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

          invoke_model(
            build_request_body(messages: clean_messages),
            thinking_message: 'Analyzing results...',
            event_handler: event_handler
          )
        else
          response
        end
      rescue => e
        ChatbotLogger.log_error(session_id: conversation_id, context: "handle_tool_calls", error_class: e.class, message: e.message, backtrace: e.backtrace)

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
      klass = tool_classes.find { |k| k.available_tools.any? { |t| t[:name] == tool_name } }

      result = if klass
        # Convert symbol keys to string keys for consistency
        params = tool_input.is_a?(Hash) ? tool_input.transform_keys(&:to_s) : {}
        params['_chatbot_context'] = true
        params['_chatbot_workspace'] = deep_dup(@workspace_context) if @workspace_context.present?
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
      result_str = result.is_a?(String) ? result : RedmineTxMcp::LlmFormatEncoder.encode(result)

      # Calculate what the truncated size would be (for logging)
      truncated_str = truncate_tool_result(result_str)
      truncated_chars = truncated_str.length < result_str.length ? truncated_str.length : nil

      @metrics[:tool_executions] += 1
      ChatbotLogger.log_tool_execution(
        tool_name: tool_name,
        tool_input: tool_input.inspect,
        result_text: result_str,
        result_chars: result_str.length,
        truncated_chars: truncated_chars,
        duration_ms: duration_ms
      )

      result
    rescue => e
      ChatbotLogger.log_error(session_id: conversation_id, context: "execute_mcp_tool(#{tool_name})", error_class: e.class, message: e.message, backtrace: e.backtrace)
      { error: "Tool execution failed: #{e.message}" }
    end

    def extract_text_content(response)
      return "" unless response && response['content']

      text_parts = response['content'].select { |c| c['type'] == 'text' }
      result = text_parts.map { |part| part['text'] }.join("\n").strip

      # extracted text logged via log_assistant_response
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
        ChatbotLogger.log_info(session_id: conversation_id, context: "WARN", detail: "Invalid role '#{role}' in conversation, skipping")
      end
    end

    def reset_metrics
      @metrics = {
        api_calls: 0, tool_executions: 0,
        input_tokens: 0, output_tokens: 0,
        tool_call_depth: 0, last_budget_message_count: nil
      }
      reset_agent_state
    end

    def reset_agent_state
      @matched_profiles = []
      @selection_confidence = 'high'
      @planner_active = false
      @plan_state = nil
      @tool_results_since_last_plan = 0
      @tool_call_budget = nil
      @tool_call_history = Hash.new { |hash, key| hash[key] = { attempts: 0, successes: 0, errors: 0 } }
      @real_tool_calls = 0
      @guard_retry_counts = Hash.new(0)
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
        %w[description project category author
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
      budget = MAX_HISTORY_CHARS

      # Build from newest, working backwards, keeping paired tool_use/tool_result together
      selected = []
      i = messages.length - 1
      while i >= 0
        msg = messages[i]
        role = msg[:role] || msg['role']
        content = msg[:content] || msg['content']

        # tool_result (user with array) must be kept with preceding tool_use (assistant with array)
        if role == 'user' && content.is_a?(Array) && i.positive?
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

      result = selected

      @metrics[:last_budget_message_count] = result.size

      if result.size < messages.size
        ChatbotLogger.log_info(session_id: conversation_id, context: "BUDGET TRIM", detail: "#{messages.size} → #{result.size} messages (#{MAX_HISTORY_CHARS} char budget)")
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
      matched_profiles = []

      PROFILE_KEYWORDS.each do |profile, keywords|
        if keywords.any? { |kw| msg_lower.include?(kw) }
          matched_profiles << profile
          matched_tools.merge(TOOL_PROFILES[profile])
        end
      end

      if mutation_intent?(msg_lower)
        matched_profiles << :issue_management unless matched_profiles.include?(:issue_management)
        matched_tools.merge(TOOL_PROFILES[:issue_management])
      end

      if mutation_intent?(msg_lower) && project_intent?(msg_lower)
        matched_profiles << :project_info unless matched_profiles.include?(:project_info)
        matched_tools.merge(TOOL_PROFILES[:project_info])
      end

      if mutation_intent?(msg_lower) && user_intent?(msg_lower)
        matched_profiles << :user_info unless matched_profiles.include?(:user_info)
        matched_tools.merge(TOOL_PROFILES[:user_info])
      end

      if mutation_intent?(msg_lower) && version_entity_intent?(msg_lower)
        matched_profiles << :version_progress unless matched_profiles.include?(:version_progress)
        matched_tools.merge(TOOL_PROFILES[:version_progress])
      end

      if assignment_intent?(msg_lower)
        matched_tools.merge(%w[user_list user_get issue_update insert_bulk_update])
      end

      if schedule_or_version_intent?(msg_lower)
        matched_tools.merge(%w[version_list version_get issue_update insert_bulk_update])
      end

      if relation_intent?(msg_lower)
        matched_tools.merge(%w[issue_list issue_get issue_relations_get issue_relation_create issue_relation_delete])
      end

      if spreadsheet_intent?(msg_lower)
        matched_profiles << :spreadsheet_work unless matched_profiles.include?(:spreadsheet_work)
        matched_tools.merge(TOOL_PROFILES[:spreadsheet_work])
      end

      @matched_profiles = matched_profiles
      @selection_confidence = selection_confidence_for(matched_profiles)
      @planner_active = should_activate_planner?(msg_lower, matched_profiles)

      unless matched_profiles.any?
        @selected_tool_names = nil  # fallback: use all tools
        ChatbotLogger.log_info(session_id: conversation_id, context: "TOOL SELECT", detail: "no keyword match, using all #{all_mcp_tools.size} tools")
        return
      end

      @selected_tool_names = matched_tools.to_a
      ChatbotLogger.log_info(session_id: conversation_id, context: "TOOL SELECT", detail: "#{@selected_tool_names.size} tools: #{@selected_tool_names.join(', ')}")
    end

    def build_execution_plan(user_message)
      message = user_message.to_s.strip
      return nil if message.empty?

      korean = korean_message?(message)
      context = extract_plan_context(message, korean)
      plan = if spreadsheet_intent?(message) && mutation_intent?(message)
        build_spreadsheet_mutation_plan(context, korean)
      elsif spreadsheet_intent?(message)
        build_spreadsheet_read_plan(context, korean)
      elsif relation_intent?(message) && mutation_intent?(message)
        build_relation_mutation_plan(context, korean)
      elsif mutation_intent?(message) && bulk_operation_intent?(message)
        build_bulk_mutation_plan(context, korean)
      elsif mutation_intent?(message)
        build_mutation_plan(context, korean)
      elsif bug_analysis_intent?(message)
        build_bug_analysis_plan(context, korean)
      elsif version_progress_intent?(message)
        build_version_progress_plan(context, korean)
      elsif relation_intent?(message)
        build_relation_read_plan(context, korean)
      elsif issue_search_intent?(message) || message.length >= 12
        build_issue_search_plan(context, korean)
      end

      return nil unless plan

      {
        title: korean ? '계획' : 'Plan',
        steps: plan,
        status: korean ? '계획대로 확인 중입니다...' : 'Working through the plan...'
      }
    end

    def localized_plan(korean, ko_steps, en_steps)
      korean ? ko_steps : en_steps
    end

    def build_spreadsheet_mutation_plan(context, korean)
      source = spreadsheet_source_phrase(context, korean)
      data_scope = search_scope_phrase(context, korean, fallback: korean ? '변경 대상 조건' : 'the target conditions')
      change = mutation_scope_phrase(context, korean, fallback: korean ? '요청한 이슈 변경' : 'the requested issue changes')

      localized_plan(
        korean,
        [
          "#{source}을 spreadsheet_list_uploads와 spreadsheet_list_sheets로 확인합니다.",
          "#{data_scope}에 맞는 시트와 행만 spreadsheet_preview_sheet 또는 spreadsheet_extract_rows로 읽습니다.",
          "#{change}를 적용하고 필요하면 spreadsheet_export_report로 결과 파일을 만듭니다."
        ],
        [
          "Inspect #{source} with spreadsheet_list_uploads and spreadsheet_list_sheets.",
          "Read only the sheets and rows that match #{data_scope} with spreadsheet_preview_sheet or spreadsheet_extract_rows.",
          "Apply #{change} and create a downloadable file with spreadsheet_export_report if needed."
        ]
      )
    end

    def build_spreadsheet_read_plan(context, korean)
      source = spreadsheet_source_phrase(context, korean)
      data_scope = search_scope_phrase(context, korean, fallback: korean ? '필요한 데이터 구간' : 'the needed data window')

      localized_plan(
        korean,
        [
          "#{source}의 파일 목록과 시트 구성을 확인합니다.",
          "#{data_scope}에 맞는 부분만 미리보기나 행 추출로 읽습니다.",
          "읽은 내용을 근거로 답하고, 요청하면 spreadsheet_export_report로 결과 엑셀을 생성합니다."
        ],
        [
          "Check the available files and sheets in #{source}.",
          "Read only the relevant preview window or extracted rows for #{data_scope}.",
          "Answer from that data, and create a downloadable Excel report with spreadsheet_export_report if requested."
        ]
      )
    end

    def build_relation_mutation_plan(context, korean)
      target = target_scope_phrase(context, korean, fallback: korean ? '대상 이슈' : 'the target issues')
      relation_scope = relation_scope_phrase(context, korean, fallback: korean ? '요청한 관계' : 'the requested relation')

      localized_plan(
        korean,
        [
          "issue_list로 #{target}를 찾고, issue_get 또는 issue_relations_get으로 #{relation_scope}의 현재 상태를 확인합니다.",
          "요청한 변경에 맞춰 issue_relation_create 또는 issue_relation_delete로 #{relation_scope}를 반영합니다.",
          "변경 후 issue_get으로 #{relation_scope}가 기대대로 보이는지 검증합니다."
        ],
        [
          "Use issue_list to identify #{target}, then inspect the current #{relation_scope} with issue_get or issue_relations_get.",
          "Apply the requested change to #{relation_scope} with issue_relation_create or issue_relation_delete.",
          "Verify with issue_get that #{relation_scope} now matches the request."
        ]
      )
    end

    def build_bulk_mutation_plan(context, korean)
      target = target_scope_phrase(context, korean, fallback: korean ? '수정할 이슈 묶음' : 'the target issue set')
      change = mutation_scope_phrase(context, korean, fallback: korean ? '요청한 변경' : 'the requested change')

      localized_plan(
        korean,
        [
          "#{target}의 현재 상태를 먼저 확인합니다.",
          "#{change}에 필요한 상태, 담당자, 버전 같은 유효 값을 조회합니다.",
          "insert_bulk_update로 #{change}를 일괄 적용한 뒤 결과를 검증합니다."
        ],
        [
          "Inspect the current state of #{target} first.",
          "Look up any valid status, assignee, or version values needed for #{change}.",
          "Apply #{change} with insert_bulk_update and verify the results."
        ]
      )
    end

    def build_mutation_plan(context, korean)
      target = target_scope_phrase(context, korean, fallback: korean ? '대상 이슈' : 'the target issue')
      change = mutation_scope_phrase(context, korean, fallback: korean ? '요청한 변경' : 'the requested change')

      localized_plan(
        korean,
        [
          "#{target}와 현재 상태를 확인합니다.",
          "#{change}에 필요한 상태, 담당자, 버전 같은 유효 값을 조회합니다.",
          "issue_update로 #{change}를 적용한 뒤 결과를 다시 확인합니다."
        ],
        [
          "Identify #{target} and inspect its current state.",
          "Look up any valid status, assignee, or version values needed for #{change}.",
          "Apply #{change} with issue_update and verify the result."
        ]
      )
    end

    def build_bug_analysis_plan(context, korean)
      scope = analysis_scope_phrase(context, korean, fallback: korean ? '질문 범위' : 'the requested scope')

      localized_plan(
        korean,
        [
          "#{scope} 기준으로 버그 범위를 먼저 확정합니다.",
          "bug_statistics와 issue_list로 위험 신호와 관련 이슈를 조회합니다.",
          "#{scope}에서 핵심 문제와 후속 확인 포인트를 정리합니다."
        ],
        [
          "Pin down the bug scope for #{scope} first.",
          "Use bug_statistics and issue_list to find risk signals and related issues.",
          "Summarize the main problems and next checks for #{scope}."
        ]
      )
    end

    def build_version_progress_plan(context, korean)
      scope = version_scope_phrase(context, korean, fallback: korean ? '관련 버전이나 상위 이슈' : 'the relevant version or parent issue')

      localized_plan(
        korean,
        [
          "#{scope}를 먼저 식별합니다.",
          "version_overview 또는 issue_children_summary로 진행률과 지연 요소를 확인합니다.",
          "#{scope} 기준으로 주의가 필요한 항목부터 정리합니다."
        ],
        [
          "Identify #{scope} first.",
          "Use version_overview or issue_children_summary to inspect progress and delay factors.",
          "Answer with the at-risk items first for #{scope}, then the overall status."
        ]
      )
    end

    def build_relation_read_plan(context, korean)
      target = target_scope_phrase(context, korean, fallback: korean ? '질문에 맞는 이슈' : 'the right issue')
      relation_scope = relation_scope_phrase(context, korean, fallback: korean ? '관계 방향' : 'the relation direction')

      localized_plan(
        korean,
        [
          "issue_list로 #{target}를 찾습니다.",
          "정확한 대상이 정해지면 issue_get 또는 issue_relations_get으로 부모와 #{relation_scope}를 확인합니다.",
          "#{relation_scope}와 근거를 함께 정리합니다."
        ],
        [
          "Use issue_list to find #{target}.",
          "Once the target is exact, use issue_get or issue_relations_get to inspect the parent and #{relation_scope}.",
          "Answer with #{relation_scope} and the supporting evidence."
        ]
      )
    end

    def build_issue_search_plan(context, korean)
      scope = search_scope_phrase(context, korean, fallback: korean ? '질문에 맞는 이슈나 관련 대상' : 'the issue or related entity that matches the request')
      detail_target = exact_issue_phrase(context, korean, fallback: korean ? '정확한 한 건' : 'one exact issue')
      conclusion = conclusion_scope_phrase(context, korean, fallback: korean ? '질문한 항목' : 'the requested point')

      localized_plan(
        korean,
        [
          "issue_list로 #{scope}를 찾습니다. 이름 기반 필터가 있으면 우선 활용합니다.",
          "#{detail_target}이 정해지면 issue_get으로 상세 필드, 부모, 현재 관계를 확인합니다.",
          "#{conclusion}에 대해 근거와 함께 결론을 정리합니다."
        ],
        [
          "Use issue_list to find #{scope}, using name-based filters when possible.",
          "Once #{detail_target} is exact, switch to issue_get for detailed fields, parent info, and current relations.",
          "Summarize #{conclusion} with supporting evidence."
        ]
      )
    end

    def extract_plan_context(message, korean)
      {
        issue_refs: extract_issue_refs(message),
        file_refs: extract_file_refs(message),
        subject: extract_subject_label(message),
        filters: extract_filter_labels(message, korean),
        relations: extract_relation_labels(message, korean),
        mutations: extract_mutation_labels(message, korean),
        versions: extract_version_labels(message, korean)
      }
    end

    def extract_issue_refs(message)
      message.to_s.scan(/#\d+|(?:이슈|issue)\s*#?\d+|\b\d+\s*번\b/i).filter_map do |token|
        id = token.to_s.scan(/\d+/).first
        "##{id}" if id.present?
      end.uniq.first(4)
    end

    def extract_file_refs(message)
      message.to_s.scan(/\b[\w.\-]+\.(?:xlsx|csv|tsv)\b/i).uniq.first(3)
    end

    def extract_subject_label(message)
      quoted = message.to_s[/["'“”‘’]([^"'“”‘’]{2,60})["'“”‘’]/, 1]
      return quoted.strip if quoted.present?

      match = message.to_s.match(/([A-Za-z0-9가-힣._-]+(?:\s+[A-Za-z0-9가-힣._-]+){0,2})\s*(?:이슈|issue|버그|bug|일감)\b/i)
      return nil unless match

      candidate = match[1].to_s.gsub(/\b(?:관련|현재|전체|모든|각|this|that|the)\b/i, '').strip
      return nil if candidate.blank? || candidate.length < 2

      candidate
    end

    def extract_filter_labels(message, korean)
      text = message.to_s
      downcased = text.downcase
      labels = []
      labels << (korean ? '미배정' : 'unassigned') if downcased.match?(/미배정|unassigned/)
      labels << (korean ? '지연' : 'overdue') if downcased.match?(/overdue|지연|마감.*초과|기한.*지난/)
      labels << (korean ? '버그' : 'bug') if downcased.match?(/\bbug\b|버그|defect/)
      labels << (korean ? '버전 없음' : 'no fixed version') if downcased.match?(/버전\s*없|고정\s*버전\s*없|no\s+version|without\s+version/)
      labels << (korean ? '기한 없음' : 'no due date') if downcased.match?(/기한\s*없|마감\s*없|due\s*없|no\s+due/)
      labels << (korean ? '상위 없는 이슈' : 'root issues') if downcased.match?(/부모\s*없|상위\s*없|루트\s*이슈|root issue|no parent/)
      labels.uniq.first(4)
    end

    def extract_relation_labels(message, korean)
      text = message.to_s.downcase
      labels = []
      labels << (korean ? '선행 관계' : 'predecessor relations') if text.match?(/선행|predecessor|precedes|precede/)
      labels << (korean ? '후행 관계' : 'successor relations') if text.match?(/후행|successor|follows|follow/)
      labels << (korean ? '차단 관계' : 'blocking relations') if text.match?(/차단|blocker|blocked|blocks/)
      labels << (korean ? '중복 관계' : 'duplicate relations') if text.match?(/중복|duplicate|duplicates|duplicated/)
      labels << (korean ? '관련 링크' : 'related links') if text.match?(/관련|relates|related|링크|연결/)
      labels.uniq.first(3)
    end

    def extract_mutation_labels(message, korean)
      text = message.to_s
      downcased = text.downcase
      labels = []

      if (status_value = extract_status_value(text))
        labels << (korean ? "상태를 #{status_value}(으)로" : "set the status to #{status_value}")
      elsif downcased.match?(/상태|status|qa|done|close|closed|reopen|review|resolved|종결|완료|검수/)
        labels << (korean ? '상태 변경' : 'a status change')
      end

      if assignment_intent?(downcased)
        assignee = extract_assignee_value(text)
        labels << if assignee.present?
                    korean ? "담당자를 #{assignee}(으)로" : "assign it to #{assignee}"
                  else
                    korean ? '담당자 변경' : 'an assignee change'
                  end
      end

      version_label = extract_version_value(text)
      if version_label.present?
        labels << (korean ? "#{version_label}(으)로 변경" : "move it to #{version_label}")
      elsif schedule_or_version_intent?(downcased)
        labels << (korean ? '버전 또는 일정 변경' : 'a version or schedule change')
      end

      if downcased.match?(/기한|마감|due|start_date|시작일/)
        labels << (korean ? '일정 필드 변경' : 'a date field change')
      end

      labels.uniq.first(4)
    end

    def extract_status_value(message)
      patterns = [
        /(?:상태|status)\s*(?:를|을)?\s*(?:to\s+)?([A-Za-z0-9가-힣_-]{2,30})(?:\s*(?:로|으로))?/i,
        /(?:to|로|으로)\s*(qa|done|closed|close|open|reopen|review|resolved|검수|완료|종결)/i
      ]

      patterns.each do |pattern|
        match = message.to_s.match(pattern)
        return match[1] if match && match[1].present?
      end

      nil
    end

    def extract_assignee_value(message)
      patterns = [
        /([A-Za-z0-9가-힣._-]{2,30})\s*(?:에게|한테)\s*할당/,
        /assign\s+(?:it\s+)?to\s+([A-Za-z0-9._-]{2,30})/i,
        /담당자\s*(?:를|을)?\s*([A-Za-z0-9가-힣._-]{2,30})/i
      ]

      patterns.each do |pattern|
        match = message.to_s.match(pattern)
        return match[1] if match && match[1].present?
      end

      nil
    end

    def extract_version_value(message)
      match = message.to_s.match(/(?:버전|version|마일스톤|milestone|스프린트|sprint)\s*[:#]?\s*([A-Za-z0-9._-]{2,40})/i)
      return nil unless match

      label = match[0].to_s.strip
      label.presence
    end

    def extract_version_labels(message, korean)
      value = extract_version_value(message)
      return [] unless value.present?

      [value]
    end

    def spreadsheet_source_phrase(context, korean)
      files = context[:file_refs]
      return files.join(', ') if files.any?

      korean ? '업로드된 파일' : 'the uploaded files'
    end

    def search_scope_phrase(context, korean, fallback:)
      labels = plan_labels(context, include_relations: false)
      return labels.join(', ') if labels.any?

      fallback
    end

    def target_scope_phrase(context, korean, fallback:)
      refs = Array(context[:issue_refs])
      labels = refs + Array(context[:subject]).compact + Array(context[:filters])
      return labels.uniq.first(3).join(', ') if labels.any?

      fallback
    end

    def exact_issue_phrase(context, korean, fallback:)
      refs = Array(context[:issue_refs])
      return refs.join(', ') if refs.any?

      subject = context[:subject]
      return korean ? "`#{subject}`에 해당하는 이슈" : "the issue matching `#{subject}`" if subject.present?

      fallback
    end

    def relation_scope_phrase(context, korean, fallback:)
      labels = Array(context[:relations])
      return labels.join(', ') if labels.any?

      fallback
    end

    def mutation_scope_phrase(context, korean, fallback:)
      labels = Array(context[:mutations])
      return labels.join(', ') if labels.any?

      fallback
    end

    def analysis_scope_phrase(context, korean, fallback:)
      labels = plan_labels(context, include_relations: false)
      return labels.join(', ') if labels.any?

      fallback
    end

    def version_scope_phrase(context, korean, fallback:)
      labels = Array(context[:versions]) + Array(context[:issue_refs]) + Array(context[:subject]).compact
      return labels.uniq.first(3).join(', ') if labels.any?

      fallback
    end

    def conclusion_scope_phrase(context, korean, fallback:)
      labels = Array(context[:relations]) + Array(context[:mutations]) + Array(context[:filters])
      return labels.uniq.first(2).join(', ') if labels.any?

      fallback
    end

    def plan_labels(context, include_relations:)
      labels = Array(context[:issue_refs]) +
               Array(context[:subject]).compact +
               Array(context[:filters]) +
               Array(context[:versions])
      labels += Array(context[:relations]) if include_relations
      labels.uniq.first(4)
    end

    def korean_message?(message)
      message.match?(/[가-힣]/)
    end

    def issue_search_intent?(message)
      PROFILE_KEYWORDS[:issue_search].any? { |kw| message.to_s.downcase.include?(kw) }
    end

    def spreadsheet_intent?(message)
      text = message.to_s
      downcased = text.downcase

      SPREADSHEET_STRONG_KEYWORDS.any? { |kw| downcased.include?(kw) } ||
        downcased.match?(SPREADSHEET_ENGLISH_REGEX)
    end

    def project_intent?(message)
      PROFILE_KEYWORDS[:project_info].any? { |kw| message.to_s.downcase.include?(kw) }
    end

    def user_intent?(message)
      PROFILE_KEYWORDS[:user_info].any? { |kw| message.to_s.downcase.include?(kw) }
    end

    def bug_analysis_intent?(message)
      PROFILE_KEYWORDS[:bug_analysis].any? { |kw| message.to_s.downcase.include?(kw) }
    end

    def version_progress_intent?(message)
      PROFILE_KEYWORDS[:version_progress].any? { |kw| message.to_s.downcase.include?(kw) }
    end

    def version_entity_intent?(message)
      version_progress_intent?(message) || message.to_s.downcase.include?('version')
    end

    def requested_issue_count(message)
      ids = message.to_s.scan(/#\d+|(?:이슈|issue)\s*#?\d+|\b\d+\s*번\b/i).map { |token| token.to_s.scan(/\d+/).first }
      ids.uniq.size
    end

    def bulk_operation_intent?(message)
      text = message.to_s
      text.match?(BULK_OPERATION_KEYWORDS) || requested_issue_count(text) >= 3
    end

    def mutation_intent?(message)
      msg = message.to_s.downcase
      PROFILE_KEYWORDS[:issue_management].any? { |kw| msg.include?(kw) } ||
        msg.match?(/(?:^|\s)#?\d+\s*(?:을|를)?\s*(?:qa|review|done|close|closed|reopen)/i)
    end

    def assignment_intent?(message)
      msg = message.to_s.downcase
      %w[담당 할당 assign assignee owner].any? { |kw| msg.include?(kw) }
    end

    def schedule_or_version_intent?(message)
      msg = message.to_s.downcase
      %w[버전 version 마일스톤 milestone 스프린트 sprint 일정 기한 마감 due release].any? { |kw| msg.include?(kw) }
    end

    def relation_intent?(message)
      msg = message.to_s.downcase
      %w[선행 후행 관계 의존 의존성 blocker blocked duplicate duplicates duplicated relates related 링크 연결 unlink].any? { |kw| msg.include?(kw) }
    end

    def analysis_intent?(message)
      message.to_s.match?(PLANNER_KEYWORDS)
    end

    def selection_confidence_for(matched_profiles)
      return 'none' if matched_profiles.empty?
      return 'high' if matched_profiles.size == 1

      'low'
    end

    def should_activate_planner?(message, matched_profiles)
      msg = message.to_s
      return true if spreadsheet_intent?(msg)
      return true if mutation_intent?(msg)
      return true if analysis_intent?(msg)
      return true if matched_profiles.size >= 2
      return true if matched_profiles.empty?
      return true if msg.length >= 36

      false
    end

    def workspace_context_summary
      return nil unless @workspace_context.is_a?(Hash)

      user_id = @workspace_context[:user_id] || @workspace_context['user_id']
      project_id = @workspace_context[:project_id] || @workspace_context['project_id']
      session_id = @workspace_context[:session_id] || @workspace_context['session_id']
      return nil unless user_id.present? && project_id.present? && session_id.present?

      workspace = RedmineTxMcp::ChatbotWorkspace.new(
        user_id: user_id,
        project_id: project_id,
        session_id: session_id
      )

      uploads = workspace.list_uploads
      reports = workspace.list_reports
      lines = ["Current chatbot workspace is isolated to this user/session."]
      if uploads.any?
        lines << "Uploaded spreadsheet files available now:"
        uploads.each do |file|
          lines << "- #{file[:stored_name]} (#{file[:size_label]})"
        end
      else
        lines << "No uploaded spreadsheet files are currently available."
      end
      if reports.any?
        lines << "Existing downloadable reports:"
        reports.each do |file|
          lines << "- #{file[:stored_name]} (#{file[:size_label]}) at #{file[:download_path]}"
        end
      end
      lines.join("\n")
    rescue => e
      ChatbotLogger.log_error(session_id: conversation_id, context: 'workspace_context_summary', error_class: e.class, message: e.message, backtrace: e.backtrace)
      nil
    end

    def response_has_tool_use?(response)
      response['content']&.any? { |content| content['type'] == 'tool_use' }
    end

    def configured_max_tool_calls
      configured = (Setting.plugin_redmine_tx_mcp['max_tool_call_depth'].to_i rescue 10)
      configured.positive? ? configured : 10
    end

    def prepare_tool_call_budget(user_message)
      base = configured_max_tool_calls
      @tool_call_budget = if bulk_operation_intent?(user_message)
        [base, 30].max
      else
        base
      end
    end

    def max_tool_calls
      @tool_call_budget || configured_max_tool_calls
    end

    def invoke_model(request_body, thinking_message: nil, event_handler: nil)
      first_chunk_received = false
      if event_handler
        event_handler.call({ type: 'thinking', message: thinking_message }) if thinking_message.present?
        call_claude_api(request_body) do |_event|
          next if first_chunk_received

          first_chunk_received = true
          event_handler.call({ type: 'thinking', message: 'Generating response...' })
        end
      else
        call_claude_api(request_body)
      end
    end

    def build_clean_messages(extra_messages = [])
      clean_conversation_history(
        budget_conversation_history(@conversation_history + extra_messages)
      )
    end

    def normalize_plan_state(input)
      steps = Array(input['steps'] || input[:steps]).filter_map do |step|
        title = (step['title'] || step[:title]).to_s.strip
        next if title.empty?

        status = (step['status'] || step[:status]).to_s
        status = 'pending' unless %w[pending in_progress completed skipped].include?(status)
        { 'title' => title, 'status' => status }
      end

      {
        'steps' => steps.first(4),
        'summary' => (input['summary'] || input[:summary]).to_s.strip
      }
    end

    def plan_pending?
      @plan_state && @plan_state['steps'].any? { |step| %w[pending in_progress].include?(step['status']) }
    end

    def pending_plan_titles
      return [] unless @plan_state

      @plan_state['steps']
        .select { |step| %w[pending in_progress].include?(step['status']) }
        .map { |step| step['title'] }
    end

    def repeated_in_progress_titles(plan_state)
      Array(plan_state['steps'])
        .select { |step| step['status'] == 'in_progress' }
        .map { |step| step['title'] }
    end

    def fake_completed_titles(old_state, new_state)
      return [] unless old_state

      old_status = Array(old_state['steps']).each_with_object({}) do |step, memo|
        memo[step['title']] = step['status']
      end

      newly_completed = Array(new_state['steps']).filter_map do |step|
        next unless step['status'] == 'completed'
        next unless %w[pending in_progress].include?(old_status[step['title']])

        step['title']
      end

      if newly_completed.size > @tool_results_since_last_plan
        newly_completed[@tool_results_since_last_plan..] || []
      else
        []
      end
    end

    def format_plan_state(plan_state)
      lines = ['계획 업데이트:']
      Array(plan_state['steps']).each_with_index do |step, index|
        icon = {
          'pending' => '⬜',
          'in_progress' => '🔄',
          'completed' => '✅',
          'skipped' => '⏭️'
        }[step['status']] || '•'
        lines << "#{icon} #{index + 1}. #{step['title']}"
      end
      lines << "현재: #{plan_state['summary']}" if plan_state['summary'].present?
      lines.join("\n")
    end

    def execute_plan_update(tool_input)
      new_state = normalize_plan_state(tool_input || {})
      fake_completed = fake_completed_titles(@plan_state, new_state)
      in_progress_titles = repeated_in_progress_titles(new_state)
      @plan_state = new_state
      @tool_results_since_last_plan = 0

      message = format_plan_state(new_state)
      if fake_completed.any?
        message += "\n⚠️ 실제 도구 호출 없이 completed 처리된 단계가 있습니다: #{fake_completed.join(', ')}"
      end
      if in_progress_titles.size > 1
        message += "\n⚠️ in_progress 단계는 하나만 유지해야 합니다: #{in_progress_titles.join(', ')}"
      end

      {
        content: message,
        event: {
          title: '실행 계획',
          status: new_state['summary'].presence || '계획을 업데이트했습니다.',
          steps: Array(new_state['steps']).map do |step|
            "#{step['status']}: #{step['title']}"
          end
        }
      }
    end

    def read_only_tool?(tool_name)
      READ_ONLY_TOOL_PATTERNS.any? { |pattern| pattern.match?(tool_name.to_s) }
    end

    def side_effecting_tool?(tool_name)
      tool = tool_name.to_s
      return true if tool == 'spreadsheet_export_report'

      !read_only_tool?(tool) && tool.match?(/(?:create|update|delete|add_member|remove_member)\z/)
    end

    def repeat_limit_for_tool(tool_name)
      return 1 if side_effecting_tool?(tool_name)
      return 3 if read_only_tool?(tool_name)

      2
    end

    def tool_call_signature(tool_name, tool_input)
      normalized = tool_input.is_a?(Hash) ? tool_input.transform_keys(&:to_s) : {}
      [tool_name.to_s, JSON.generate(normalized.sort.to_h)]
    rescue
      [tool_name.to_s, normalized.to_s]
    end

    def repeat_blocked?(tool_name, tool_input)
      signature = tool_call_signature(tool_name, tool_input)
      history = @tool_call_history[signature]
      return history[:successes] >= 1 if side_effecting_tool?(tool_name)

      history[:attempts] >= repeat_limit_for_tool(tool_name)
    end

    def record_tool_call!(tool_name, tool_input, result)
      history = @tool_call_history[tool_call_signature(tool_name, tool_input)]
      history[:attempts] += 1
      if tool_error_result?(result)
        history[:errors] += 1
      else
        history[:successes] += 1
      end
    end

    def tool_error_result?(result)
      result.is_a?(Hash) && (result.key?(:error) || result.key?('error'))
    end

    def encoded_tool_content(result)
      result.is_a?(String) ? result : RedmineTxMcp::LlmFormatEncoder.encode(result)
    end

    def capability_refusal_response?(text)
      text.to_s.match?(/도구.*(없|않)|접근할 수 있는 도구|제공되지 않|수정 기능.*없|can't .*tool|don't have access/i)
    end

    def completion_claim_without_tool?(text)
      text.to_s.match?(/완료했|수정했|변경했|업데이트했|생성했|삭제했|할당했|옮겼|종결했|재오픈했|created|updated|deleted|assigned|closed|reopened/i)
    end

    def factual_query_intent?(message)
      issue_search_intent?(message) || bug_analysis_intent?(message) ||
        version_progress_intent?(message) || project_intent?(message) || user_intent?(message)
    end

    def direct_answer_without_tool?(text)
      message = text.to_s.strip
      return false if message.empty?
      return false if message.include?('?')
      return false if message.match?(/확인해볼|찾아볼|도와줄|가능할까요|please clarify/i)

      message.length >= 40
    end

    def guard_retry_instruction(response, user_message)
      assistant_message = extract_text_content(response)

      if @planner_active && plan_pending? && @guard_retry_counts[:plan_pending] < MAX_GUARD_RETRIES
        @guard_retry_counts[:plan_pending] += 1
        return {
          instruction: "[시스템] 아직 완료되지 않은 계획 단계가 있습니다: #{pending_plan_titles.join(', ')}. 남은 단계를 계속 진행하거나 불가능하면 skipped로 표시하세요.",
          status: '남은 계획 단계를 계속 확인 중입니다...'
        }
      end

      if mutation_intent?(user_message) && @real_tool_calls.zero?
        if capability_refusal_response?(assistant_message) && @guard_retry_counts[:capability_refusal] < 1
          @guard_retry_counts[:capability_refusal] += 1
          return {
            instruction: '[시스템] 이번 요청에는 수정/등록용 도구가 있을 수 있습니다. 도구 목록을 다시 확인하고, 필요한 조회 후 적절한 변경 도구를 호출하세요. 도구가 실제로 없을 때만 불가하다고 답하세요.',
            status: '수정 가능한 도구를 다시 확인 중입니다...',
            force_all_tools: true,
            tool_choice: { type: 'any' },
            include_internal_tools: false
          }
        end

        if completion_claim_without_tool?(assistant_message) && @guard_retry_counts[:completion_without_tool] < 1
          @guard_retry_counts[:completion_without_tool] += 1
          return {
            instruction: '[시스템] 변경 작업은 실제 도구 호출과 검증이 필요합니다. 도구 호출 없이 성공했다고 답하면 안 됩니다. 필요한 조회와 변경 도구를 사용해 다시 처리하세요.',
            status: '실제 변경 적용 여부를 다시 검증 중입니다...',
            force_all_tools: true,
            tool_choice: { type: 'any' },
            include_internal_tools: false
          }
        end
      end

      if factual_query_intent?(user_message) && @real_tool_calls.zero? &&
         direct_answer_without_tool?(assistant_message) &&
         @guard_retry_counts[:factual_without_tool] < 1
        @guard_retry_counts[:factual_without_tool] += 1
        return {
          instruction: '[시스템] 이 요청은 Redmine 데이터 확인이 필요합니다. 추측하지 말고 관련 조회 도구를 호출한 뒤 근거와 함께 답하세요.',
          status: '실제 Redmine 데이터를 다시 확인 중입니다...',
          tool_choice: { type: 'any' },
          include_internal_tools: false
        }
      end

      nil
    end

    def retry_response(response, retry_info, event_handler: nil)
      retry_messages = build_clean_messages([
        { role: 'assistant', content: extract_text_content(response) },
        { role: 'user', content: retry_info[:instruction] }
      ])
      invoke_model(
        build_request_body(
          messages: retry_messages,
          force_all_tools: retry_info[:force_all_tools],
          tool_choice: retry_info[:tool_choice],
          include_internal_tools: retry_info.fetch(:include_internal_tools, true)
        ),
        thinking_message: retry_info[:status],
        event_handler: event_handler
      )
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
            ChatbotLogger.log_info(session_id: conversation_id, context: "WARN", detail: "Dropping orphaned tool_result message")
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
