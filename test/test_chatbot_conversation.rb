require File.expand_path('test_helper', __dir__)

class ChatbotConversationTest < ActiveSupport::TestCase
  def teardown
    RedmineTxMcp::ChatbotConversation.delete_all
  end

  test "uses placeholder title until the first activity" do
    conversation = RedmineTxMcp::ChatbotConversation.create!(
      user_id: 1,
      project_id: 1,
      session_id: SecureRandom.hex(8)
    )

    assert_equal '새 대화', conversation.display_title

    conversation.touch_activity!(title_hint: '로그인 오류 원인 분석해줘')
    assert_equal '로그인 오류 원인 분석해줘', conversation.reload.display_title

    conversation.touch_activity!(title_hint: '다른 질문')
    assert_equal '로그인 오류 원인 분석해줘', conversation.reload.display_title
  end

  test "recent scope orders by last activity" do
    older = RedmineTxMcp::ChatbotConversation.create!(
      user_id: 1,
      project_id: 1,
      session_id: SecureRandom.hex(8),
      title: '예전 대화',
      last_message_at: 2.days.ago
    )
    newer = RedmineTxMcp::ChatbotConversation.create!(
      user_id: 1,
      project_id: 1,
      session_id: SecureRandom.hex(8),
      title: '최근 대화',
      last_message_at: 1.hour.ago
    )

    result = RedmineTxMcp::ChatbotConversation.for_user_project(user_id: 1, project_id: 1).to_a

    assert_equal [newer.id, older.id], result.map(&:id)
  end

  test "persist_snapshot stores and restores structured payloads" do
    conversation = RedmineTxMcp::ChatbotConversation.create!(
      user_id: 1,
      project_id: 1,
      session_id: SecureRandom.hex(8)
    )

    display_history = [{ 'role' => 'user', 'content' => 'hello', 'timestamp' => '10:00' }]
    chatbot_state = { 'conversation_id' => 'abc123', 'conversation_history' => [{ 'role' => 'user', 'content' => 'hello' }] }

    conversation.persist_snapshot!(
      display_history: display_history,
      chatbot_state: chatbot_state,
      title_hint: 'hello'
    )

    conversation.reload
    assert_equal display_history, conversation.display_history_payload
    assert_equal chatbot_state, conversation.chatbot_state_payload
    assert_equal 'hello', conversation.display_title
  end
end
