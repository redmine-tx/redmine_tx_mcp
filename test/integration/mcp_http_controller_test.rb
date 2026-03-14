require File.expand_path('../test_helper', __dir__)

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

  test "http mcp requires a Redmine user api key" do
    post '/mcp/http',
         params: JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list'),
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'Authorization' => 'Bearer plugin-secret',
           'Origin' => 'https://allowed.example'
         }

    assert_response :unauthorized
    payload = JSON.parse(response.body)
    assert_equal "Missing Redmine API key", payload.dig('error', 'message')
    assert_equal 'https://allowed.example', response.headers['Access-Control-Allow-Origin']
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
