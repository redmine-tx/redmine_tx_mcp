require File.expand_path('../test_helper', __dir__)
require 'securerandom'

class McpHttpControllerTest < Redmine::IntegrationTest
  def setup
    @original_plugin_settings = (Setting.plugin_redmine_tx_mcp || {}).dup
    Setting.plugin_redmine_tx_mcp = @original_plugin_settings.merge(
      'api_key' => 'plugin-secret',
      'allowed_origins' => "https://allowed.example"
    )
  end

  def teardown
    ActionController::Base.allow_forgery_protection = false
    Setting.plugin_redmine_tx_mcp = @original_plugin_settings
  end

  test "http mcp accepts a logged-in session without a Redmine user api key" do
    log_user('admin', 'admin')
    ActionController::Base.allow_forgery_protection = true
    csrf_token = fetch_csrf_token

    post '/mcp/http',
         params: JSON.generate(
           jsonrpc: '2.0',
           id: 1,
           method: 'tools/list'
         ),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'X-CSRF-Token' => csrf_token
         }

    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.dig('result', 'tools').present?
  end

  test "http mcp session auth still requires use_mcp_api permission" do
    log_user('someone', 'foo')
    ActionController::Base.allow_forgery_protection = true
    csrf_token = fetch_csrf_token

    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list'),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'X-CSRF-Token' => csrf_token
         }

    assert_response :forbidden
    payload = JSON.parse(response.body)
    assert_equal "Not authorized to use MCP API", payload.dig('error', 'message')
  end

  test "http mcp session auth enforces csrf protection" do
    log_user('admin', 'admin')
    ActionController::Base.allow_forgery_protection = true

    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list'),
         headers: {
           'CONTENT_TYPE' => 'application/json'
         }

    assert_response 422
    payload = JSON.parse(response.body)
    assert_equal -32002, payload.dig('error', 'code')
  end

  test "streamable http initialize works with bearer token only" do
    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize'),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Accept' => 'application/json, text/event-stream',
           'Authorization' => 'Bearer plugin-secret',
           'Origin' => 'https://allowed.example'
         }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal '2025-06-18', payload.dig('result', 'protocolVersion')
    assert_nil response.headers['Mcp-Session-Id']
    assert_equal 'https://allowed.example', response.headers['Access-Control-Allow-Origin']
  end

  test "streamable http notifications return accepted without a body" do
    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', method: 'notifications/initialized'),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Accept' => 'application/json, text/event-stream',
           'Authorization' => 'Bearer plugin-secret'
         }

    assert_response :accepted
    assert response.body.blank?
  end

  test "streamable http get returns method not allowed when sse stream is unsupported" do
    get '/mcp/http',
        headers: {
          'Accept' => 'text/event-stream',
          'Authorization' => 'Bearer plugin-secret'
        }

    assert_response :method_not_allowed
  end

  test "streamable http tool calls require a Redmine user api key" do
    post '/mcp/http',
         params: JSON.generate(
           jsonrpc: '2.0',
           id: 1,
           method: 'tools/call',
           params: {
             name: 'issue_list',
             arguments: { page: 1, per_page: 1 }
           }
         ),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Accept' => 'application/json, text/event-stream',
           'Authorization' => 'Bearer plugin-secret'
         }

    assert_response :unauthorized
    payload = JSON.parse(response.body)
    assert_equal "Missing Redmine API key", payload.dig('error', 'message')
  end

  test "streamable http works with only Redmine api key when mcp api key is blank" do
    Setting.plugin_redmine_tx_mcp = (Setting.plugin_redmine_tx_mcp || {}).merge('api_key' => '')

    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list'),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Accept' => 'application/json, text/event-stream',
           'X-Redmine-API-Key' => User.find(1).api_key
         }

    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.dig('result', 'tools').present?
  end

  test "streamable http accepts bearer as Redmine api key when mcp api key is blank" do
    Setting.plugin_redmine_tx_mcp = (Setting.plugin_redmine_tx_mcp || {}).merge('api_key' => '')

    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list'),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Accept' => 'application/json, text/event-stream',
           'Authorization' => "Bearer #{User.find(1).api_key}"
         }

    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.dig('result', 'tools').present?
  end

  test "http mcp external auth does not fall back to admin privileges" do
    post '/mcp/http',
         params: JSON.generate(
           jsonrpc: '2.0',
           id: 1,
           method: 'tools/call',
           params: {
             name: 'user_update',
             arguments: { id: 2, firstname: 'blocked' }
           }
         ),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Authorization' => 'Bearer plugin-secret',
           'X-Redmine-API-Key' => User.find(2).api_key
         }

    assert_response :forbidden
    payload = JSON.parse(response.body)
    assert_equal "Not authorized to use MCP API", payload.dig('error', 'message')
  end

  test "http mcp accepts chatbot agent token and injects project context" do
    user = User.find(1)
    project = Project.find(1)
    token = SecureRandom.hex(32)
    Rails.cache.write(
      RedmineTxMcp::ClaudeAgentSdkChatbot.token_cache_key(token),
      {
        'user_id' => user.id,
        'project_id' => project.id,
        'session_id' => 'sdk-test',
        'workspace' => {
          'user_id' => user.id,
          'project_id' => project.id,
          'session_id' => 'sdk-test'
        }
      },
      expires_in: 1.minute
    )

    post '/mcp/http',
         params: JSON.generate(
           jsonrpc: '2.0',
           id: 1,
           method: 'tools/call',
           params: {
             name: 'version_list',
             arguments: {}
           }
         ),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'X-Redmine-Tx-Mcp-Chatbot-Token' => token
         }

    assert_response :success
    payload = JSON.parse(response.body)
    assert payload.dig('result', 'content').present?
    assert_nil payload['error']
  end

  test "http mcp does not emit wildcard cors when allowed origins are blank" do
    settings = (Setting.plugin_redmine_tx_mcp || {}).merge('allowed_origins' => '')
    Setting.plugin_redmine_tx_mcp = settings

    options '/mcp/http', headers: { 'Origin' => 'https://disallowed.example' }

    assert_response :success
    assert_nil response.headers['Access-Control-Allow-Origin']
  end

  private

  def fetch_csrf_token
    get '/'
    assert_response :success

    response.body[/<meta name="csrf-token" content="([^"]+)"/, 1] ||
      response.body[/content="([^"]+)" name="csrf-token"/, 1] ||
      flunk('Expected csrf-token meta tag in response body')
  end
end
