class AddSessionPayloadsToChatbotConversations < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:redmine_tx_mcp_chatbot_conversations, :display_history_data)
      add_column :redmine_tx_mcp_chatbot_conversations, :display_history_data, :text
    end
    unless column_exists?(:redmine_tx_mcp_chatbot_conversations, :chatbot_state_data)
      add_column :redmine_tx_mcp_chatbot_conversations, :chatbot_state_data, :text
    end
  end
end
