require 'json'
require 'logger'
require 'minitest/autorun'
require 'ostruct'
require 'pathname'
require 'securerandom'
require 'fileutils'

require 'active_support/cache'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'

PLUGIN_ROOT = File.expand_path('../..', __dir__)
FileUtils.mkdir_p(File.join(PLUGIN_ROOT, 'log'))

module ActiveSupport
  class TestCase < Minitest::Test
    def self.test(name, &block)
      method_name = "test_#{name.gsub(/\s+/, '_')}"
      raise ArgumentError, "duplicate test #{method_name}" if method_defined?(method_name)

      define_method(method_name, &block)
    end

    def assert_not_nil(value, message = nil)
      refute_nil(value, message)
    end

    def before_setup
      super
      Rails.cache.clear if Rails.cache.respond_to?(:clear)
      Setting.plugin_redmine_tx_mcp = Marshal.load(Marshal.dump(DEFAULT_PLUGIN_SETTINGS))
      User.current = nil
    end
  end
end

class Object
  def stub(method_name, replacement = nil, &block)
    callable = replacement.respond_to?(:call) ? replacement : proc { replacement }
    singleton = class << self; self; end
    aliased = "__stubbed__#{method_name}__#{object_id}".to_sym
    had_original = singleton.method_defined?(method_name) || singleton.private_method_defined?(method_name)
    singleton.alias_method(aliased, method_name) if had_original

    singleton.define_method(method_name) do |*args, **kwargs, &method_block|
      if kwargs.empty?
        callable.call(*args, &method_block)
      else
        callable.call(*args, **kwargs, &method_block)
      end
    end

    block.call
  ensure
    singleton.send(:remove_method, method_name) rescue nil
    if had_original
      singleton.alias_method(method_name, aliased)
      singleton.send(:remove_method, aliased) rescue nil
    end
  end
end

DEFAULT_PLUGIN_SETTINGS = {
  'system_prompt' => '',
  'max_run_seconds' => '180',
  'max_tool_call_depth' => '15',
  'max_loop_iterations' => '0',
  'openai_endpoint_url' => 'http://example.test/v1/chat/completions',
  'openai_api_key' => 'openai-test-key',
  'claude_api_key' => 'anthropic-test-key',
  'chatbot_feature_flags' => {
    'enhanced_metrics' => true,
    'adaptive_compaction' => true,
    'provider_fallback' => true,
    'streaming_status' => true
  }
}.freeze

module Rails
  class << self
    attr_writer :application, :logger, :cache

    def root
      @root ||= Pathname.new(PLUGIN_ROOT)
    end

    def application
      @application ||= OpenStruct.new(
        routes: OpenStruct.new(
          url_helpers: Module.new do
            def self.chatbot_report_download_path(project_id:, filename:, conversation:)
              "/projects/#{project_id}/chatbot/reports/#{conversation}/#{filename}"
            end
          end
        )
      )
    end

    def logger
      @logger ||= Logger.new(File::NULL)
    end

    def cache
      @cache ||= ActiveSupport::Cache::MemoryStore.new
    end
  end
end

class Setting
  class << self
    attr_accessor :plugin_redmine_tx_mcp
  end
end

Setting.plugin_redmine_tx_mcp = Marshal.load(Marshal.dump(DEFAULT_PLUGIN_SETTINGS))

module Redmine
  class Plugin
    PluginConfig = Struct.new(:settings)

    class << self
      def find(_name)
        PluginConfig.new(default: { system_prompt: 'Unit test system prompt' })
      end
    end
  end
end

class User
  StubUser = Struct.new(:id, :name)

  class << self
    attr_accessor :current

    def find(id)
      StubUser.new(id.to_i, "User #{id}")
    end
  end
end

class Project
  StubProject = Struct.new(:id, :name)

  class << self
    def find(id)
      StubProject.new(id.to_i, "Project #{id}")
    end
  end
end

module RedmineTxMcp
  module Tools
    class BaseTool
      class << self
        def call_tool(tool_name, params)
          { 'tool' => tool_name, 'params' => params, 'ok' => true }
        end

        private

        def tool(name, properties: {})
          {
            name: name,
            description: "Mock tool for #{name}",
            inputSchema: {
              type: 'object',
              properties: properties
            }
          }
        end
      end
    end

    class IssueTool < BaseTool
      def self.available_tools
        [
          tool('issue_list', properties: { subject: { type: 'string' } }),
          tool('issue_get', properties: { id: { type: 'integer' } }),
          tool('issue_relations_get', properties: { issue_id: { type: 'integer' } }),
          tool('issue_children_summary', properties: { parent_id: { type: 'integer' } }),
          tool('issue_schedule_tree', properties: { parent_id: { type: 'integer' } }),
          tool('issue_create', properties: { project_id: { type: 'integer' }, subject: { type: 'string' } }),
          tool('issue_update', properties: { id: { type: 'integer' }, status_id: { type: 'integer' } }),
          tool('insert_bulk_update', properties: { issue_ids: { type: 'array' } }),
          tool('issue_auto_schedule_preview', properties: { parent_issue_id: { type: 'integer' } }),
          tool('issue_auto_schedule_apply', properties: { preview_token: { type: 'string' } }),
          tool('version_schedule_report', properties: { version_id: { type: 'integer' } }),
          tool('issue_relation_create', properties: { issue_id: { type: 'integer' }, related_issue_id: { type: 'integer' } }),
          tool('issue_relation_delete', properties: { id: { type: 'integer' } })
        ]
      end
    end

    class ProjectTool < BaseTool
      def self.available_tools
        [
          tool('project_list'),
          tool('project_get', properties: { id: { type: 'integer' } }),
          tool('project_members', properties: { id: { type: 'integer' } }),
          tool('project_update', properties: { id: { type: 'integer' } })
        ]
      end
    end

    class UserTool < BaseTool
      def self.available_tools
        [
          tool('user_list'),
          tool('user_get', properties: { id: { type: 'integer' } }),
          tool('user_update', properties: { id: { type: 'integer' } })
        ]
      end
    end

    class VersionTool < BaseTool
      def self.available_tools
        [
          tool('version_list', properties: { project_id: { type: 'integer' } }),
          tool('version_get', properties: { id: { type: 'integer' } }),
          tool('version_overview', properties: { version_id: { type: 'integer' } }),
          tool('version_update', properties: { id: { type: 'integer' } })
        ]
      end
    end

    class EnumerationTool < BaseTool
      def self.available_tools
        [
          tool('enum_statuses'),
          tool('enum_trackers'),
          tool('enum_priorities'),
          tool('enum_categories'),
          tool('enum_custom_fields')
        ]
      end
    end

    class SpreadsheetTool < BaseTool
      def self.available_tools
        [
          tool('spreadsheet_list_uploads'),
          tool('spreadsheet_list_sheets', properties: { file_name: { type: 'string' } }),
          tool('spreadsheet_preview_sheet', properties: { file_name: { type: 'string' }, sheet_name: { type: 'string' } }),
          tool('spreadsheet_extract_rows', properties: { file_name: { type: 'string' }, sheet_name: { type: 'string' } }),
          tool('spreadsheet_export_report', properties: { file_name: { type: 'string' } })
        ]
      end
    end

    class ScriptTool < BaseTool
      def self.available_tools
        [
          tool('run_script', properties: { script: { type: 'string' } })
        ]
      end
    end
  end
end

$LOAD_PATH.unshift(File.join(PLUGIN_ROOT, 'lib'))

require_relative '../../lib/redmine_tx_mcp/llm_format_encoder'
require_relative '../../lib/redmine_tx_mcp/chatbot_workspace'
require_relative '../../lib/redmine_tx_mcp/openai_adapter'
require_relative '../../lib/redmine_tx_mcp/chatbot_mutation_workflow'
require_relative '../../lib/redmine_tx_mcp/chatbot_run_guard'
require_relative '../../lib/redmine_tx_mcp/chatbot_loop_guard'
require_relative '../../lib/redmine_tx_mcp/chatbot_logger'
require_relative '../../lib/redmine_tx_mcp/claude_chatbot'
