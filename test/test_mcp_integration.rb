require File.expand_path('../../test_helper', __FILE__)

class McpIntegrationTest < ActiveSupport::TestCase
  def setup
    @server = RedmineTxMcp::McpServer
  end

  test "server class should be defined" do
    assert defined?(RedmineTxMcp::McpServer)
  end

  test "tools should be available" do
    issue_tools = RedmineTxMcp::Tools::IssueTool.available_tools
    project_tools = RedmineTxMcp::Tools::ProjectTool.available_tools
    user_tools = RedmineTxMcp::Tools::UserTool.available_tools

    assert issue_tools.count > 0, "Issue tools should be available"
    assert project_tools.count > 0, "Project tools should be available"
    assert user_tools.count > 0, "User tools should be available"

    # Check specific tools
    issue_tool_names = issue_tools.map { |t| t[:name] }
    assert_includes issue_tool_names, 'issue_list'
    assert_includes issue_tool_names, 'issue_get'
    assert_includes issue_tool_names, 'issue_create'
  end

  test "issue tool should handle list request" do
    User.current = User.find(1) # Admin user
    result = RedmineTxMcp::Tools::IssueTool.call_tool('issue_list', { 'page' => 1, 'per_page' => 5 })

    assert result.is_a?(Hash)
    assert result.key?('items')
    assert result.key?('pagination')
    assert result['pagination']['page'] == 1
  end

  test "project tool should handle list request" do
    User.current = User.find(1) # Admin user
    result = RedmineTxMcp::Tools::ProjectTool.call_tool('project_list', { 'page' => 1, 'per_page' => 5 })

    assert result.is_a?(Hash)
    assert result.key?('items')
    assert result.key?('pagination')
  end

  test "user tool should handle list request" do
    User.current = User.find(1) # Admin user
    result = RedmineTxMcp::Tools::UserTool.call_tool('user_list', { 'page' => 1, 'per_page' => 5 })

    assert result.is_a?(Hash)
    assert result.key?('items')
    assert result.key?('pagination')
  end

  test "tools should handle errors gracefully" do
    User.current = User.find(1)
    result = RedmineTxMcp::Tools::IssueTool.call_tool('issue_get', { 'id' => 99999 })

    assert result.is_a?(Hash)
    assert result.key?('error')
    assert_equal "Issue not found", result['error']
  end

  test "unknown tool should return error" do
    result = RedmineTxMcp::Tools::IssueTool.call_tool('unknown_tool', {})

    assert result.is_a?(Hash)
    assert result.key?('error')
    assert_match /Unknown tool/, result['error']
  end
end