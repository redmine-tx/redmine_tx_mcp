require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'set'
require 'timeout'

module RedmineTxMcp
  class ClaudeAgentSdkChatbot
    TOKEN_CACHE_PREFIX = 'redmine_tx_mcp:chatbot_agent_sdk_token'.freeze
    DEFAULT_WORKER_PATH = File.expand_path('../../bin/chatbot_agent_sdk_worker.py', __dir__).freeze
    DEFAULT_MCP_SERVER_NAME = 'redmine'.freeze
    DEFAULT_MAX_WRITE_TOOL_CALLS = 1
    BULK_MAX_WRITE_TOOL_CALLS = 3
    COMPLEX_READ_BUDGET_RATIO = 1.2
    BULK_BUDGET_RATIO = 1.8
    MIN_COMPLEX_READ_TOOL_CALL_BUDGET = 18
    MIN_BULK_TOOL_CALL_BUDGET = 30

    TOOL_PROFILES = {
      version_progress: %w[
        version_list version_get version_overview version_statistics version_schedule_report
        issue_children_summary issue_schedule_tree
      ],
      issue_search: %w[issue_list issue_get issue_relations_get],
      spreadsheet_work: %w[
        spreadsheet_list_uploads spreadsheet_list_sheets spreadsheet_preview_sheet
        spreadsheet_extract_rows spreadsheet_export_report
        issue_list issue_get issue_update issue_bulk_update issue_relation_create issue_relation_delete
        enum_statuses enum_trackers enum_priorities enum_categories enum_custom_fields
        user_list user_get version_list version_get
      ],
      bug_analysis: %w[bug_statistics issue_list issue_get version_list version_get],
      issue_management: %w[
        issue_get issue_relations_get issue_create issue_update issue_bulk_update
        issue_auto_schedule_preview issue_auto_schedule_apply
        issue_relation_create issue_relation_delete
        enum_statuses enum_trackers enum_priorities enum_categories enum_custom_fields
        version_list version_get user_list user_get
      ],
      project_info: %w[
        project_list project_get project_members
        project_create project_update project_delete project_add_member project_remove_member
        user_list user_get enum_roles enum_custom_fields
      ],
      user_info: %w[
        user_list user_get user_projects user_groups user_roles
        user_create user_update user_delete
        project_list project_get enum_custom_fields
      ]
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
                          링크 연결 해제 unlink priority 우선순위 일정 기한 마감 qa 검수
                          커스텀필드 커스텀 사용자정의 custom_field custom],
      project_info: %w[프로젝트 project],
      user_info: %w[사용자 user 담당자 멤버 member 누구]
    }.freeze

    SCRIPT_TOOL_KEYWORDS = %w[
      계산 계산해 산식 수식 통계 평균 합계 정렬 순위 랭킹 날짜 date math arithmetic calculate calculation
      sum average mean sort rank ranking
    ].freeze

    BASE_TOOLS = %w[
      issue_list issue_get issue_relations_get issue_create issue_update issue_bulk_update
      issue_relation_create issue_relation_delete issue_children_summary issue_schedule_tree
      version_list version_get version_overview version_schedule_report bug_statistics
      enum_statuses enum_trackers enum_priorities enum_categories enum_custom_fields
      user_list user_get
    ].freeze

    EVIDENCE_TOOLS = {
      bug_analysis: %w[bug_statistics issue_list issue_get],
      issue_search: %w[issue_list issue_get issue_relations_get],
      version_progress: %w[version_overview version_get version_list version_schedule_report issue_children_summary issue_schedule_tree],
      project_info: %w[project_list project_get project_members],
      user_info: %w[user_list user_get user_projects user_groups user_roles],
      spreadsheet_work: %w[spreadsheet_list_uploads spreadsheet_list_sheets spreadsheet_preview_sheet spreadsheet_extract_rows]
    }.freeze

    class << self
      def token_cache_key(token)
        "#{TOKEN_CACHE_PREFIX}:#{token}"
      end

      def read_token_context(token)
        return nil if token.blank?

        Rails.cache.read(token_cache_key(token.to_s))
      end
    end

    def initialize(api_key:, model:, project_id:, mcp_url:)
      @api_key = api_key
      @model = model
      @project_id = project_id
      @mcp_url = mcp_url
      @workspace_context = nil
      @agent_sdk_session_id = nil
      @mutation_workflow = RedmineTxMcp::ChatbotMutationWorkflow.new
      @conversation_id = SecureRandom.hex(8)
    end

    def set_workspace_context(context)
      @workspace_context = context.is_a?(Hash) ? deep_dup(context) : nil
    end

    def conversation_id
      @conversation_id ||= SecureRandom.hex(8)
    end

    def chat(user_message, user: nil)
      User.current = user || User.find(1)
      final_message = nil

      run_worker(user_message, user: User.current) do |event|
        final_message = event[:message] if event[:type] == 'answer'
      end

      {
        success: true,
        message: final_message.presence || '',
        conversation_id: conversation_id
      }
    rescue => e
      RedmineTxMcp::ChatbotLogger.log_error(
        session_id: conversation_id,
        context: 'claude_agent_sdk_chatbot.chat',
        error_class: e.class,
        message: e.message,
        backtrace: e.backtrace
      )
      { success: false, error: e.message }
    end

    def chat_stream(user_message, user: nil)
      User.current = user || User.find(1)
      run_worker(user_message, user: User.current) do |event|
        yield(event)
      end
    rescue => e
      RedmineTxMcp::ChatbotLogger.log_error(
        session_id: conversation_id,
        context: 'claude_agent_sdk_chatbot.chat_stream',
        error_class: e.class,
        message: e.message,
        backtrace: e.backtrace
      )
      yield(type: 'error', message: e.message)
      yield(type: 'done')
      { success: false, error: e.message }
    end

    def export_session_state
      {
        'conversation_id' => conversation_id,
        'conversation_history' => [],
        'agent_state' => {
          'adapter' => 'claude_agent_sdk',
          'agent_sdk_session_id' => @agent_sdk_session_id,
          'mutation_workflow_state' => @mutation_workflow.export_state
        }
      }
    end

    def restore_session_state(snapshot)
      return unless snapshot.is_a?(Hash)

      restored_id = snapshot['conversation_id'] || snapshot[:conversation_id]
      @conversation_id = restored_id.to_s if restored_id.present?

      agent_state = snapshot['agent_state'] || snapshot[:agent_state] || {}
      @agent_sdk_session_id = agent_state['agent_sdk_session_id'] || agent_state[:agent_sdk_session_id]
      workflow_state = agent_state['mutation_workflow_state'] || agent_state[:mutation_workflow_state]
      @mutation_workflow = RedmineTxMcp::ChatbotMutationWorkflow.new(workflow_state)
    end

    private

    def run_worker(user_message, user:)
      token = register_agent_token(user)
      payload = worker_payload(user_message, token, user)
      final_message = nil
      error_message = nil
      successful_tool_results = []
      pending_done = false

      each_worker_event(payload) do |event|
        case event['type']
        when 'session'
          @agent_sdk_session_id = event['session_id'].to_s if event['session_id'].present?
          next
        when 'answer'
          final_message = event['message'].to_s
          next
        when 'tool_result'
          tool_result = record_agent_tool_result(event)
          successful_tool_results << tool_result if tool_result
        when 'error'
          error_message ||= event['message'].to_s
          next
        when 'done'
          next if final_message.blank? && error_message.present?
          pending_done = true
          next
        end

        yield(symbolize_event(event)) if block_given?
      end

      raise(error_message) if final_message.blank? && error_message.present?
      enforce_mutation_answer_guard!(user_message, final_message, successful_tool_results)
      if final_message.present? &&
         requires_redmine_tool_result?(user_message) &&
         !relevant_successful_tool_result?(user_message, successful_tool_results)
        raise(
          "질문과 관련된 Redmine MCP 조회 결과 없이 생성된 답변이라 중단했습니다. " \
          "버그/이슈/프로젝트 현황 질의는 관련 MCP 조회 결과가 확인되어야 답변할 수 있습니다."
        )
      end

      if final_message.present?
        yield(type: 'answer', message: final_message) if block_given?
      end
      yield(type: 'done') if block_given? && pending_done

      final_message
    ensure
      Rails.cache.delete(self.class.token_cache_key(token)) if token.present?
    end

    def worker_payload(user_message, token, user)
      allowed_tools = selected_tool_names_for(user_message)
      {
        message: user_message.to_s,
        model: @model,
        system_prompt: build_system_message,
        mcp_server_name: DEFAULT_MCP_SERVER_NAME,
        mcp_url: @mcp_url,
        mcp_headers: {
          'X-Redmine-Tx-Mcp-Chatbot-Token' => token
        },
        cwd: agent_sdk_cwd,
        resume_session_id: @agent_sdk_session_id,
        max_turns: configured_max_turns(user_message),
        max_write_tools: configured_max_write_tools(user_message),
        allowed_tool_names: allowed_tools,
        mutation_requires_read: mutation_intent?(user_message),
        user: user&.id.to_s
      }
    end

    def each_worker_event(payload)
      FileUtils.mkdir_p(agent_sdk_cwd)
      command = [python_path, worker_path]
      stderr_text = +''
      wait_thread = nil
      saw_error_event = false

      Timeout.timeout(configured_max_run_seconds + 30) do
        Open3.popen3(worker_env, *command, chdir: agent_sdk_cwd) do |stdin, stdout, stderr, wait_thr|
          wait_thread = wait_thr
          stderr_reader = Thread.new do
            stderr.each_line { |line| stderr_text << line }
          end

          stdin.write(JSON.generate(payload))
          stdin.close

          stdout.each_line do |line|
            line = line.to_s.strip
            next if line.empty?

            begin
              event = JSON.parse(line)
              saw_error_event = true if event['type'] == 'error'
              yield event
            rescue JSON::ParserError
              RedmineTxMcp::ChatbotLogger.log_info(
                session_id: conversation_id,
                context: 'AGENT SDK WORKER',
                detail: "Ignoring non-JSON worker output: #{line[0, 500]}"
              )
            end
          end

          status = wait_thr.value
          stderr_reader.join
          unless status.success? || saw_error_event
            detail = stderr_text.strip.presence || "exit status #{status.exitstatus}"
            raise "Claude Agent SDK worker failed: #{detail}"
          end
        end
      end
    rescue Timeout::Error
      begin
        Process.kill('TERM', wait_thread.pid) if wait_thread&.pid
      rescue Errno::ESRCH
        # Process already exited while the timeout was being handled.
      end
      raise "Claude Agent SDK worker timed out after #{configured_max_run_seconds} seconds"
    end

    def register_agent_token(user)
      token = SecureRandom.hex(32)
      Rails.cache.write(
        self.class.token_cache_key(token),
        {
          'user_id' => user&.id,
          'project_id' => @project_id,
          'session_id' => @workspace_context && (@workspace_context[:session_id] || @workspace_context['session_id']),
          'workspace' => deep_dup(@workspace_context || {})
        },
        expires_in: (configured_max_run_seconds + 120).seconds
      )
      token
    end

    def build_system_message
      plugin_defaults = Redmine::Plugin.find(:redmine_tx_mcp).settings[:default] rescue {}
      base_prompt = (plugin_defaults[:system_prompt] || plugin_defaults['system_prompt'] || '').to_s
      custom_prompt = chatbot_settings['system_prompt'].to_s

      parts = [base_prompt]
      parts << "## Additional Instructions\n#{custom_prompt.gsub('\\n', "\n")}" if custom_prompt.present?

      if @project_id
        project = Project.find(@project_id)
        parts << "Current project: #{project.name} (ID: #{project.id})"
      end

      parts << "Current user: #{User.current&.name || 'Anonymous'}"
      workspace_summary = workspace_context_summary
      parts << workspace_summary if workspace_summary.present?
      parts << <<~PROMPT.strip
        You are running through Anthropic Claude Agent SDK.
        Use only the Redmine MCP tools provided by the `#{DEFAULT_MCP_SERVER_NAME}` MCP server.
        For any question about Redmine issues, bugs, versions, projects, users, schedules, progress, or uploaded spreadsheet data, call the relevant Redmine MCP read tool before answering.
        If no Redmine MCP tool result is available, say that the data could not be verified instead of answering from memory or inference.
        Do not claim that Redmine data was changed unless a write tool succeeded and you verified the result with a read tool.
      PROMPT
      parts.join("\n\n")
    end

    def requires_redmine_tool_result?(user_message)
      text = user_message.to_s.downcase
      return false if text.blank?

      data_keywords = %w[
        bug bugs issue issues ticket tickets redmine project projects version versions
        status progress schedule roadmap milestone tracker priority assignee member
        버그 이슈 일감 결함 현황 상태 진행률 진행상황 일정 버전 마일스톤 프로젝트
        담당자 담당 멤버 우선순위 트래커 카테고리 조회 목록 통계 요약 지연 완료
        미완료 열린 닫힌 배정 미배정
      ]

      data_keywords.any? { |keyword| text.include?(keyword) } || text.match?(/#?\d{2,}/)
    end

    def record_agent_tool_result(event)
      tool_name = event['tool'].to_s
      return nil if tool_name.blank? || tool_name == DEFAULT_MCP_SERVER_NAME

      tool_input = event['input'].is_a?(Hash) ? event['input'] : {}
      result = decode_agent_tool_result(event['content'])
      is_error = event['is_error'] == true || tool_error_result?(result)
      result = { 'error' => 'MCP tool result was marked as failed.' } if is_error && !tool_error_result?(result)

      @mutation_workflow.record_tool_result(tool_name, tool_input, result)
      return nil if is_error

      {
        'tool' => tool_name,
        'input' => deep_dup(tool_input),
        'result' => deep_dup(result)
      }
    end

    def decode_agent_tool_result(content)
      case content
      when Hash
        deep_dup(content)
      when Array
        text = content.filter_map do |item|
          next item['text'] if item.is_a?(Hash) && item['text'].present?
          next item[:text] if item.is_a?(Hash) && item[:text].present?
        end.join("\n")
        text.present? ? parse_tool_result_text(text) : deep_dup(content)
      when String
        parse_tool_result_text(content)
      else
        {}
      end
    end

    def parse_tool_result_text(text)
      trimmed = text.to_s.strip
      return {} if trimmed.blank?

      JSON.parse(trimmed)
    rescue JSON::ParserError
      { 'text' => trimmed }
    end

    def selected_tool_names_for(user_message)
      text = user_message.to_s.downcase
      if @mutation_workflow.pending_verification?
        verify_tools = Set.new(@mutation_workflow.verify_with_tools)
        if verify_tools.empty?
          verify_tools.merge(Array(@mutation_workflow.follow_up_tool_names).select { |name| read_only_tool?(name) })
        end
        return verify_tools.map(&:to_s).uniq if verify_tools.any?
      end

      tools = Set.new(BASE_TOOLS)
      mutation = mutation_intent?(text)

      matched_profiles_for(text).each do |profile|
        tools.merge(TOOL_PROFILES[profile])
      end

      if RedmineTxMcp::ChatbotMutationWorkflow.follow_up_reference?(text) && @mutation_workflow.has_follow_up_context?
        tools.merge(@mutation_workflow.follow_up_tool_names)
      end

      tools.merge(TOOL_PROFILES[:issue_management]) if mutation
      tools.merge(%w[user_list user_get issue_update issue_bulk_update]) if assignment_intent?(text)
      tools.merge(%w[version_list version_get issue_update issue_bulk_update]) if schedule_or_version_intent?(text)
      tools.merge(%w[issue_list issue_get issue_relations_get issue_relation_create issue_relation_delete]) if relation_intent?(text)
      tools.merge(%w[issue_get issue_children_summary issue_schedule_tree issue_auto_schedule_preview issue_auto_schedule_apply]) if auto_schedule_intent?(text)
      tools << 'run_script' if calculation_intent?(text)

      tools = tools.select { |name| read_only_tool?(name) } unless mutation
      tools.map(&:to_s).uniq
    end

    def matched_profiles_for(text)
      PROFILE_KEYWORDS.each_with_object([]) do |(profile, keywords), matched|
        matched << profile if keywords.any? { |keyword| intent_keyword_match?(text, keyword) }
      end
    end

    def relevant_successful_tool_result?(user_message, successful_tool_results)
      required = required_evidence_tools_for(user_message)
      return successful_tool_results.any? if required.empty?

      successful_tool_results.any? { |result| required.include?(result['tool'].to_s) }
    end

    def required_evidence_tools_for(user_message)
      text = user_message.to_s.downcase
      required = Set.new
      matched_profiles_for(text).each do |profile|
        required.merge(EVIDENCE_TOOLS[profile]) if EVIDENCE_TOOLS[profile]
      end

      if parent_issue_progress_scope?(text)
        required.merge(%w[issue_children_summary issue_schedule_tree])
      elsif required.empty? && requires_redmine_tool_result?(text)
        required.merge(EVIDENCE_TOOLS[:issue_search])
        required.merge(EVIDENCE_TOOLS[:bug_analysis]) if text.include?('현황') || text.include?('status')
      end

      required.to_a
    end

    def enforce_mutation_answer_guard!(user_message, final_message, successful_tool_results)
      return if final_message.blank?
      return unless mutation_intent?(user_message) || @mutation_workflow.pending_verification? || @mutation_workflow.verification_failed?
      return unless completion_claim_without_tool?(final_message)

      successful_writes = successful_tool_results.select { |result| side_effecting_tool?(result['tool']) }
      if successful_writes.empty?
        raise(
          "Redmine 변경 도구의 성공 결과 없이 완료로 답변하려 해서 중단했습니다. " \
          "수정/삭제/생성 요청은 실제 MCP 쓰기 도구 성공 결과가 있어야 합니다."
        )
      end

      if @mutation_workflow.pending_verification?
        raise(
          "#{@mutation_workflow.verification_pending_message} " \
          "완료로 답변하려면 read-back 검증이 먼저 통과해야 합니다."
        )
      end

      if @mutation_workflow.verification_failed?
        raise(
          "최근 read-back 검증이 요청한 변경과 일치하지 않았습니다. " \
          "성공으로 보고하지 말고 불일치 내용을 확인해야 합니다."
        )
      end
    end

    def read_only_tool?(tool_name)
      RedmineTxMcp::ChatbotMutationWorkflow.read_only_tool?(tool_name)
    end

    def side_effecting_tool?(tool_name)
      RedmineTxMcp::ChatbotMutationWorkflow.side_effecting_tool?(tool_name)
    end

    def tool_error_result?(result)
      result.is_a?(Hash) && (result.key?(:error) || result.key?('error'))
    end

    def completion_claim_without_tool?(text)
      text.to_s.match?(/완료했|수정했|변경했|업데이트했|생성했|삭제했|할당했|옮겼|종결했|재오픈했|created|updated|deleted|assigned|closed|reopened/i)
    end

    def mutation_intent?(message)
      text = message.to_s.downcase
      PROFILE_KEYWORDS[:issue_management].any? { |keyword| intent_keyword_match?(text, keyword) } ||
        auto_schedule_intent?(text) ||
        text.match?(/(?:^|\s)#?\d+\s*(?:을|를)?\s*(?:qa|review|done|close|closed|reopen)/i)
    end

    def assignment_intent?(message)
      text = message.to_s.downcase
      %w[담당 할당 assign assignee owner].any? { |keyword| intent_keyword_match?(text, keyword) }
    end

    def schedule_or_version_intent?(message)
      text = message.to_s.downcase
      %w[버전 version 마일스톤 milestone 스프린트 sprint 일정 기한 마감 due release].any? { |keyword| text.include?(keyword) }
    end

    def relation_intent?(message)
      text = message.to_s.downcase
      %w[선행 후행 관계 의존 의존성 blocker blocked duplicate duplicates duplicated relates related 링크 연결 unlink].any? { |keyword| text.include?(keyword) }
    end

    def auto_schedule_intent?(message)
      message.to_s.match?(/자동\s*(?:일정|배치|스케줄|스케줄링)|일정\s*자동|스케줄\s*자동|auto[\s-]*schedule/i)
    end

    def parent_issue_progress_scope?(message)
      text = message.to_s
      asks_parent = text.match?(/부모\s*이슈|상위\s*이슈|하위\s*일감|자식\s*일감|children?|parent/i)
      asks_progress = schedule_or_version_intent?(text) || text.match?(/진행|현황|지연|progress|schedule/i)
      asks_parent && asks_progress
    end

    def bulk_operation_intent?(message)
      text = message.to_s
      text.match?(/일괄|대량|bulk|batch|한꺼번에|한번에|여러\s*(?:개|건|이슈)|모두|전체|전부/i) ||
        requested_issue_count(text) >= 3
    end

    def calculation_intent?(message)
      text = message.to_s.downcase
      SCRIPT_TOOL_KEYWORDS.any? { |keyword| intent_keyword_match?(text, keyword) }
    end

    def requested_issue_count(message)
      message.to_s.scan(
        /#\d+|(?:이슈|issue)\s*#?\d+|\b\d+\s*번(?=\s|[[:punct:]]|$|[은는이가을를의도만에로와과랑])/i
      ).map { |token| token.to_s.scan(/\d+/).first }.uniq.size
    end

    def intent_keyword_match?(message, keyword)
      key = keyword.to_s.downcase
      return false if key.blank?
      return message.match?(/\b#{Regexp.escape(key)}\b/i) if key.ascii_only?

      message.include?(key)
    end

    def workspace_context_summary
      return nil unless @workspace_context.is_a?(Hash)

      user_id = @workspace_context[:user_id] || @workspace_context['user_id']
      project_id = @workspace_context[:project_id] || @workspace_context['project_id']
      session_id = @workspace_context[:session_id] || @workspace_context['session_id']
      return nil unless user_id && project_id && session_id

      workspace = RedmineTxMcp::ChatbotWorkspace.new(
        user_id: user_id,
        project_id: project_id,
        session_id: session_id
      )
      uploads = workspace.list_uploads.map { |file| "#{file[:stored_name]} (#{file[:size_label]})" }
      reports = workspace.list_reports.map { |file| "#{file[:stored_name]} (#{file[:size_label]})" }

      lines = ['Current chatbot workspace is isolated to this user/session.']
      lines << "Uploaded files: #{uploads.any? ? uploads.join(', ') : 'none'}"
      lines << "Generated reports: #{reports.any? ? reports.join(', ') : 'none'}"
      lines.join("\n")
    rescue => e
      RedmineTxMcp::ChatbotLogger.log_error(
        session_id: conversation_id,
        context: 'agent_sdk_workspace_context_summary',
        error_class: e.class,
        message: e.message,
        backtrace: e.backtrace
      )
      nil
    end

    def agent_sdk_cwd
      session_id = @workspace_context && (@workspace_context[:session_id] || @workspace_context['session_id'])
      File.join(Rails.root, 'tmp', 'redmine_tx_mcp', 'agent_sdk', "session-#{session_id.presence || conversation_id}")
    end

    def worker_env
      {
        'ANTHROPIC_API_KEY' => @api_key.to_s,
        'PYTHONUNBUFFERED' => '1'
      }
    end

    def python_path
      chatbot_settings['agent_sdk_python_path'].presence ||
        ENV['REDMINE_TX_MCP_AGENT_SDK_PYTHON'].presence ||
        'python3'
    end

    def worker_path
      chatbot_settings['agent_sdk_worker_path'].presence ||
        ENV['REDMINE_TX_MCP_AGENT_SDK_WORKER'].presence ||
        DEFAULT_WORKER_PATH
    end

    def configured_max_run_seconds
      configured = (chatbot_settings['max_run_seconds'].to_i rescue 0)
      configured.positive? ? configured : 180
    end

    def configured_max_turns(user_message = nil)
      explicit = (chatbot_settings['max_loop_iterations'].to_i rescue 0)
      return explicit if explicit.positive?

      depth = (chatbot_settings['max_tool_call_depth'].to_i rescue 0)
      base = depth.positive? ? depth : 15

      return [base, MIN_BULK_TOOL_CALL_BUDGET].max if bulk_operation_intent?(user_message)
      if matched_profiles_for(user_message.to_s.downcase).any? { |profile| %i[bug_analysis version_progress].include?(profile) }
        return [base, MIN_COMPLEX_READ_TOOL_CALL_BUDGET].max
      end

      base
    end

    def configured_max_write_tools(user_message = nil)
      bulk_operation_intent?(user_message) ? BULK_MAX_WRITE_TOOL_CALLS : DEFAULT_MAX_WRITE_TOOL_CALLS
    end

    def chatbot_settings
      Setting.plugin_redmine_tx_mcp || {}
    end

    def symbolize_event(event)
      event.each_with_object({}) { |(key, value), memo| memo[key.to_sym] = value }
    end

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(key, value), memo| memo[key] = deep_dup(value) }
      when Array then obj.map { |value| deep_dup(value) }
      else obj
      end
    end
  end
end
