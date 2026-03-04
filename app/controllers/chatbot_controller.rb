class ChatbotController < ApplicationController
  before_action :require_login
  before_action :find_project, except: [:global_chat, :global_chat_submit]
  skip_before_action :verify_authenticity_token, only: [:chat_submit, :global_chat_submit]

  def index
    @chatbot_session_id = session[:chatbot_session_id] ||= SecureRandom.hex(8)
    @conversation_history = get_conversation_history(@chatbot_session_id)
  end

  def chat_submit
    message = params[:message]

    if message.blank?
      render json: { error: "Message cannot be empty" }, status: 400
      return
    end

    begin
      # Initialize chatbot
      chatbot = get_or_create_chatbot

      # Send message to Claude
      response = chatbot.chat(message, user: User.current)

      if response[:success]
        # Store conversation in cache
        session_id = session[:chatbot_session_id]
        store_conversation_message(session_id, 'user', message)
        store_conversation_message(session_id, 'assistant', response[:message])

        render json: {
          success: true,
          message: response[:message],
          conversation_id: response[:conversation_id]
        }
      else
        render json: {
          success: false,
          error: response[:error]
        }, status: 500
      end

    rescue => e
      Rails.logger.error "Chatbot Error: #{e.message}"
      render json: {
        success: false,
        error: "Sorry, I encountered an error. Please try again."
      }, status: 500
    end
  end

  def reset
    session_id = session[:chatbot_session_id]
    clear_conversation_history(session_id) if session_id
    session[:chatbot_instance] = nil

    render json: { success: true, message: "Conversation reset" }
  end

  def global_chat
    @chatbot_session_id = session[:global_chatbot_session_id] ||= SecureRandom.hex(8)
    @conversation_history = get_conversation_history(@chatbot_session_id)
  end

  def global_chat_submit
    message = params[:message]

    if message.blank?
      if wants_streaming?
        self.response.headers['Content-Type'] = 'text/event-stream'
        self.response.headers['Cache-Control'] = 'no-cache'
        self.response_body = ["data: #{({ type: 'error', message: 'Message cannot be empty' }).to_json}\n\n",
                              "data: #{({ type: 'done' }).to_json}\n\n"]
      else
        render json: { error: "Message cannot be empty" }, status: 400
      end
      return
    end

    if wants_streaming?
      stream_chat_response(message)
      return
    end

    begin
      # Initialize global chatbot
      chatbot = get_or_create_global_chatbot

      # Send message to Claude
      response = chatbot.chat(message, user: User.current)

      if response[:success]
        # Store conversation in cache
        session_id = session[:global_chatbot_session_id]
        store_conversation_message(session_id, 'user', message)
        store_conversation_message(session_id, 'assistant', response[:message])

        render json: {
          success: true,
          message: response[:message],
          conversation_id: response[:conversation_id]
        }
      else
        render json: {
          success: false,
          error: response[:error]
        }, status: 500
      end

    rescue => e
      Rails.logger.error "Global Chatbot Error: #{e.message}"
      render json: {
        success: false,
        error: "Sorry, I encountered an error. Please try again."
      }, status: 500
    end
  end

  private

  def wants_streaming?
    request.headers['Accept']&.include?('text/event-stream')
  end

  def stream_chat_response(message)
    session_id = session[:global_chatbot_session_id]
    chatbot = get_or_create_global_chatbot
    current_user = User.current

    self.response.headers['Content-Type'] = 'text/event-stream'
    self.response.headers['Cache-Control'] = 'no-cache'
    self.response.headers['X-Accel-Buffering'] = 'no'

    self.response_body = Enumerator.new do |yielder|
      final_message = nil

      begin
        chatbot.chat_stream(message, user: current_user) do |event|
          yielder << "data: #{event.to_json}\n\n"
          final_message = event[:message] if event[:type] == 'answer'
        end

        if final_message
          store_conversation_message(session_id, 'user', message)
          store_conversation_message(session_id, 'assistant', final_message)
        end
      rescue => e
        Rails.logger.error "Stream Chat Error: #{e.class}: #{e.message}"
        yielder << "data: #{({ type: 'error', message: e.message }).to_json}\n\n"
        yielder << "data: #{({ type: 'done' }).to_json}\n\n"
      end
    end
  end

  def find_project
    @project = Project.find(params[:project_id]) if params[:project_id]
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def get_or_create_chatbot
    session[:chatbot_instance] ||= create_new_chatbot

    # Restore conversation history
    chatbot = create_new_chatbot
    session_id = session[:chatbot_session_id]
    restore_conversation_to_chatbot(chatbot, session_id)
    chatbot
  end

  def get_or_create_global_chatbot
    session[:global_chatbot_instance] ||= create_new_chatbot

    # Restore conversation history
    chatbot = create_new_chatbot
    session_id = session[:global_chatbot_session_id]
    restore_conversation_to_chatbot(chatbot, session_id)
    chatbot
  end

  def create_new_chatbot
    settings = Setting.plugin_redmine_tx_mcp || {}
    api_key = settings['claude_api_key'] || ENV['ANTHROPIC_API_KEY']
    model = settings['claude_model'] || 'claude-sonnet-4-6'

    unless api_key.present?
      raise "Claude API key not configured. Please set it in MCP settings or ANTHROPIC_API_KEY environment variable."
    end

    RedmineTxMcp::ClaudeChatbot.new(api_key: api_key, model: model)
  end

  def get_conversation_history(session_id)
    return [] unless session_id
    cache_ttl = get_cache_ttl
    Rails.cache.fetch("chatbot_conversation_#{session_id}", expires_in: cache_ttl) { [] }
  end

  def store_conversation_message(session_id, role, content)
    return unless session_id

    history = get_conversation_history(session_id)
    history << {
      'role' => role,
      'content' => content,
      'timestamp' => Time.current.strftime("%H:%M")
    }

    # Keep only last 20 messages (increased from 6 since we're not limited by cookies)
    history = history.last(20)

    cache_ttl = get_cache_ttl
    Rails.cache.write("chatbot_conversation_#{session_id}", history, expires_in: cache_ttl)
  end

  def get_cache_ttl
    settings = Setting.plugin_redmine_tx_mcp || {}
    (settings['cache_ttl'] || 3600).to_i.seconds
  end

  def clear_conversation_history(session_id)
    return unless session_id
    Rails.cache.delete("chatbot_conversation_#{session_id}")
  end

  def restore_conversation_to_chatbot(chatbot, session_id)
    history = get_conversation_history(session_id)
    history.each do |msg|
      role = msg['role'] || msg[:role]
      content = msg['content'] || msg[:content]
      next unless role.present? && content.present?
      chatbot.instance_variable_get(:@conversation_history) << {
        role: role.to_s,
        content: content
      }
    end
  end
end