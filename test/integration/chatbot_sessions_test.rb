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

  test "new conversation creates and switches the active session" do
    log_user('admin', 'admin')
    project = Project.find(1)
    session_key = :"chatbot_session_#{project.id}"

    get project_chatbot_path(project)
    assert_response :success
    first_session_id = session[session_key]

    assert first_session_id.present?
    assert_select '#chat-session-list .chat-session-link.active', 1
    assert_equal 1, RedmineTxMcp::ChatbotConversation.where(user_id: User.find(1).id, project_id: project.id).count

    post create_chatbot_conversation_path(project)
    follow_redirect!
    assert_response :success

    second_session_id = session[session_key]
    assert second_session_id.present?
    assert_not_equal first_session_id, second_session_id
    assert_select '#chat-session-list .chat-session-link', minimum: 2
    assert_select '#chat-session-list .chat-session-link.active', 1

    get project_chatbot_path(project, conversation: first_session_id)
    assert_response :success
    assert_equal first_session_id, session[session_key]
    assert_select '#chat-session-heading', /새 대화/
  end

  test "upload-only submit uses explicit conversation instead of the active cookie session" do
    log_user('admin', 'admin')
    project = Project.find(1)

    get project_chatbot_path(project)
    assert_response :success
    first_session_id = session[:"chatbot_session_#{project.id}"]

    post create_chatbot_conversation_path(project)
    follow_redirect!
    assert_response :success
    second_session_id = session[:"chatbot_session_#{project.id}"]

    assert_not_equal first_session_id, second_session_id

    post chat_submit_chatbot_path(project), params: {
      conversation: first_session_id,
      files: [uploaded_test_file('import_issues.csv', 'text/csv')]
    }
    assert_response :success

    first_workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: User.find(1).id, project_id: project.id, session_id: first_session_id)
    second_workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: User.find(1).id, project_id: project.id, session_id: second_session_id)

    assert_equal 1, first_workspace.list_uploads.size
    assert_equal 0, second_workspace.list_uploads.size
  end

  test "download report uses explicit conversation parameter" do
    log_user('admin', 'admin')
    project = Project.find(1)

    get project_chatbot_path(project)
    assert_response :success
    first_session_id = session[:"chatbot_session_#{project.id}"]

    post create_chatbot_conversation_path(project)
    follow_redirect!
    assert_response :success

    workspace = RedmineTxMcp::ChatbotWorkspace.new(user_id: User.find(1).id, project_id: project.id, session_id: first_session_id)
    report = workspace.save_report(file_name: 'summary.xlsx', content: 'fake-xlsx')

    get chatbot_report_download_path(project, filename: report[:stored_name], conversation: first_session_id)
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

    get project_chatbot_path(project)
    assert_response :success
    session_id = session[:"chatbot_session_#{project.id}"]

    post chat_submit_chatbot_path(project), params: {
      conversation: session_id,
      files: [uploaded_test_file('import_issues.csv', 'text/csv')]
    }
    assert_response :success

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

  test "stale session cookie starts a new conversation instead of reviving the deleted one" do
    log_user('admin', 'admin')
    project = Project.find(1)
    session_key = :"chatbot_session_#{project.id}"

    get project_chatbot_path(project)
    assert_response :success
    stale_session_id = session[session_key]

    RedmineTxMcp::ChatbotConversation.find_by!(session_id: stale_session_id).destroy!

    get project_chatbot_path(project)
    assert_response :success

    fresh_session_id = session[session_key]
    assert fresh_session_id.present?
    assert_not_equal stale_session_id, fresh_session_id
    assert_nil RedmineTxMcp::ChatbotConversation.find_by(session_id: stale_session_id)
    assert RedmineTxMcp::ChatbotConversation.find_by(session_id: fresh_session_id)
  end
end
