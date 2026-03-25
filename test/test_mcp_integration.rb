require File.expand_path('test_helper', __dir__)

class McpIntegrationTest < ActiveSupport::TestCase
  def setup
    @server = RedmineTxMcp::McpServer
  end

  private

  def indifferent(hash)
    hash.with_indifferent_access
  end

  public

  test "server class should be defined" do
    assert defined?(RedmineTxMcp::McpServer)
  end

  test "tools should be available" do
    issue_tools = RedmineTxMcp::Tools::IssueTool.available_tools
    project_tools = RedmineTxMcp::Tools::ProjectTool.available_tools
    user_tools = RedmineTxMcp::Tools::UserTool.available_tools
    spreadsheet_tools = RedmineTxMcp::Tools::SpreadsheetTool.available_tools

    assert issue_tools.count > 0, "Issue tools should be available"
    assert project_tools.count > 0, "Project tools should be available"
    assert user_tools.count > 0, "User tools should be available"
    assert spreadsheet_tools.count > 0, "Spreadsheet tools should be available"

    # Check specific tools
    issue_tool_names = issue_tools.map { |t| t[:name] }
    assert_includes issue_tool_names, 'issue_list'
    assert_includes issue_tool_names, 'issue_get'
    assert_includes issue_tool_names, 'issue_relations_get'
    assert_includes issue_tool_names, 'issue_create'
    assert_includes issue_tool_names, 'issue_bulk_update'
    refute_includes issue_tool_names, 'insert_bulk_update'
    assert_includes issue_tool_names, 'issue_relation_create'
    assert_includes issue_tool_names, 'issue_relation_delete'
    assert_includes issue_tool_names, 'issue_auto_schedule_preview'
    assert_includes issue_tool_names, 'issue_auto_schedule_apply'

    issue_list_tool = issue_tools.find { |t| t[:name] == 'issue_list' }
    issue_list_props = issue_list_tool[:inputSchema][:properties]
    assert_includes issue_list_props.keys, :status_name
    assert_includes issue_list_props.keys, :is_unassigned
    assert_includes issue_list_props.keys, :fetch_all
    assert_includes issue_list_props.keys, :related_to_id
    assert_includes issue_list_props.keys, :has_relations

    spreadsheet_tool_names = spreadsheet_tools.map { |t| t[:name] }
    assert_includes spreadsheet_tool_names, 'spreadsheet_list_uploads'
    assert_includes spreadsheet_tool_names, 'spreadsheet_list_sheets'
    assert_includes spreadsheet_tool_names, 'spreadsheet_preview_sheet'
    assert_includes spreadsheet_tool_names, 'spreadsheet_extract_rows'
    assert_includes spreadsheet_tool_names, 'spreadsheet_export_report'
  end

  test "issue tool should handle list request" do
    User.current = User.find(1) # Admin user
    result = indifferent(RedmineTxMcp::Tools::IssueTool.call_tool('issue_list', { 'page' => 1, 'per_page' => 5 }))

    assert result.is_a?(Hash)
    assert result.key?(:items)
    assert result.key?(:pagination)
    assert_equal 1, indifferent(result[:pagination])[:page]
  end

  test "project tool should handle list request" do
    User.current = User.find(1) # Admin user
    result = indifferent(RedmineTxMcp::Tools::ProjectTool.call_tool('project_list', { 'page' => 1, 'per_page' => 5 }))

    assert result.is_a?(Hash)
    assert result.key?(:items)
    assert result.key?(:pagination)
  end

  test "user tool should handle list request" do
    User.current = User.find(1) # Admin user
    result = indifferent(RedmineTxMcp::Tools::UserTool.call_tool('user_list', { 'page' => 1, 'per_page' => 5 }))

    assert result.is_a?(Hash)
    assert result.key?(:items)
    assert result.key?(:pagination)
  end

  test "tools should handle errors gracefully" do
    User.current = User.find(1)
    result = indifferent(RedmineTxMcp::Tools::IssueTool.call_tool('issue_get', { 'id' => 99999 }))

    assert result.is_a?(Hash)
    assert result.key?(:error)
    assert_equal "Issue not found", result[:error]
  end

  test "deprecated insert_bulk_update alias still works" do
    User.current = User.find(1)
    issue = Issue.visible(User.current).find_by(project_id: 1)
    assert issue.present?

    result = indifferent(RedmineTxMcp::Tools::IssueTool.call_tool('insert_bulk_update', {
      'issue_ids' => [issue.id],
      'notes' => 'deprecated alias check'
    }))

    assert_equal true, result[:success]
    assert_includes result[:updated_issue_ids], issue.id
  end

  test "issue_get hides private journals from users without private note permission" do
    issue = Issue.visible(User.anonymous).first
    assert issue.present?

    Journal.create!(
      journalized: issue,
      user: User.find(1),
      notes: 'Private MCP note',
      private_notes: true
    )

    User.current = User.anonymous
    result = indifferent(RedmineTxMcp::Tools::IssueTool.call_tool('issue_get', {
      'id' => issue.id,
      'include_journals' => true
    }))

    notes = Array(result[:journals]).map { |journal| indifferent(journal)[:notes] }
    refute_includes notes, 'Private MCP note'
  end

  test "unknown tool should return error" do
    result = indifferent(RedmineTxMcp::Tools::IssueTool.call_tool('unknown_tool', {}))

    assert result.is_a?(Hash)
    assert result.key?(:error)
    assert_match /Unknown tool/, result[:error]
  end

  test "issue delete rejects users without delete permission" do
    issue = Issue.visible(User.anonymous).where(project_id: 1).first
    assert issue.present?

    User.current = User.anonymous
    result = indifferent(RedmineTxMcp::Tools::IssueTool.call_tool('issue_delete', { 'id' => issue.id }))

    assert_equal "Not authorized to delete this issue", result[:error]
  end

  test "project update rejects users without project edit permission" do
    User.current = User.anonymous
    result = indifferent(RedmineTxMcp::Tools::ProjectTool.call_tool('project_update', {
      'id' => 1,
      'name' => 'unauthorized change'
    }))

    assert_equal "Not authorized to edit this project", result[:error]
  end

  test "user update requires admin" do
    User.current = User.find(2)
    result = indifferent(RedmineTxMcp::Tools::UserTool.call_tool('user_update', {
      'id' => 2,
      'firstname' => 'nope'
    }))

    assert_equal "Not authorized to manage users", result[:error]
  end

  test "version update rejects users without manage_versions permission" do
    version = Version.visible(User.anonymous).find_by(project_id: 1)
    assert version.present?

    User.current = User.anonymous
    result = indifferent(RedmineTxMcp::Tools::VersionTool.call_tool('version_update', {
      'id' => version.id,
      'name' => 'unauthorized change'
    }))

    assert_equal "Not authorized to manage versions in this project", result[:error]
  end
end
