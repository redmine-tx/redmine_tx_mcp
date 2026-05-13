class McpHttpController < ApplicationController
  skip_before_action :check_if_login_required
  skip_before_action :verify_authenticity_token, if: :external_mcp_request?
  before_action :set_cors_headers
  before_action :authenticate_mcp_request, except: :options

  def mcp_request
    User.current = @mcp_user

    parsed_request = parse_json_rpc_body
    return unless parsed_request

    unless parsed_request.is_a?(Hash)
      render_streamable_http_error("Batch JSON-RPC requests are not supported", status: :bad_request)
      return
    end

    if json_rpc_notification_or_response?(parsed_request)
      head :accepted
      return
    end

    response_data = RedmineTxMcp::HttpMcpServer.handle_parsed_request(parsed_request, request.headers)

    render json: response_data
  end

  def mcp_stream
    render_streamable_http_error("Server-initiated SSE streams are not supported", status: :method_not_allowed)
  end

  def delete_session
    head :method_not_allowed
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
    if external_mcp_request?
      return authenticate_external_mcp_request
    end

    return render_auth_error("Login required") unless User.current.logged?
    return render_forbidden("Not authorized to use MCP API") unless User.current.allowed_to?(:use_mcp_api, nil, global: true)

    @mcp_user = User.current
  end

  def authenticate_external_mcp_request
    if configured_mcp_api_key.present?
      return render_auth_error("Missing MCP API key") unless bearer_token.present?
      return render_auth_error("Invalid MCP API key") unless secure_token_equal?(bearer_token, configured_mcp_api_key)

      # tools/list, initialize 등 메타데이터 요청은 서버 Bearer 토큰만으로 허용
      # (사용자 API key 불필요 — DB 접근 없는 순수 스키마 조회)
      if non_executing_or_metadata_request?
        @mcp_user = User.anonymous
        return true
      end
    end

    @mcp_user = find_authenticated_mcp_user
    return render_auth_error("Missing Redmine API key") unless redmine_api_key_from_request.present?
    return render_auth_error("Invalid Redmine API key") unless @mcp_user
    return render_forbidden("Not authorized to use MCP API") unless @mcp_user.allowed_to?(:use_mcp_api, nil, global: true)

    true
  end

  def find_authenticated_mcp_user
    return nil if redmine_api_key_from_request.blank?

    User.find_by_api_key(redmine_api_key_from_request)
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

  def render_streamable_http_error(message, status:)
    render json: {
      jsonrpc: "2.0",
      error: {
        code: -32000,
        message: message
      }
    }, status: status
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

    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, DELETE, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = [
      'Accept',
      'Content-Type',
      'Authorization',
      'X-Redmine-API-Key',
      'MCP-Protocol-Version',
      'Mcp-Session-Id',
      'Last-Event-ID'
    ].join(', ')
    response.headers['Access-Control-Max-Age'] = '86400'
  end

  def external_mcp_request?
    bearer_token.present? || api_key_from_request.present?
  end

  def bearer_token
    request.headers['Authorization'].to_s[/\ABearer\s+(.+)\z/, 1].to_s.presence
  end

  def configured_mcp_api_key
    settings = Setting.plugin_redmine_tx_mcp || {}
    settings['api_key'].to_s.strip.presence
  end

  def redmine_api_key_from_request
    api_key_from_request.presence || (configured_mcp_api_key.blank? ? bearer_token : nil)
  end

  def secure_token_equal?(actual, expected)
    return false if actual.to_s.bytesize != expected.to_s.bytesize

    ActiveSupport::SecurityUtils.secure_compare(actual.to_s, expected.to_s)
  end

  def non_executing_or_metadata_request?
    parsed = parsed_json_rpc_body
    return true if parsed.nil?
    return false unless parsed.is_a?(Hash)
    return true if json_rpc_notification_or_response?(parsed)

    %w[initialize tools/list resources/list].include?(parsed['method'])
  rescue JSON::ParserError
    true
  end

  def parse_json_rpc_body
    parsed_json_rpc_body
  rescue JSON::ParserError => e
    render_streamable_http_error("Invalid JSON: #{e.message}", status: :bad_request)
    nil
  end

  def parsed_json_rpc_body
    @parsed_json_rpc_body ||= JSON.parse(request.raw_post.to_s)
  end

  def json_rpc_notification_or_response?(parsed)
    !parsed.key?('id') || !parsed.key?('method')
  end
end
