require File.expand_path('test_helper', __dir__)

class McpAdminControllerTest < ActiveSupport::TestCase
  test "redacted_settings_for_log filters sensitive plugin settings" do
    controller = McpAdminController.new

    result = controller.send(:redacted_settings_for_log, {
      'enabled' => '1',
      'allowed_origins' => "https://allowed.example",
      'api_key' => 'plugin-secret',
      'claude_api_key' => 'claude-secret',
      'openai_api_key' => 'openai-secret'
    })

    assert_equal '1', result['enabled']
    assert_equal "https://allowed.example", result['allowed_origins']
    assert_equal '[FILTERED]', result['api_key']
    assert_equal '[FILTERED]', result['claude_api_key']
    assert_equal '[FILTERED]', result['openai_api_key']
  end
end
