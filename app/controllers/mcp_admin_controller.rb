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
      logger.error "Settings: #{redacted_settings_for_log(@mcp_status[:settings]).inspect}"
      logger.error "========================"

      # Also output to STDERR to ensure we see it
      STDERR.puts "=== MCP Admin Error ==="
      STDERR.puts "Error: #{@mcp_status[:error]}"
      STDERR.puts "========================"
    end
  end

  def models
    settings = Setting.plugin_redmine_tx_mcp || {}
    provider = params[:provider] || 'anthropic'
    force_refresh = params[:refresh] == '1'

    if provider == 'openai'
      # Prefer endpoint_url from query param (form value) over saved setting
      endpoint_url = params[:endpoint_url].presence || settings['openai_endpoint_url']
      unless endpoint_url.present?
        render json: { success: false, models: [], error: 'OpenAI endpoint URL not configured' }
        return
      end

      api_key = params[:api_key].presence || settings['openai_api_key'].presence
      models = RedmineTxMcp::OpenaiModelsService.fetch_models(
        endpoint_url: endpoint_url, api_key: api_key, force_refresh: force_refresh
      )
    else
      api_key = settings['claude_api_key'].presence || ENV['ANTHROPIC_API_KEY']

      unless api_key.present?
        render json: { success: false, models: [], error: 'API key not configured' }
        return
      end

      models = RedmineTxMcp::AnthropicModelsService.fetch_models(force_refresh: force_refresh)
    end

    render json: { success: models.any?, models: models }
  rescue => e
    logger.error "[McpAdmin#models] #{e.class}: #{e.message}"
    render json: { success: false, models: [], error: e.message }
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
          enumeration_tool: !!defined?(RedmineTxMcp::Tools::EnumerationTool),
          spreadsheet_tool: !!defined?(RedmineTxMcp::Tools::SpreadsheetTool)
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
          enumeration_tool: false,
          spreadsheet_tool: false
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
        RedmineTxMcp::Tools::EnumerationTool,
        RedmineTxMcp::Tools::SpreadsheetTool
      ].flat_map(&:available_tools)
    rescue => e
      Rails.logger.error "Failed to load MCP tools: #{e.message}"
      []
    end
  end

  def redacted_settings_for_log(settings)
    settings.to_h.each_with_object({}) do |(key, value), memo|
      memo[key] = sensitive_setting_key?(key) && value.present? ? '[FILTERED]' : value
    end
  end

  def sensitive_setting_key?(key)
    key.to_s.match?(/(?:\A|_)(api_key|token|secret|password)\z/)
  end
end
