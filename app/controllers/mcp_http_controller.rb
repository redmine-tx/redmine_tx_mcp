class McpHttpController < ApplicationController
  skip_before_action :check_if_login_required
  skip_before_action :verify_authenticity_token, if: :external_mcp_token_request?
  before_action :set_cors_headers
  before_action :authenticate_mcp_request, except: :options

  def mcp_request
    User.current = @mcp_user

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

  def handle_unverified_request
    render json: {
      jsonrpc: "2.0",
      error: {
        code: -32002,
        message: l(:error_invalid_authenticity_token)
      }
    }, status: 422
  end

  def authenticate_mcp_request
    if external_mcp_token_request?
      return authenticate_external_mcp_request
    end

    return render_auth_error("Login required") unless User.current.logged?
    return render_forbidden("Not authorized to use MCP API") unless User.current.allowed_to?(:use_mcp_api, nil, global: true)

    @mcp_user = User.current
  end

  def authenticate_external_mcp_request
    api_key = request.headers['Authorization']&.gsub(/^Bearer /, '')
    return render_auth_error("Missing API key") unless api_key.present?

    settings = Setting.plugin_redmine_tx_mcp || {}
    configured_key = settings['api_key']
    return render_auth_error("Invalid API key") unless configured_key.present? && api_key == configured_key

    @mcp_user = find_authenticated_mcp_user
    return render_auth_error("Missing Redmine API key") unless api_key_from_request.present?
    return render_auth_error("Invalid Redmine API key") unless @mcp_user
    return render_forbidden("Not authorized to use MCP API") unless @mcp_user.allowed_to?(:use_mcp_api, nil, global: true)

    true
  end

  def find_authenticated_mcp_user
    return nil if api_key_from_request.blank?

    User.find_by_api_key(api_key_from_request)
  rescue
    nil
  end

  def render_auth_error(message)
    render json: {
      jsonrpc: "2.0",
      error: {
        code: -32001,
        message: message
      }
    }, status: 401
    false
  end

  def render_forbidden(message)
    render json: {
      jsonrpc: "2.0",
      error: {
        code: -32003,
        message: message
      }
    }, status: 403
    false
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
    end

    response.headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-Redmine-API-Key'
    response.headers['Access-Control-Max-Age'] = '86400'
  end

  def external_mcp_token_request?
    request.headers['Authorization'].to_s.match?(/\ABearer\s+/)
  end
end
