class McpController < ApplicationController
  before_action :require_login
  before_action :authorize_mcp

  def index
    render json: {
      server: "redmine-tx-mcp",
      version: "1.0.0",
      status: "running",
      tools_available: available_tools_count
    }
  end

  def list_tools
    tools = [
      RedmineTxMcp::Tools::IssueTool,
      RedmineTxMcp::Tools::ProjectTool,
      RedmineTxMcp::Tools::UserTool,
      RedmineTxMcp::Tools::VersionTool,
      RedmineTxMcp::Tools::EnumerationTool,
      RedmineTxMcp::Tools::SpreadsheetTool
    ].flat_map(&:available_tools)

    render json: {
      tools: tools
    }
  end

  def get_tool
    tool_name = params[:name]

    all_tools = [
      RedmineTxMcp::Tools::IssueTool,
      RedmineTxMcp::Tools::ProjectTool,
      RedmineTxMcp::Tools::UserTool,
      RedmineTxMcp::Tools::VersionTool,
      RedmineTxMcp::Tools::EnumerationTool,
      RedmineTxMcp::Tools::SpreadsheetTool
    ].flat_map(&:available_tools)

    tool = all_tools.find { |t| t[:name] == tool_name }

    if tool
      render json: { tool: tool }
    else
      render json: { error: "Tool not found: #{tool_name}" }, status: 404
    end
  end

  def call_tool
    tool_name = params[:name]
    arguments = params[:arguments] || {}

    result = case tool_name
             when /^issue_/
               RedmineTxMcp::Tools::IssueTool.call_tool(tool_name, arguments)
             when /^project_/
               RedmineTxMcp::Tools::ProjectTool.call_tool(tool_name, arguments)
             when /^user_/
               RedmineTxMcp::Tools::UserTool.call_tool(tool_name, arguments)
             when /^version_/
               RedmineTxMcp::Tools::VersionTool.call_tool(tool_name, arguments)
             when /^enum_/
               RedmineTxMcp::Tools::EnumerationTool.call_tool(tool_name, arguments)
             when /^spreadsheet_/
               RedmineTxMcp::Tools::SpreadsheetTool.call_tool(tool_name, arguments)
             else
               { error: "Unknown tool: #{tool_name}" }
             end

    render json: { result: result }
  rescue => e
    Rails.logger.error "MCP Tool Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { error: "Tool execution failed: #{e.message}" }, status: 500
  end

  private

  def authorize_mcp
    deny_access unless User.current.allowed_to?(:use_mcp_api, @project, global: true)
  end

  def available_tools_count
    [
      RedmineTxMcp::Tools::IssueTool,
      RedmineTxMcp::Tools::ProjectTool,
      RedmineTxMcp::Tools::UserTool,
      RedmineTxMcp::Tools::VersionTool,
      RedmineTxMcp::Tools::EnumerationTool,
      RedmineTxMcp::Tools::SpreadsheetTool
    ].sum { |tool_class| tool_class.available_tools.count }
  end
end
