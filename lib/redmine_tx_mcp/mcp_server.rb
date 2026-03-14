require 'json'
require 'socket'
require 'logger'

module RedmineTxMcp
  class McpServer
    class << self
      # Public method for Rails console usage
      # Example: RedmineTxMcp::McpServer.handle_json_request('{"method": "tools/list", "id": 1}')
      def handle_json_request(json_string)
        setup_logger
        
        begin
          request = JSON.parse(json_string)
          response = handle_request(request)
          response
        rescue JSON::ParserError => e
          logger.error "JSON Parse Error: #{e.message}"
          create_error_response("Invalid JSON: #{e.message}", (request['id'] rescue nil))
        rescue => e
          logger.error "Request Error: #{e.message}"
          logger.error e.backtrace.join("\n")
          create_error_response("Internal server error: #{e.message}", (request['id'] rescue nil))
        end
      end

      private

      def setup_logger
        @logger ||= Logger.new(Rails.root.join('log', 'mcp_server.log'))
      end

      def logger
        @logger ||= setup_logger
      end

      def handle_request(request)
        case request['method']
        when 'initialize'
          handle_initialize(request)
        when 'tools/list'
          handle_list_tools(request)
        when 'tools/call'
          handle_call_tool(request)
        when 'resources/list'
          handle_list_resources(request)
        when 'resources/read'
          handle_read_resource(request)
        else
          create_error_response("Method not found: #{request['method']}", request['id'])
        end
      end

      def handle_initialize(request)
        {
          jsonrpc: "2.0",
          id: request['id'],
          result: {
            protocolVersion: "2024-11-05",
            capabilities: {
              tools: {},
              resources: {}
            },
            serverInfo: {
              name: "redmine-tx-mcp",
              version: "1.0.0"
            }
          }
        }
      end

      def handle_list_tools(request)
        tools = tool_classes.flat_map(&:available_tools)

        {
          jsonrpc: "2.0",
          id: request['id'],
          result: {
            tools: tools
          }
        }
      end

      def handle_call_tool(request)
        tool_name = request.dig('params', 'name')
        arguments = request.dig('params', 'arguments') || {}

        # Find the tool class that handles this tool name
        klass = tool_classes.find { |k| k.available_tools.any? { |t| t[:name] == tool_name } }

        result = if klass
          klass.call_tool(tool_name, arguments)
        else
          { error: "Unknown tool: #{tool_name}" }
        end

        {
          jsonrpc: "2.0",
          id: request['id'],
          result: {
            content: [
              {
                type: "text",
                text: result.is_a?(Hash) && result[:error] ? result[:error] : RedmineTxMcp::LlmFormatEncoder.encode(result)
              }
            ]
          }
        }
      rescue => e
        logger.error "Tool call error: #{e.message}"
        create_error_response("Tool execution failed: #{e.message}", request['id'])
      end

      def handle_list_resources(request)
        {
          jsonrpc: "2.0",
          id: request['id'],
          result: {
            resources: []
          }
        }
      end

      def handle_read_resource(request)
        create_error_response("Resource not found", request['id'])
      end

      def tool_classes
        %w[
          RedmineTxMcp::Tools::IssueTool
          RedmineTxMcp::Tools::ProjectTool
          RedmineTxMcp::Tools::UserTool
          RedmineTxMcp::Tools::VersionTool
          RedmineTxMcp::Tools::EnumerationTool
          RedmineTxMcp::Tools::SpreadsheetTool
        ].map(&:constantize)
      end

      def create_error_response(message, id = nil)
        {
          jsonrpc: "2.0",
          id: id,
          error: {
            code: -32000,
            message: message
          }
        }
      end
    end
  end
end
