class McpAdminController < ApplicationController
  layout 'admin'
  before_action :require_admin

  def index
    @mcp_status = check_mcp_server_status
    @available_tools = get_available_tools

    # Log any errors for debugging
    if @mcp_status[:error]
      logger.error "=== MCP Admin Error ==="
      logger.error "Error: #{@mcp_status[:error]}"
      logger.error "Server Loaded: #{@mcp_status[:server_loaded]}"
      logger.error "Tools Loaded: #{@mcp_status[:tools_loaded]}"
      logger.error "Settings: #{@mcp_status[:settings]}"
      logger.error "========================"

      # Also output to STDERR to ensure we see it
      STDERR.puts "=== MCP Admin Error ==="
      STDERR.puts "Error: #{@mcp_status[:error]}"
      STDERR.puts "========================"
    end
  end

  def settings
    @settings = Setting.plugin_redmine_tx_mcp || {}
  rescue => e
    logger.error "MCP Settings access error: #{e.message}"
    STDERR.puts "MCP Settings access error: #{e.message}"
    @settings = {}
  end

  def models
    settings = Setting.plugin_redmine_tx_mcp || {}
    api_key = settings['claude_api_key'].presence || ENV['ANTHROPIC_API_KEY']

    unless api_key.present?
      render json: { success: false, models: [], error: 'API key not configured' }
      return
    end

    force_refresh = params[:refresh] == '1'
    models = RedmineTxMcp::AnthropicModelsService.fetch_models(force_refresh: force_refresh)

    render json: { success: models.any?, models: models }
  rescue => e
    logger.error "[McpAdmin#models] #{e.class}: #{e.message}"
    render json: { success: false, models: [], error: e.message }
  end

  def update_settings
    settings = params[:settings] || {}

    # Validate settings
    if settings[:enabled] == '1' && settings[:api_key].blank?
      flash[:error] = "API Key is required when MCP is enabled"
      redirect_to mcp_admin_settings_path
      return
    end

    Setting.plugin_redmine_tx_mcp = settings
    flash[:notice] = "MCP settings updated successfully"
    redirect_to mcp_admin_index_path
  end

  private

  def check_mcp_server_status
    begin
      # Check if MCP server components are loaded
      {
        server_loaded: !!defined?(RedmineTxMcp::McpServer),
        tools_loaded: {
          issue_tool: !!defined?(RedmineTxMcp::Tools::IssueTool),
          project_tool: !!defined?(RedmineTxMcp::Tools::ProjectTool),
          user_tool: !!defined?(RedmineTxMcp::Tools::UserTool),
          version_tool: !!defined?(RedmineTxMcp::Tools::VersionTool),
          enumeration_tool: !!defined?(RedmineTxMcp::Tools::EnumerationTool)
        },
        settings: (Setting.plugin_redmine_tx_mcp rescue {})
      }
    rescue => e
      logger.error "MCP Status Check Error: #{e.message}"
      logger.error e.backtrace.join("\n")
      STDERR.puts "MCP Status Check Error: #{e.message}"
      {
        error: e.message,
        server_loaded: false,
        tools_loaded: {
          issue_tool: false,
          project_tool: false,
          user_tool: false,
          version_tool: false,
          enumeration_tool: false
        },
        settings: {}
      }
    end
  end

  def get_available_tools
    begin
      [
        RedmineTxMcp::Tools::IssueTool,
        RedmineTxMcp::Tools::ProjectTool,
        RedmineTxMcp::Tools::UserTool,
        RedmineTxMcp::Tools::VersionTool,
        RedmineTxMcp::Tools::EnumerationTool
      ].flat_map(&:available_tools)
    rescue => e
      Rails.logger.error "Failed to load MCP tools: #{e.message}"
      []
    end
  end
end