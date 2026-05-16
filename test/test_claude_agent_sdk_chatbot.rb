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
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_get',
        'input' => { 'id' => 123 },
        'content' => { 'id' => 123, 'status' => { 'id' => 1, 'name' => 'New' } }
      )
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
    assert_equal 1, captured_payload[:max_write_tools]
    assert_includes captured_payload[:allowed_tool_names], 'issue_get'
    refute_includes captured_payload[:allowed_tool_names], 'issue_update'
    refute_includes captured_payload[:allowed_tool_names], 'run_script'
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
      block.call('type' => 'tool_call', 'tool' => 'project_get', 'status' => '프로젝트를 조회 중입니다.')
      block.call(
        'type' => 'tool_result',
        'tool' => 'project_get',
        'input' => { 'id' => 1 },
        'content' => { 'project' => { 'id' => 1, 'name' => 'Project 1' } }
      )
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
    assert_equal %w[phase tool_call tool_result answer done], events.map { |event| event[:type] }
    assert_equal 1, captured_payload[:max_write_tools]
    assert_includes captured_payload[:allowed_tool_names], 'project_get'
    refute_includes captured_payload[:allowed_tool_names], 'project_update'
    refute_includes captured_payload[:allowed_tool_names], 'run_script'
    assert_equal '기본 질의 응답입니다.', events.find { |event| event[:type] == 'answer' }[:message]
    assert_equal 'sdk-stream', chatbot.export_session_state.dig('agent_state', 'agent_sdk_session_id')
  end

  test "chat rejects Redmine data answers without MCP tool result evidence" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'hallucination-guard')

    worker = proc do |_payload, &block|
      block.call('type' => 'phase', 'phase' => 'analysis', 'status' => '분석 중입니다.')
      block.call('type' => 'answer', 'message' => '현재 버그는 3건입니다.')
      block.call('type' => 'done')
    end

    RedmineTxMcp::ChatbotLogger.stub(:log_error, nil) do
      chatbot.stub(:each_worker_event, worker) do
        result = chatbot.chat('버그현황 알려줘', user: User.find(7))

        assert_equal false, result[:success]
        assert_match(/MCP 조회 결과 없이 생성된 답변/, result[:error])
      end
    end
  end

  test "chat rejects Redmine data answers when MCP tool result is an error" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'failed-tool-result')

    worker = proc do |_payload, &block|
      block.call('type' => 'tool_result', 'tool' => 'redmine', 'is_error' => true)
      block.call('type' => 'answer', 'message' => '현재 버그는 3건입니다.')
      block.call('type' => 'done')
    end

    RedmineTxMcp::ChatbotLogger.stub(:log_error, nil) do
      chatbot.stub(:each_worker_event, worker) do
        result = chatbot.chat('버그현황 알려줘', user: User.find(7))

        assert_equal false, result[:success]
        assert_match(/MCP 조회 결과 없이 생성된 답변/, result[:error])
      end
    end
  end

  test "chat rejects Redmine data answers when MCP evidence is unrelated to the question" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'unrelated-evidence')

    worker = proc do |_payload, &block|
      block.call(
        'type' => 'tool_result',
        'tool' => 'project_get',
        'input' => { 'id' => 1 },
        'content' => { 'project' => { 'id' => 1, 'name' => 'Project 1' } }
      )
      block.call('type' => 'answer', 'message' => '현재 버그는 3건입니다.')
      block.call('type' => 'done')
    end

    RedmineTxMcp::ChatbotLogger.stub(:log_error, nil) do
      chatbot.stub(:each_worker_event, worker) do
        result = chatbot.chat('버그현황 알려줘', user: User.find(7))

        assert_equal false, result[:success]
        assert_match(/관련된 Redmine MCP 조회 결과 없이 생성된 답변/, result[:error])
      end
    end
  end

  test "chat allows Redmine data answers with relevant MCP evidence" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'relevant-evidence')

    worker = proc do |_payload, &block|
      block.call(
        'type' => 'tool_result',
        'tool' => 'bug_statistics',
        'input' => { 'project_id' => 1 },
        'content' => { 'total' => 3 }
      )
      block.call('type' => 'answer', 'message' => '현재 버그는 3건입니다.')
      block.call('type' => 'done')
    end

    chatbot.stub(:each_worker_event, worker) do
      result = chatbot.chat('버그현황 알려줘', user: User.find(7))

      assert_equal true, result[:success]
      assert_equal '현재 버그는 3건입니다.', result[:message]
    end
  end

  test "chat rejects mutation completion claims without a successful write tool" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'mutation-no-write')

    worker = proc do |_payload, &block|
      block.call('type' => 'tool_result', 'tool' => 'issue_get', 'input' => { 'id' => 123 }, 'content' => { 'id' => 123 })
      block.call('type' => 'answer', 'message' => '이슈 123 상태를 변경했습니다.')
      block.call('type' => 'done')
    end

    RedmineTxMcp::ChatbotLogger.stub(:log_error, nil) do
      chatbot.stub(:each_worker_event, worker) do
        result = chatbot.chat('이슈 123 상태를 QA로 변경해줘', user: User.find(7))

        assert_equal false, result[:success]
        assert_match(/변경 도구의 성공 결과 없이 완료로 답변/, result[:error])
      end
    end
  end

  test "chat rejects mutation completion claims until read back verification passes" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'mutation-needs-verify')

    worker = proc do |_payload, &block|
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_update',
        'input' => { 'id' => 123, 'status_id' => 5 },
        'content' => { 'issue' => { 'id' => 123 } }
      )
      block.call('type' => 'answer', 'message' => '이슈 123 상태를 변경했습니다.')
      block.call('type' => 'done')
    end

    RedmineTxMcp::ChatbotLogger.stub(:log_error, nil) do
      chatbot.stub(:each_worker_event, worker) do
        result = chatbot.chat('이슈 123 상태를 QA로 변경해줘', user: User.find(7))

        assert_equal false, result[:success]
        assert_match(/read-back 검증/, result[:error])
      end
    end
  end

  test "chat allows mutation completion claims after successful read back verification" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'mutation-verified')

    worker = proc do |_payload, &block|
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_update',
        'input' => { 'id' => 123, 'status_id' => 5 },
        'content' => { 'issue' => { 'id' => 123 } }
      )
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_get',
        'input' => { 'id' => 123 },
        'content' => { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
      )
      block.call('type' => 'answer', 'message' => '이슈 123 상태를 변경했습니다.')
      block.call('type' => 'done')
    end

    chatbot.stub(:each_worker_event, worker) do
      result = chatbot.chat('이슈 123 상태를 QA로 변경해줘', user: User.find(7))

      assert_equal true, result[:success]
      assert_equal '이슈 123 상태를 변경했습니다.', result[:message]
    end
  end

  test "pending mutation follow up exposes only read back verification tools" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'mutation-follow-up-tools')

    first_worker = proc do |_payload, &block|
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_get',
        'input' => { 'id' => 123 },
        'content' => { 'id' => 123, 'status' => { 'id' => 1, 'name' => 'New' } }
      )
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_update',
        'input' => { 'id' => 123, 'status_id' => 5 },
        'content' => { 'issue' => { 'id' => 123 } }
      )
      block.call('type' => 'answer', 'message' => 'read-back 검증이 필요합니다.')
      block.call('type' => 'done')
    end

    chatbot.stub(:each_worker_event, first_worker) do
      result = chatbot.chat('이슈 123 상태를 QA로 변경해줘', user: User.find(7))

      assert_equal true, result[:success]
    end

    captured_payload = nil
    second_worker = proc do |payload, &block|
      captured_payload = payload
      block.call(
        'type' => 'tool_result',
        'tool' => 'issue_get',
        'input' => { 'id' => 123 },
        'content' => { 'id' => 123, 'status' => { 'id' => 5, 'name' => 'QA' } }
      )
      block.call('type' => 'answer', 'message' => '이슈 123 상태를 변경했습니다.')
      block.call('type' => 'done')
    end

    chatbot.stub(:each_worker_event, second_worker) do
      result = chatbot.chat('계속 확인해줘', user: User.find(7))

      assert_equal true, result[:success]
      assert_equal '이슈 123 상태를 변경했습니다.', result[:message]
    end

    assert_equal %w[issue_get], captured_payload[:allowed_tool_names]
  end

  test "bulk mutation payload permits multiple verified write steps" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )

    payload = chatbot.send(
      :worker_payload,
      '이슈 #123 #124 #125 상태를 QA로 일괄 변경해줘',
      'test-token',
      User.find(7)
    )

    assert_equal 3, payload[:max_write_tools]
    assert_operator payload[:max_turns], :>=, 30
    assert_includes payload[:allowed_tool_names], 'issue_bulk_update'
    assert_includes payload[:allowed_tool_names], 'issue_update'
  end

  test "chat allows non data answers without MCP tool result evidence" do
    chatbot = RedmineTxMcp::ClaudeAgentSdkChatbot.new(
      api_key: 'anthropic-test-key',
      model: 'claude-sonnet-4-6',
      project_id: 1,
      mcp_url: 'http://redmine.test/mcp/http'
    )
    chatbot.set_workspace_context(user_id: 7, project_id: 1, session_id: 'small-talk')

    worker = proc do |_payload, &block|
      block.call('type' => 'answer', 'message' => '안녕하세요.')
      block.call('type' => 'done')
    end

    chatbot.stub(:each_worker_event, worker) do
      result = chatbot.chat('안녕', user: User.find(7))

      assert_equal true, result[:success]
      assert_equal '안녕하세요.', result[:message]
    end
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
      assert_includes events.map { |event| event['type'] }, 'tool_result'
      assert_equal '기본 질의 응답입니다.', events.find { |event| event['type'] == 'answer' }['message']
      assert_equal 'done', events.last['type']
    end
  end

  test "worker permission guard enforces selected tools and read before write" do
    Dir.mktmpdir('fake-claude-agent-sdk') do |tmpdir|
      sdk_dir = File.join(tmpdir, 'claude_agent_sdk')
      FileUtils.mkdir_p(sdk_dir)
      File.write(File.join(sdk_dir, '__init__.py'), fake_claude_agent_sdk)

      request = {
        message: '이슈 123 상태를 QA로 변경해줘',
        model: 'claude-sonnet-4-6',
        system_prompt: 'Permission guard prompt',
        mcp_server_name: 'redmine',
        mcp_url: 'http://redmine.test/mcp/http',
        mcp_headers: { 'X-Redmine-Tx-Mcp-Chatbot-Token' => 'test-token' },
        cwd: tmpdir,
        max_turns: 3,
        allowed_tool_names: %w[issue_get issue_update],
        max_write_tools: 2,
        mutation_requires_read: true
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
      assert_equal 'permission guard ok', events.find { |event| event['type'] == 'answer' }['message']
      assert_equal 'issue_get', events.find { |event| event['type'] == 'tool_result' }['tool']
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
          if options.kwargs.get("system_prompt") == "Permission guard prompt":
              if options.kwargs.get("permission_mode") != "default":
                  raise RuntimeError("expected default permission mode for can_use_tool callback")

              write_before_read = await can_use_tool("mcp__redmine__issue_update", {"id": 123}, None)
              disallowed = await can_use_tool("mcp__redmine__project_delete", {"id": 1}, None)
              read_allowed = await can_use_tool("mcp__redmine__issue_get", {"id": 123}, None)
              if write_before_read.__class__.__name__ != "PermissionResultDeny":
                  raise RuntimeError("expected write before read to be denied")
              if disallowed.__class__.__name__ != "PermissionResultDeny":
                  raise RuntimeError("expected non-selected tool to be denied")
              if read_allowed.__class__.__name__ != "PermissionResultAllow":
                  raise RuntimeError("expected selected read tool to be allowed")

              yield SimpleNamespace(
                  type="assistant",
                  content=[SimpleNamespace(type="tool_use", id="read-1", name="mcp__redmine__issue_get", input={"id": 123})],
              )
              yield SimpleNamespace(
                  type="user",
                  content=[SimpleNamespace(type="tool_result", tool_use_id="read-1", content='{"id":123}')],
              )

              write_after_read = await can_use_tool("mcp__redmine__issue_update", {"id": 123}, None)
              if write_after_read.__class__.__name__ != "PermissionResultAllow":
                  raise RuntimeError("expected write after read to be allowed")

              second_write_without_readback = await can_use_tool("mcp__redmine__issue_update", {"id": 124}, None)
              if second_write_without_readback.__class__.__name__ != "PermissionResultDeny":
                  raise RuntimeError("expected second write before read-back to be denied")

              yield SimpleNamespace(
                  type="assistant",
                  content=[SimpleNamespace(type="tool_use", id="read-2", name="mcp__redmine__issue_get", input={"id": 123})],
              )
              yield SimpleNamespace(
                  type="user",
                  content=[SimpleNamespace(type="tool_result", tool_use_id="read-2", content='{"id":123}')],
              )

              second_write_after_readback = await can_use_tool("mcp__redmine__issue_update", {"id": 124}, None)
              if second_write_after_readback.__class__.__name__ != "PermissionResultAllow":
                  raise RuntimeError("expected second write after read-back to be allowed")

              yield SimpleNamespace(
                  type="assistant",
                  content=[SimpleNamespace(type="tool_use", id="read-3", name="mcp__redmine__issue_get", input={"id": 124})],
              )
              yield SimpleNamespace(
                  type="user",
                  content=[SimpleNamespace(type="tool_result", tool_use_id="read-3", content='{"id":124}')],
              )

              third_write_after_budget = await can_use_tool("mcp__redmine__issue_update", {"id": 125}, None)
              if third_write_after_budget.__class__.__name__ != "PermissionResultDeny":
                  raise RuntimeError("expected third write beyond max_write_tools to be denied")

              yield SimpleNamespace(
                  type="result",
                  session_id="sdk-permission-session",
                  is_error=False,
                  result="permission guard ok",
                  num_turns=1,
                  stop_reason="end_turn",
                  total_cost_usd=0,
                  usage={},
              )
              return

          allowed = await can_use_tool("mcp__redmine__issue_list", {}, None)
          denied = await can_use_tool("Bash", {}, None)
          if allowed.__class__.__name__ != "PermissionResultAllow":
              raise RuntimeError("expected Redmine MCP read tool to be allowed")
          if denied.__class__.__name__ != "PermissionResultDeny":
              raise RuntimeError("expected non-MCP tool to be denied")

          yield SimpleNamespace(type="system", subtype="init", data={"session_id": "sdk-basic-session"})
          yield SimpleNamespace(type="assistant", content=[SimpleNamespace(type="text", text="응답")])
          yield SimpleNamespace(type="user", content=[SimpleNamespace(tool_use_id="tool-1", content="{}")])
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
