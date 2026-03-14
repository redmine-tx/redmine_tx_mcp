class CreateRedmineTxMcpChatbotConversations < ActiveRecord::Migration[6.1]
  def change
    unless table_exists?(:redmine_tx_mcp_chatbot_conversations)
      create_table :redmine_tx_mcp_chatbot_conversations, **mysql_utf8mb4_table_options do |t|
        t.integer :user_id, null: false
        t.integer :project_id, null: false
        t.string :session_id, null: false
        t.string :title, null: false, default: '새 대화'
        t.datetime :last_message_at

        t.timestamps
      end
    end

    add_index :redmine_tx_mcp_chatbot_conversations, :session_id, unique: true, name: 'idx_rtxmcp_chatbot_conversations_on_session' unless index_exists?(:redmine_tx_mcp_chatbot_conversations, :session_id, name: 'idx_rtxmcp_chatbot_conversations_on_session')
    unless index_exists?(:redmine_tx_mcp_chatbot_conversations, [:user_id, :project_id, :last_message_at], name: 'idx_rtxmcp_chatbot_conversations_recent')
      add_index :redmine_tx_mcp_chatbot_conversations, [:user_id, :project_id, :last_message_at], name: 'idx_rtxmcp_chatbot_conversations_recent'
    end
  end

  private

  def mysql_utf8mb4_table_options
    return {} unless mysql?

    { options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' }
  end

  def mysql?
    connection.adapter_name.to_s.downcase.include?('mysql')
  end
end
