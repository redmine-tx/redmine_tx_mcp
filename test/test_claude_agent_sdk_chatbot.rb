require_relative 'support/chatbot_unit_helper'
require 'open3'
require 'tmpdir'

class ClaudeAgentSdkChatbotTest < ActiveSupport::TestCase
  test "chat delegates to the agent sdk worker and persists sdk session id" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'chat-1')
    chatbot.restore_session_state(
      'conversation_id' => 'conversation-1',
      'agent_state' => { 'agent_sdk_session_id' => 'sdk-old' }
    )

    captured_payload = nil
    worker = proc do |payload, &block|
      captured_payload = payload
      token = payload.dig(:mcp_headers, 'X-Redmine-Tx-Mcp-Chatbot-Token')
      token_context = RedmineTxMcp::ClaudeAgentSdkChatbot.read_token_context(token)
      assert_equal 7, token_context['user_id']
      assert_equal 1, token_context['project_id']
      assert_equal 'chat-1', token_context['session_id']

      block.call('type' => 'session', 'session_id' => 'sdk-new')
      block.call('type' => 'answer', 'message' => '처리했습니다.')
      block.call('type' => 'done')
    end

    chatbot.stub(:each_worker_event, worker) do
      result = chatbot.chat('상태 확인', user: User.find(7))

      assert_equal true, result[:success]
      assert_equal '처리했습니다.', result[:message]
      assert_equal 'conversation-1', result[:conversation_id]
    end

    assert_equal 'sdk-old', captured_payload[:resume_session_id]
    assert_equal 'http://redmine.test/mcp/http', captured_payload[:mcp_url]
    assert_equal 'claude-sonnet-4-6', captured_payload[:model]
    assert_equal 15, captured_payload[:max_turns]
    assert captured_payload[:mcp_headers]['X-Redmine-Tx-Mcp-Chatbot-Token'].present?
    assert_nil RedmineTxMcp::ClaudeAgentSdkChatbot.read_token_context(
      captured_payload[:mcp_headers]['X-Redmine-Tx-Mcp-Chatbot-Token']
    )

    exported = chatbot.export_session_state
    assert_equal 'sdk-new', exported.dig('agent_state', 'agent_sdk_session_id')
    assert_equal 'claude_agent_sdk', exported.dig('agent_state', 'adapter')
  end

  test "chat_stream forwards basic query progress events" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'chat-stream')

    captured_payload = nil
    worker = proc do |payload, &block|
      captured_payload = payload
      block.call('type' => 'phase', 'phase' => 'analysis', 'status' => '분석 중입니다.')
      block.call('type' => 'tool_call', 'tool' => 'issue_list', 'status' => '이슈를 조회 중입니다.')
      block.call('type' => 'session', 'session_id' => 'sdk-stream')
      block.call('type' => 'answer', 'message' => '기본 질의 응답입니다.')
      block.call('type' => 'done')
    end

    events = []
    chatbot.stub(:each_worker_event, worker) do
      chatbot.chat_stream('프로젝트 상태 알려줘', user: User.find(7)) do |event|
        events << event
      end
    end

    assert_equal '프로젝트 상태 알려줘', captured_payload[:message]
    assert_equal %w[phase tool_call answer done], events.map { |event| event[:type] }
    assert_equal '기본 질의 응답입니다.', events.find { |event| event[:type] == 'answer' }[:message]
    assert_equal 'sdk-stream', chatbot.export_session_state.dig('agent_state', 'agent_sdk_session_id')
  end

  test "worker keeps Redmine user id out of Claude Agent SDK OS user option" do
    Dir.mktmpdir('fake-claude-agent-sdk') do |tmpdir|
      sdk_dir = File.join(tmpdir, 'claude_agent_sdk')
      FileUtils.mkdir_p(sdk_dir)
      File.write(File.join(sdk_dir, '__init__.py'), fake_claude_agent_sdk)

      request = {
        message: '기본 질의 테스트',
        model: 'claude-sonnet-4-6',
        system_prompt: 'Test prompt',
        mcp_server_name: 'redmine',
        mcp_url: 'http://redmine.test/mcp/http',
        mcp_headers: { 'X-Redmine-Tx-Mcp-Chatbot-Token' => 'test-token' },
        cwd: tmpdir,
        max_turns: 3,
        user: '4'
      }
      env = {
        'PYTHONPATH' => [tmpdir, ENV['PYTHONPATH']].compact.join(File::PATH_SEPARATOR),
        'PYTHONUNBUFFERED' => '1'
      }

      stdout, stderr, status = Open3.capture3(
        env,
        'python3',
        File.expand_path('../bin/chatbot_agent_sdk_worker.py', __dir__),
        stdin_data: JSON.generate(request)
      )

      assert status.success?, "worker failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
      assert_empty stderr

      events = stdout.lines.map { |line| JSON.parse(line) }
      assert_includes events.map { |event| event['type'] }, 'phase'
      assert_includes events.map { |event| event['type'] }, 'session'
      assert_equal '기본 질의 응답입니다.', events.find { |event| event['type'] == 'answer' }['message']
      assert_equal 'done', events.last['type']
    end
  end

  private

  def fake_claude_agent_sdk
    <<~PY
      from types import SimpleNamespace

      class PermissionResultAllow:
          pass

      class PermissionResultDeny:
          def __init__(self, message=None, interrupt=False):
              self.message = message
              self.interrupt = interrupt

      class ClaudeAgentOptions:
          def __init__(self, **kwargs):
              if "user" in kwargs:
                  raise RuntimeError("unexpected OS user option: %s" % kwargs["user"])
              self.kwargs = kwargs

      async def query(prompt, options):
          if isinstance(prompt, str):
              raise RuntimeError("prompt must be an async iterable")

          prompt_events = []
          async for event in prompt:
              prompt_events.append(event)

          if not prompt_events or prompt_events[0].get("type") != "user":
              raise RuntimeError("missing user prompt event")

          can_use_tool = options.kwargs.get("can_use_tool")
          allowed = await can_use_tool("mcp__redmine__issue_list", {}, None)
          denied = await can_use_tool("Bash", {}, None)
          if allowed.__class__.__name__ != "PermissionResultAllow":
              raise RuntimeError("expected Redmine MCP read tool to be allowed")
          if denied.__class__.__name__ != "PermissionResultDeny":
              raise RuntimeError("expected non-MCP tool to be denied")

          yield SimpleNamespace(type="system", subtype="init", data={"session_id": "sdk-basic-session"})
          yield SimpleNamespace(type="assistant", content=[SimpleNamespace(type="text", text="응답")])
          yield SimpleNamespace(
              type="result",
              session_id="sdk-basic-session",
              is_error=False,
              result="기본 질의 응답입니다.",
              num_turns=1,
              stop_reason="end_turn",
              total_cost_usd=0,
              usage={"input_tokens": 1},
          )
    PY
  end
end
