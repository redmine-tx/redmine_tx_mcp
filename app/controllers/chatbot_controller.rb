class ChatbotController < ApplicationController
  include ActionController::Live

  before_action :require_login
  before_action :find_project
  before_action :authorize_chatbot_access

  # Concurrency guard — prevent chatbot from consuming all Puma/Passenger workers
  MAX_CONCURRENT_CHATS = 2
  RECENT_CHAT_SESSION_LIMIT = 12
  MAX_PERSISTED_CHAT_SESSIONS = 30
  CHAT_SESSION_RETENTION_DAYS = 30
  @@chat_mutex = Mutex.new
  @@active_chats = 0

  def index
    @chatbot_session_id = resolve_active_session_id
    return if performed?

    @active_chat_session = ensure_chat_conversation_record(@chatbot_session_id)
    @conversation_history = get_display_history(@chatbot_session_id)
    @workspace_uploads = current_workspace(@chatbot_session_id).list_uploads
    @workspace_reports = current_workspace(@chatbot_session_id).list_reports
    @recent_chat_sessions = recent_chat_conversations
  end

  def create_conversation
    sid = start_new_chat_session
    redirect_to project_chatbot_path(@project, conversation: sid)
  end

  def chat_submit
    sid = request_chat_session_id
    return if performed?

    message = params[:message].to_s
    upload_result = process_uploaded_files(sid)

    if upload_result[:error]
      return render_chat_error(upload_result[:error], status: 422)
    end

    if message.blank? && upload_result[:saved_files].present?
      return render_upload_only_response(upload_result[:saved_files], sid)
    end

    unless acquire_chat_slot
      if wants_streaming?
        response.headers['Content-Type'] = 'text/event-stream'
        response.headers['Cache-Control'] = 'no-cache'
        write_sse_event(type: 'error', message: '서버가 바쁩니다. 잠시 후 다시 시도해주세요.')
        write_sse_event(type: 'done')
        response.stream.close
      else
        render json: { error: "서버가 바쁩니다. 잠시 후 다시 시도해주세요." }, status: 429
      end
      return
    end

    if message.blank?
      release_chat_slot
      return render_chat_error('Message cannot be empty', status: 400)
    end

    if wants_streaming?
      stream_chat_response(message, sid: sid, workspace_changed: upload_result[:saved_files].present?)
      return
    end

    begin
      chatbot = get_or_create_chatbot(sid)

      result = chatbot.chat(message, user: User.current)

      if result[:success]
        persist_chatbot_session(sid, chatbot, user_message: message, assistant_message: result[:message])

        render json: {
          success: true,
          message: result[:message],
          conversation_id: result[:conversation_id],
          workspace: workspace_payload(sid),
          sessions: sessions_payload(active_session_id: sid)
        }
      else
        render json: {
          success: false,
          error: result[:error]
        }, status: 500
      end

    rescue => e
      RedmineTxMcp::ChatbotLogger.log_error(context: "chat_submit (non-streaming)", error_class: e.class, message: e.message, backtrace: e.backtrace)
      render json: {
        success: false,
        error: "Sorry, I encountered an error. Please try again."
      }, status: 500
    ensure
      release_chat_slot
    end
  end

  def reset
    session_id = request_chat_session_id
    return if performed?

    clear_conversation_history(session_id) if session_id
    current_workspace(session_id).clear! if session_id
    delete_chat_conversation_record(session_id) if session_id
    session[session_key] = nil if session[session_key] == session_id

    render json: {
      success: true,
      message: "Conversation reset",
      redirect_url: project_chatbot_path(@project)
    }
  end

  def download_report
    sid = request_chat_session_id
    return if performed?

    workspace = current_workspace(sid)
    report = workspace.resolve_report(params[:filename])

    send_file report[:path],
              filename: report[:stored_name],
              type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              disposition: 'attachment'
  rescue ArgumentError
    render_404
  end

  private

  def handle_unverified_request
    return super unless action_name == 'chat_submit'

    cookies.delete(autologin_cookie_name)
    self.logged_user = nil
    set_localization
    render_chat_error(
      l(:error_invalid_authenticity_token),
      status: 422,
      code: 'invalid_authenticity_token'
    )
  end

  def acquire_chat_slot
    @@chat_mutex.synchronize do
      if @@active_chats >= MAX_CONCURRENT_CHATS
        RedmineTxMcp::ChatbotLogger.log_info(context: "SLOT REJECTED", detail: "#{@@active_chats}/#{MAX_CONCURRENT_CHATS} slots in use")
        false
      else
        @@active_chats += 1
        RedmineTxMcp::ChatbotLogger.log_info(context: "SLOT ACQUIRED", detail: "#{@@active_chats}/#{MAX_CONCURRENT_CHATS}")
        true
      end
    end
  end

  def release_chat_slot
    @@chat_mutex.synchronize do
      @@active_chats = [@@active_chats - 1, 0].max
      RedmineTxMcp::ChatbotLogger.log_info(context: "SLOT RELEASED", detail: "#{@@active_chats}/#{MAX_CONCURRENT_CHATS}")
    end
  end

  def session_key
    :"chatbot_session_#{@project.id}"
  end

  def resolve_active_session_id
    requested = params[:conversation].to_s.strip
    if requested.present?
      conversation = find_chat_conversation(requested)
      unless conversation
        session[session_key] = nil if session[session_key] == requested
        handle_missing_conversation
        return
      end
      session[session_key] = conversation.session_id
    end

    current_chat_session_id
  end

  def request_chat_session_id
    requested = params[:conversation].to_s.strip
    return current_chat_session_id if requested.blank?

    conversation = find_chat_conversation(requested)
    unless conversation
      session[session_key] = nil if session[session_key] == requested
      handle_missing_conversation
      return
    end

    session[session_key] = conversation.session_id
    conversation.session_id
  end

  def current_chat_session_id
    sid = session[session_key]
    return sid if sid.present? && find_chat_conversation(sid)

    session[session_key] = nil if sid.present?
    start_new_chat_session
  end

  def start_new_chat_session
    sid = SecureRandom.hex(8)
    ensure_chat_conversation_record(sid)
    session[session_key] = sid
    prune_chat_conversations!(keep_session_id: sid)
    sid
  end

  def wants_streaming?
    request.headers['Accept']&.include?('text/event-stream')
  end

  def stream_chat_response(message, sid:, workspace_changed: false)
    chatbot = get_or_create_chatbot(sid)
    current_user = User.current
    chatbot_session_id = chatbot.conversation_id

    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'
    response.headers['X-Accel-Buffering'] = 'no'

    RedmineTxMcp::ChatbotLogger.log_stream_event(
      event: :started, session_id: chatbot_session_id,
      call_count: 1, pid: Process.pid, tid: Thread.current.object_id
    )

    final_message = nil

    begin
      write_sse_event(type: 'workspace', workspace: workspace_payload(sid)) if workspace_changed

      chatbot.chat_stream(message, user: current_user) do |event|
        write_sse_event(event)
        final_message = event[:message] if event[:type] == 'answer'
      end

      if final_message
        persist_chatbot_session(sid, chatbot, user_message: message, assistant_message: final_message)
      end
      write_sse_event(type: 'workspace', workspace: workspace_payload(sid))
      write_sse_event(type: 'sessions', sessions: sessions_payload(active_session_id: sid))
    rescue => e
      RedmineTxMcp::ChatbotLogger.log_error(session_id: chatbot_session_id, context: "stream_chat_response", error_class: e.class, message: e.message, backtrace: e.backtrace)
      write_sse_event(type: 'error', message: e.message)
      write_sse_event(type: 'done')
    ensure
      release_chat_slot
      RedmineTxMcp::ChatbotLogger.log_stream_event(
        event: :finished, session_id: chatbot_session_id,
        call_count: 1, pid: Process.pid, tid: Thread.current.object_id
      )
      response.stream.close
    end
  end

  def find_project
    @project = Project.find(params[:project_id])
    render_404 unless @project.visible?(User.current)
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_chatbot_access
    return true if User.current.admin?

    deny_access unless User.current.allowed_to?(:use_chatbot, @project)
  end

  def get_or_create_chatbot(session_id = session[session_key])
    chatbot = create_new_chatbot
    restore_chatbot_session(chatbot, session_id)
    chatbot.set_workspace_context(
      user_id: User.current.id,
      project_id: @project.id,
      session_id: session_id
    )
    chatbot
  end

  def create_new_chatbot
    settings = Setting.plugin_redmine_tx_mcp || {}
    provider = settings['llm_provider'] || 'anthropic'

    if provider == 'openai'
      endpoint_url = settings['openai_endpoint_url']
      raise "OpenAI endpoint URL not configured." unless endpoint_url.present?

      api_key = settings['openai_api_key'].presence  # Optional for local LLMs
      model = settings['openai_model'] || 'default'

      RedmineTxMcp::ClaudeChatbot.new(
        api_key: api_key, model: model, project_id: @project.id,
        provider: 'openai', endpoint_url: endpoint_url
      )
    else
      api_key = settings['claude_api_key'] || ENV['ANTHROPIC_API_KEY']
      model = settings['claude_model'] || 'claude-sonnet-4-6'

      unless api_key.present?
        raise "Claude API key not configured. Please set it in MCP settings or ANTHROPIC_API_KEY environment variable."
      end

      RedmineTxMcp::ClaudeChatbot.new(api_key: api_key, model: model, project_id: @project.id)
    end
  end

  def conversation_cache_key(session_id)
    "chatbot_conversation_#{session_id}"
  end

  def default_conversation_session
    {
      'display_history' => [],
      'chatbot_state' => nil
    }
  end

  def get_conversation_session(session_id)
    return default_conversation_session unless session_id
    cache_key = conversation_cache_key(session_id)
    cached = normalize_conversation_session(Rails.cache.read(cache_key))
    return cached if conversation_session_present?(cached)

    persisted = persisted_conversation_session(session_id)
    if conversation_session_present?(persisted)
      Rails.cache.write(cache_key, persisted, expires_in: get_cache_ttl)
      return persisted
    end

    default_conversation_session
  end

  def get_display_history(session_id)
    get_conversation_session(session_id)['display_history']
  end

  def persist_chatbot_session(session_id, chatbot, user_message:, assistant_message:)
    return unless session_id

    data = get_conversation_session(session_id)
    timestamp = Time.current
    history = Array(data['display_history'])
    history << {
      'role' => 'user',
      'content' => user_message,
      'timestamp' => timestamp.iso8601
    }
    history << {
      'role' => 'assistant',
      'content' => assistant_message,
      'timestamp' => timestamp.iso8601
    }

    data['display_history'] = history.last(20)
    data['chatbot_state'] = chatbot.export_session_state

    cache_ttl = get_cache_ttl
    Rails.cache.write(conversation_cache_key(session_id), data, expires_in: cache_ttl)
    persist_chat_conversation!(
      session_id,
      display_history: data['display_history'],
      chatbot_state: data['chatbot_state'],
      title_hint: conversation_title_for_message(user_message),
      touched_at: timestamp
    )
  end

  def normalize_conversation_session(cached)
    case cached
    when Hash
      {
        'display_history' => Array(cached['display_history'] || cached[:display_history]).map { |msg| normalize_display_message(msg) }.compact,
        'chatbot_state' => cached['chatbot_state'] || cached[:chatbot_state]
      }
    when Array
      display_history = cached.map { |msg| normalize_display_message(msg) }.compact
      {
        'display_history' => display_history,
        'chatbot_state' => {
          'conversation_history' => display_history.map do |msg|
            { 'role' => msg['role'], 'content' => msg['content'] }
          end
        }
      }
    else
      default_conversation_session
    end
  end

  def normalize_display_message(msg)
    role = msg['role'] || msg[:role]
    content = msg['content'] || msg[:content]
    return nil unless role.present? && content.present?

    {
      'role' => role,
      'content' => content,
      'timestamp' => (msg['timestamp'] || msg[:timestamp] || Time.current.iso8601)
    }
  end

  def get_cache_ttl
    settings = Setting.plugin_redmine_tx_mcp || {}
    (settings['cache_ttl'] || 3600).to_i.seconds
  end

  def clear_conversation_history(session_id)
    return unless session_id
    Rails.cache.delete(conversation_cache_key(session_id))
  end

  def conversation_session_present?(data)
    return false unless data.is_a?(Hash)

    Array(data['display_history']).any? || data['chatbot_state'].present?
  end

  def persisted_conversation_session(session_id)
    conversation = find_chat_conversation(session_id)
    return default_conversation_session unless conversation

    normalize_conversation_session(
      'display_history' => conversation.display_history_payload,
      'chatbot_state' => conversation.chatbot_state_payload
    )
  end

  def chat_conversation_scope
    RedmineTxMcp::ChatbotConversation.for_user_project(
      user_id: User.current.id,
      project_id: @project.id
    )
  end

  def recent_chat_conversations
    chat_conversation_scope.limit(RECENT_CHAT_SESSION_LIMIT)
  end

  def find_chat_conversation(session_id)
    return nil if session_id.blank?

    chat_conversation_scope.find_by(session_id: session_id)
  end

  def ensure_chat_conversation_record(session_id)
    return nil if session_id.blank?

    conversation = RedmineTxMcp::ChatbotConversation.ensure_for!(
      user_id: User.current.id,
      project_id: @project.id,
      session_id: session_id
    )
    prune_chat_conversations!(keep_session_id: session_id)
    conversation
  end

  def delete_chat_conversation_record(session_id)
    conversation = find_chat_conversation(session_id)
    return unless conversation

    clear_conversation_history(conversation.session_id)
    current_workspace(conversation.session_id).clear!
    conversation.destroy
  end

  def persist_chat_conversation!(session_id, display_history:, chatbot_state:, title_hint:, touched_at: Time.current)
    ensure_chat_conversation_record(session_id).persist_snapshot!(
      display_history: display_history,
      chatbot_state: chatbot_state,
      title_hint: title_hint,
      touched_at: touched_at
    )
    prune_chat_conversations!(keep_session_id: session_id)
  end

  def touch_chat_conversation!(session_id, title_hint:, touched_at: Time.current)
    ensure_chat_conversation_record(session_id).touch_activity!(title_hint: title_hint, touched_at: touched_at)
    prune_chat_conversations!(keep_session_id: session_id)
  end

  def prune_chat_conversations!(keep_session_id:)
    cutoff = CHAT_SESSION_RETENTION_DAYS.days.ago
    stale = chat_conversation_scope.where('COALESCE(last_message_at, updated_at, created_at) < ?', cutoff).to_a
    overflow = chat_conversation_scope.offset(MAX_PERSISTED_CHAT_SESSIONS).to_a

    (stale + overflow).uniq.each do |conversation|
      next if conversation.session_id == keep_session_id

      delete_chat_conversation_record(conversation.session_id)
    end
  end

  def sessions_payload(active_session_id:)
    {
      active_session_id: active_session_id,
      items: recent_chat_conversations.map { |conversation| serialize_chat_conversation(conversation, active_session_id) }
    }
  end

  def serialize_chat_conversation(conversation, active_session_id)
    touched_at = conversation.last_message_at || conversation.updated_at || conversation.created_at
    {
      session_id: conversation.session_id,
      title: conversation.display_title,
      active: conversation.session_id == active_session_id,
      updated_at: touched_at&.iso8601,
      updated_label: format_session_timestamp(touched_at),
      path: project_chatbot_path(@project, conversation: conversation.session_id)
    }
  end

  def format_session_timestamp(timestamp)
    return '' unless timestamp

    local = User.current.convert_time_to_user_timezone(timestamp)
    if local.to_date == User.current.today
      local.strftime('%H:%M')
    else
      local.strftime('%m-%d')
    end
  end

  def restore_chatbot_session(chatbot, session_id)
    snapshot = get_conversation_session(session_id)['chatbot_state']
    chatbot.restore_session_state(snapshot)
  end

  def current_workspace(session_id)
    RedmineTxMcp::ChatbotWorkspace.new(
      user_id: User.current.id,
      project_id: @project.id,
      session_id: session_id
    )
  end

  def process_uploaded_files(session_id)
    saved_files = []
    uploads = Array(params[:files]).compact
    return { saved_files: saved_files } if uploads.empty?

    workspace = current_workspace(session_id)
    uploads.each do |upload|
      next if upload.blank?
      saved_files << workspace.save_upload(upload)
    end

    { saved_files: saved_files }
  rescue => e
    { error: e.message, saved_files: saved_files }
  end

  def workspace_payload(session_id)
    current_workspace(session_id).summary
  end

  def render_upload_only_response(saved_files, session_id)
    message = upload_acknowledgement(saved_files)
    persist_upload_only_session(session_id, saved_files, assistant_message: message)

    if wants_streaming?
      response.headers['Content-Type'] = 'text/event-stream'
      response.headers['Cache-Control'] = 'no-cache'
      write_sse_event(type: 'workspace', workspace: workspace_payload(session_id))
      write_sse_event(type: 'sessions', sessions: sessions_payload(active_session_id: session_id))
      write_sse_event(type: 'answer', message: message)
      write_sse_event(type: 'done')
      response.stream.close
    else
      render json: {
        success: true,
        message: message,
        uploaded_files: saved_files,
        workspace: workspace_payload(session_id),
        sessions: sessions_payload(active_session_id: session_id)
      }
    end
  end

  def upload_acknowledgement(saved_files)
    file_list = saved_files.map { |file| "#{file[:stored_name]} (#{file[:size_label]})" }.join(', ')
    "업로드 완료: #{file_list}\n이제 업로드한 파일을 기준으로 시트 목록, 데이터 추출, 이슈 수정, 결과 엑셀 생성까지 이어서 요청할 수 있습니다."
  end

  def upload_request_message(saved_files)
    file_names = Array(saved_files).filter_map do |file|
      file[:stored_name] || file['stored_name']
    end
    return '[파일 업로드]' if file_names.empty?

    "[파일 업로드] [첨부 파일] #{file_names.join(', ')}"
  end

  def persist_upload_only_session(session_id, saved_files, assistant_message:)
    return unless session_id

    timestamp = Time.current
    data = get_conversation_session(session_id)
    history = Array(data['display_history'])
    history << {
      'role' => 'user',
      'content' => upload_request_message(saved_files),
      'timestamp' => timestamp.iso8601
    }
    history << {
      'role' => 'assistant',
      'content' => assistant_message,
      'timestamp' => timestamp.iso8601
    }

    data['display_history'] = history.last(20)

    cache_ttl = get_cache_ttl
    Rails.cache.write(conversation_cache_key(session_id), data, expires_in: cache_ttl)
    persist_chat_conversation!(
      session_id,
      display_history: data['display_history'],
      chatbot_state: data['chatbot_state'],
      title_hint: conversation_title_for_upload(saved_files),
      touched_at: timestamp
    )
  end

  def conversation_title_for_message(message)
    RedmineTxMcp::ChatbotConversation.normalize_title(message)
  end

  def conversation_title_for_upload(saved_files)
    first_file = Array(saved_files).first
    name = first_file && (first_file[:stored_name] || first_file['stored_name'])
    return nil if name.blank?

    RedmineTxMcp::ChatbotConversation.normalize_title("파일: #{name}")
  end

  def handle_missing_conversation
    message = '대화 세션을 찾을 수 없습니다. 새로고침 후 다시 시도해주세요.'
    redirect_url = project_chatbot_path(@project)

    if request.get? && !wants_streaming?
      redirect_to redirect_url, alert: message
      return
    end

    render_chat_error(
      message,
      status: 404,
      code: 'conversation_not_found',
      redirect_url: redirect_url
    )
  end

  def render_chat_error(message, status:, code: nil, redirect_url: nil)
    payload = { type: 'error', message: message }
    payload[:code] = code if code.present?
    payload[:redirect_url] = redirect_url if redirect_url.present?

    if wants_streaming?
      response.status = status
      response.headers['Content-Type'] = 'text/event-stream'
      response.headers['Cache-Control'] = 'no-cache'
      write_sse_event(payload)
      write_sse_event(type: 'done')
      response.stream.close
    else
      json_payload = { error: message }
      json_payload[:code] = code if code.present?
      json_payload[:redirect_url] = redirect_url if redirect_url.present?
      render json: json_payload, status: status
    end
  end

  def write_sse_event(payload)
    response.stream.write "data: #{payload.to_json}\n\n"
  end
end
