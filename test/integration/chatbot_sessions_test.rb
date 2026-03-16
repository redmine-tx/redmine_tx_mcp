require File.expand_path('../test_helper', __dir__)

class ChatbotSessionsTest < Redmine::IntegrationTest
  def teardown
    ActionController::Base.allow_forgery_protection = false
    RedmineTxMcp::ChatbotConversation.find_each do |conversation|
      RedmineTxMcp::ChatbotWorkspace.new(
        user_id: conversation.user_id,
        project_id: conversation.project_id,
        session_id: conversation.session_id
      ).clear!
    end
    RedmineTxMcp::ChatbotConversation.delete_all
  end

  test "chatbot landing page does not create a placeholder conversation" do
    log_user('admin', 'admin')
    project = Project.find(1)
    session_key = :"chatbot_session_#{project.id}"

    get project_chatbot_path(project)
    assert_response :success

    assert_nil session[session_key]
    assert_equal 0, user_project_conversations(project).count
    assert_select '#chat-session-heading', /새 대화/
    assert_select '#chat-session-list .chat-session-link', 0
  end

  test "new conversation button clears the active session without creating a placeholder" do
    log_user('admin', 'admin')
    project = Project.find(1)
    session_key = :"chatbot_session_#{project.id}"
    conversation = create_chat_conversation(project, title: '기존 대화')

    get project_chatbot_path(project, conversation: conversation.session_id)
    assert_response :success
    assert_equal conversation.session_id, session[session_key]

    post create_chatbot_conversation_path(project)
    follow_redirect!
    assert_response :success

    assert_nil session[session_key]
    assert_equal 1, user_project_conversations(project).count
    assert_select '#chat-session-heading', /새 대화/
    assert_select '#chat-session-list .chat-session-link', 1
  end

  test "empty placeholder sessions are removed on landing" do
    log_user('admin', 'admin')
    project = Project.find(1)

    RedmineTxMcp::ChatbotConversation.create!(
      user_id: User.find(1).id,
      project_id: project.id,
      session_id: SecureRandom.hex(8),
      title: '새 대화'
    )

    get project_chatbot_path(project)
    assert_response :success

    assert_equal 0, user_project_conversations(project).count
    assert_select '#chat-session-list .chat-session-link', 0
  end

  test "upload-only submit creates a fresh conversation on demand" do
    log_user('admin', 'admin')
    project = Project.find(1)
    existing = create_chat_conversation(project, title: '기존 대화')

    post chat_submit_chatbot_path(project), params: {
      new_conversation: '1',
      files: [uploaded_test_file('import_issues.csv', 'text/csv')]
    }
    assert_response :success

    session_id = session[:"chatbot_session_#{project.id}"]
    assert session_id.present?
    assert_not_equal existing.session_id, session_id
    assert RedmineTxMcp::ChatbotConversation.find_by(session_id: session_id)
  end

  test "upload-only submit uses explicit conversation instead of the active cookie session" do
    log_user('admin', 'admin')
    project = Project.find(1)
    first = create_chat_conversation(project, title: '첫 대화')
    second = create_chat_conversation(project, title: '둘째 대화', touched_at: 1.minute.ago)

    get project_chatbot_path(project, conversation: second.session_id)
    assert_response :success
    assert_equal second.session_id, session[:"chatbot_session_#{project.id}"]

    post chat_submit_chatbot_path(project), params: {
      conversation: first.session_id,
      files: [uploaded_test_file('import_issues.csv', 'text/csv')]
    }
    assert_response :success

    first_workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: User.find(1).id, project_id: project.id, session_id: first.session_id)
    second_workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: User.find(1).id, project_id: project.id, session_id: second.session_id)

    assert_equal 1, first_workspace.list_uploads.size
    assert_equal 0, second_workspace.list_uploads.size
  end

  test "download report uses explicit conversation parameter" do
    log_user('admin', 'admin')
    project = Project.find(1)
    conversation = create_chat_conversation(project, title: '리포트 대화')

    workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: User.find(1).id, project_id: project.id, session_id: conversation.session_id)
    report = workspace.save_report(file_name: 'summary.xlsx', content: 'fake-xlsx')

    get chatbot_report_download_path(project, filename: report[:stored_name], conversation: conversation.session_id)
    assert_response :success
    assert_equal 'fake-xlsx', response.body
  end

  test "conversation page restores persisted messages when cache entry is gone" do
    log_user('admin', 'admin')
    project = Project.find(1)
    session_id = SecureRandom.hex(8)

    RedmineTxMcp::ChatbotConversation.create!(
      user_id: User.find(1).id,
      project_id: project.id,
      session_id: session_id,
      title: '복구 테스트',
      last_message_at: Time.current,
      display_history_data: JSON.generate([{ 'role' => 'assistant', 'content' => '복구된 응답', 'timestamp' => '10:00' }]),
      chatbot_state_data: JSON.generate({ 'conversation_id' => 'restore-1', 'conversation_history' => [] })
    )

    get project_chatbot_path(project, conversation: session_id)
    assert_response :success
    assert_select '#chat-messages', /복구된 응답/
  end

  test "hidden projects are not accessible through the chatbot page" do
    log_user('someone', 'foo')

    get project_chatbot_path(2)

    assert_response :not_found
  end

  test "visible projects still require chatbot permission" do
    log_user('someone', 'foo')

    get project_chatbot_path(1)

    assert_response :forbidden
  end

  test "chat submit enforces csrf protection" do
    log_user('admin', 'admin')
    ActionController::Base.allow_forgery_protection = true
    project = Project.find(1)

    post chat_submit_chatbot_path(project), params: { message: 'hello' }

    assert_response 422
    payload = JSON.parse(response.body)
    assert_equal 'invalid_authenticity_token', payload['code']
    assert payload['error'].present?
  end

  test "upload-only submit is persisted in conversation history" do
    log_user('admin', 'admin')
    project = Project.find(1)

    post chat_submit_chatbot_path(project), params: {
      files: [uploaded_test_file('import_issues.csv', 'text/csv')]
    }
    assert_response :success
    session_id = session[:"chatbot_session_#{project.id}"]
    assert session_id.present?

    get project_chatbot_path(project, conversation: session_id)
    assert_response :success
    assert_select '#chat-messages', /\[파일 업로드\]/
    assert_select '#chat-messages', /업로드 완료:/

    conversation = RedmineTxMcp::ChatbotConversation.find_by!(session_id: session_id)
    history = conversation.display_history_payload.last(2)
    assert_equal %w[user assistant], history.map { |entry| entry['role'] }
  end

  test "streaming submit returns a structured error for missing conversations" do
    log_user('admin', 'admin')
    project = Project.find(1)

    post chat_submit_chatbot_path(project), params: {
      conversation: 'missing-session',
      message: 'hello'
    }, headers: {
      'Accept' => 'text/event-stream'
    }

    assert_response :not_found
    assert_equal 'text/event-stream', response.media_type
    assert_includes response.body, '"code":"conversation_not_found"'
    assert_includes response.body, '"type":"error"'
  end

  test "missing conversations on reset redirect the user back to the chatbot" do
    log_user('admin', 'admin')
    project = Project.find(1)

    post reset_chatbot_path(project), params: { conversation: 'missing-session' }

    assert_response :not_found
    payload = JSON.parse(response.body)
    assert_equal 'conversation_not_found', payload['code']
    assert_equal project_chatbot_path(project), payload['redirect_url']
  end

  test "landing page reuses the most recent conversation instead of creating a placeholder" do
    log_user('admin', 'admin')
    project = Project.find(1)
    older = create_chat_conversation(project, title: '이전 대화', touched_at: 1.hour.ago)
    recent = create_chat_conversation(project, title: '최근 대화', touched_at: Time.current)

    get project_chatbot_path(project)
    assert_response :success

    assert_equal recent.session_id, session[:"chatbot_session_#{project.id}"]
    assert_equal 2, user_project_conversations(project).count
    assert_select '#chat-session-heading', /최근 대화/
  end

  test "stale session cookie clears the active session without auto-creating a replacement" do
    log_user('admin', 'admin')
    project = Project.find(1)
    session_key = :"chatbot_session_#{project.id}"
    conversation = create_chat_conversation(project, title: '삭제될 대화')

    get project_chatbot_path(project, conversation: conversation.session_id)
    assert_response :success
    stale_session_id = session[session_key]

    RedmineTxMcp::ChatbotConversation.find_by!(session_id: stale_session_id).destroy!

    get project_chatbot_path(project, new_conversation: '1')
    assert_response :success

    assert_nil session[session_key]
    assert_nil RedmineTxMcp::ChatbotConversation.find_by(session_id: stale_session_id)
    assert_equal 0, user_project_conversations(project).count
  end

  private

  def user_project_conversations(project)
    RedmineTxMcp::ChatbotConversation.where(user_id: User.find(1).id, project_id: project.id)
  end

  def create_chat_conversation(project, title:, touched_at: Time.current)
    RedmineTxMcp::ChatbotConversation.create!(
      user_id: User.find(1).id,
      project_id: project.id,
      session_id: SecureRandom.hex(8),
      title: title,
      last_message_at: touched_at,
      display_history_data: JSON.generate([
        { 'role' => 'assistant', 'content' => title, 'timestamp' => touched_at.iso8601 }
      ]),
      chatbot_state_data: JSON.generate({ 'conversation_id' => "restore-#{SecureRandom.hex(4)}", 'conversation_history' => [] })
    )
  end
end
