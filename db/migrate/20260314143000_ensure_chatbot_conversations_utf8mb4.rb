class EnsureChatbotConversationsUtf8mb4 < ActiveRecord::Migration[6.1]
  TABLE_NAME = :redmine_tx_mcp_chatbot_conversations

  def up
    return unless mysql?
    return unless table_exists?(TABLE_NAME)

    execute <<~SQL.squish
      ALTER TABLE #{quote_table_name(TABLE_NAME)}
      CONVERT TO CHARACTER SET utf8mb4
      COLLATE utf8mb4_unicode_ci
    SQL
  end

  def down
    # Irreversible on purpose. We don't want to downgrade text data to a narrower charset.
  end

  private

  def mysql?
    connection.adapter_name.to_s.downcase.include?('mysql')
  end
end
