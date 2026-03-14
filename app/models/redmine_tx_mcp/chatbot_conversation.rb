module RedmineTxMcp
  class ChatbotConversation < ApplicationRecord
    self.table_name = 'redmine_tx_mcp_chatbot_conversations'

    DEFAULT_TITLE = '새 대화'.freeze
    TITLE_LIMIT = 80

    scope :for_user_project, lambda { |user_id:, project_id:|
      where(user_id: user_id, project_id: project_id)
        .order(Arel.sql('COALESCE(last_message_at, updated_at, created_at) DESC'), created_at: :desc)
    }

    validates :user_id, :project_id, :session_id, presence: true
    validates :session_id, uniqueness: true
    validates :title, length: { maximum: TITLE_LIMIT }

    before_validation :apply_default_title

    def display_title
      title.presence || DEFAULT_TITLE
    end

    def placeholder_title?
      title.blank? || title == DEFAULT_TITLE
    end

    def display_history_payload
      parse_json_payload(display_history_data, fallback: [])
    end

    def chatbot_state_payload
      parse_json_payload(chatbot_state_data, fallback: nil)
    end

    def touch_activity!(title_hint: nil, touched_at: Time.current)
      attrs = { last_message_at: touched_at }
      normalized = self.class.normalize_title(title_hint)
      attrs[:title] = normalized if normalized.present? && placeholder_title?
      persist_with_mysql_fallback!(attrs)
    end

    def persist_snapshot!(display_history:, chatbot_state:, title_hint: nil, touched_at: Time.current)
      attrs = {
        last_message_at: touched_at,
        display_history_data: JSON.generate(Array(display_history)),
        chatbot_state_data: chatbot_state.present? ? JSON.generate(chatbot_state) : nil
      }
      normalized = self.class.normalize_title(title_hint)
      attrs[:title] = normalized if normalized.present? && placeholder_title?
      persist_with_mysql_fallback!(attrs)
    end

    def self.ensure_for!(user_id:, project_id:, session_id:)
      find_or_create_by!(user_id: user_id, project_id: project_id, session_id: session_id)
    end

    def self.normalize_title(text)
      cleaned = text.to_s.gsub(/\s+/, ' ').strip
      return nil if cleaned.blank?

      cleaned.first(TITLE_LIMIT)
    end

    private

    def apply_default_title
      self.title = DEFAULT_TITLE if title.blank?
    end

    def parse_json_payload(raw, fallback:)
      return fallback if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      fallback
    end

    def persist_with_mysql_fallback!(attrs)
      update!(attrs)
    rescue ActiveRecord::StatementInvalid => e
      raise unless mysql_incorrect_string_value?(e)

      Rails.logger.warn('[ChatbotConversation] Retrying persistence with utf8mb3-safe content') if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      update!(sanitize_for_mysql_utf8mb3(attrs))
    end

    def mysql_incorrect_string_value?(error)
      error.message.to_s.include?('Incorrect string value')
    end

    def sanitize_for_mysql_utf8mb3(value)
      case value
      when String
        value.gsub(/[\u{10000}-\u{10FFFF}]/, '?')
      when Array
        value.map { |item| sanitize_for_mysql_utf8mb3(item) }
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          memo[key] = sanitize_for_mysql_utf8mb3(item)
        end
      else
        value
      end
    end
  end
end
