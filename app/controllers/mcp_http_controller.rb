class McpHttpController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :check_if_login_required
  before_action :authenticate_mcp_request
  before_action :set_cors_headers

  def mcp_request
    # Set current user for Redmine operations (use API key to determine user)
    User.current = find_user_by_api_key

    request_body = request.raw_post
    headers = request.headers

    response_data = RedmineTxMcp::HttpMcpServer.handle_request(request_body, headers)

    render json: response_data
  end

  # Handle CORS preflight requests
  def options
    head :ok
  end

  private

  def authenticate_mcp_request
    api_key = request.headers['Authorization']&.gsub(/^Bearer /, '')

    unless api_key.present?
      render json: {
        jsonrpc: "2.0",
        error: {
          code: -32001,
          message: "Missing API key"
        }
      }, status: 401
      return false
    end

    settings = Setting.plugin_redmine_tx_mcp || {}
    configured_key = settings['api_key']

    unless configured_key.present? && api_key == configured_key
      render json: {
        jsonrpc: "2.0",
        error: {
          code: -32001,
          message: "Invalid API key"
        }
      }, status: 401
      return false
    end

    true
  end

  def find_user_by_api_key
    # For now, use admin user. In production, you might want to
    # associate API keys with specific users
    User.find(1) # Admin user
  rescue
    User.anonymous
  end

  def set_cors_headers
    settings = Setting.plugin_redmine_tx_mcp || {}
    allowed_origins = settings['allowed_origins']

    if allowed_origins.present? && !allowed_origins.strip.empty?
      origins = allowed_origins.split("\n").map(&:strip).reject(&:empty?)
      origin = request.headers['Origin']

      if origins.include?(origin)
        response.headers['Access-Control-Allow-Origin'] = origin
      end
    else
      # Allow all origins if allowed_origins is empty or not configured
      response.headers['Access-Control-Allow-Origin'] = '*'
    end

    response.headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
    response.headers['Access-Control-Max-Age'] = '86400'
  end
end