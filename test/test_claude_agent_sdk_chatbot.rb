require_relative 'support/chatbot_unit_helper'

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

    exported = chatbot.export_session_state
    assert_equal 'sdk-new', exported.dig('agent_state', 'agent_sdk_session_id')
    assert_equal 'claude_agent_sdk', exported.dig('agent_state', 'adapter')
  end
end
