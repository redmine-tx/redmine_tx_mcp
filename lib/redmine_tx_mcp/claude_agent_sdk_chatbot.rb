require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'timeout'

module RedmineTxMcp
  class ClaudeAgentSdkChatbot
    TOKEN_CACHE_PREFIX = 'redmine_tx_mcp:chatbot_agent_sdk_token'.freeze
    DEFAULT_WORKER_PATH = File.expand_path('../../bin/chatbot_agent_sdk_worker.py', __dir__).freeze
    DEFAULT_MCP_SERVER_NAME = 'redmine'.freeze

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
          'agent_sdk_session_id' => @agent_sdk_session_id
        }
      }
    end

    def restore_session_state(snapshot)
      return unless snapshot.is_a?(Hash)

      restored_id = snapshot['conversation_id'] || snapshot[:conversation_id]
      @conversation_id = restored_id.to_s if restored_id.present?

      agent_state = snapshot['agent_state'] || snapshot[:agent_state] || {}
      @agent_sdk_session_id = agent_state['agent_sdk_session_id'] || agent_state[:agent_sdk_session_id]
    end

    private

    def run_worker(user_message, user:)
      token = register_agent_token(user)
      payload = worker_payload(user_message, token, user)
      final_message = nil
      error_message = nil

      each_worker_event(payload) do |event|
        case event['type']
        when 'session'
          @agent_sdk_session_id = event['session_id'].to_s if event['session_id'].present?
          next
        when 'answer'
          final_message = event['message'].to_s
        when 'error'
          error_message ||= event['message'].to_s
          next
        when 'done'
          next if final_message.blank? && error_message.present?
        end

        yield(symbolize_event(event)) if block_given?
      end

      raise(error_message) if final_message.blank? && error_message.present?

      final_message
    ensure
      Rails.cache.delete(self.class.token_cache_key(token)) if token.present?
    end

    def worker_payload(user_message, token, user)
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
        max_turns: configured_max_turns,
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
        Do not claim that Redmine data was changed unless a write tool succeeded and you verified the result with a read tool.
      PROMPT
      parts.join("\n\n")
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

    def configured_max_turns
      explicit = (chatbot_settings['max_loop_iterations'].to_i rescue 0)
      return explicit if explicit.positive?

      depth = (chatbot_settings['max_tool_call_depth'].to_i rescue 0)
      depth.positive? ? depth : 15
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
