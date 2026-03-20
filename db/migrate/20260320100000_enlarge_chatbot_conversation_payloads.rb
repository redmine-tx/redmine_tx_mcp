class EnlargeChatbotConversationPayloads < ActiveRecord::Migration[6.1]
  def up
    change_column :redmine_tx_mcp_chatbot_conversations, :display_history_data, :mediumtext
    change_column :redmine_tx_mcp_chatbot_conversations, :chatbot_state_data, :mediumtext
  end

  def down
    change_column :redmine_tx_mcp_chatbot_conversations, :display_history_data, :text
    change_column :redmine_tx_mcp_chatbot_conversations, :chatbot_state_data, :text
  end
end
