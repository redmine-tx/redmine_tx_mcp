require 'json'
require 'logger'

module RedmineTxMcp
  class HttpMcpServer
    class << self
      def handle_request(request_body, headers = {})
        @logger ||= Logger.new(Rails.root.join('log', 'mcp_http_server.log'))

        begin
          # Parse JSON request
          request = JSON.parse(request_body)
          handle_parsed_request(request, headers)

        rescue JSON::ParserError => e
          @logger.error "JSON Parse Error: #{e.message}"
          create_error_response("Invalid JSON: #{e.message}")
        rescue => e
          @logger.error "HTTP MCP Server Error: #{e.message}"
          @logger.error e.backtrace.join("\n")
          create_error_response("Internal server error: #{e.message}")
        end
      end

      def handle_parsed_request(request, headers = {}, chatbot_context: nil)
        @logger ||= Logger.new(Rails.root.join('log', 'mcp_http_server.log'))

        begin
          return create_error_response("Invalid JSON-RPC request") unless request.is_a?(Hash)

          # Log request
          @logger.info "HTTP MCP Request: #{request['method']}"
          @logger.debug "Request data: #{request.inspect}"

          # Handle request
          response = case request['method']
                    when 'initialize'
                      handle_initialize(request)
                    when 'tools/list'
                      handle_list_tools(request)
                    when 'tools/call'
                      handle_call_tool(request, chatbot_context: chatbot_context)
                    when 'resources/list'
                      handle_list_resources(request)
                    when 'resources/read'
                      handle_read_resource(request)
                    else
                      create_error_response("Method not found: #{request['method']}", request['id'])
                    end

          @logger.info "HTTP MCP Response: #{response[:result] ? 'success' : 'error'}"
          response

        rescue => e
          @logger.error "HTTP MCP Server Error: #{e.message}"
          @logger.error e.backtrace.join("\n")
          create_error_response("Internal server error: #{e.message}")
        end
      end

      private

      def handle_initialize(request)
        {
          jsonrpc: "2.0",
          id: request['id'],
          result: {
            protocolVersion: "2025-06-18",
            capabilities: {
              tools: {},
              resources: {}
            },
            serverInfo: {
              name: "redmine-tx-mcp-http",
              version: "1.0.0"
            }
          }
        }
      end

      def handle_list_tools(request)
        tools = tool_classes.flat_map do |klass|
          klass.available_tools.map do |tool|
            sanitized = deep_dup(tool)
            schema = sanitized[:inputSchema] || sanitized[:input_schema] || sanitized['inputSchema'] || sanitized['input_schema']
            sanitize_schema!(schema) if schema.is_a?(Hash)
            sanitized
          end
        end

        {
          jsonrpc: "2.0",
          id: request['id'],
          result: {
            tools: tools
          }
        }
      end

      def handle_call_tool(request, chatbot_context: nil)
        tool_name = request.dig('params', 'name')
        arguments = request.dig('params', 'arguments') || {}
        arguments = arguments.deep_dup if arguments.respond_to?(:deep_dup)
        arguments = inject_chatbot_context(tool_name, arguments, chatbot_context)

        @logger.debug "Calling tool: #{tool_name} with args: #{arguments.inspect}"

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
        @logger.error "Tool call error: #{e.message}"
        create_error_response("Tool execution failed: #{e.message}", request['id'])
      end

      def inject_chatbot_context(tool_name, arguments, chatbot_context)
        return arguments unless chatbot_context.is_a?(Hash)

        arguments = arguments.is_a?(Hash) ? arguments.transform_keys(&:to_s) : {}
        arguments['_chatbot_context'] = true

        workspace = chatbot_context['workspace'] || chatbot_context[:workspace]
        arguments['_chatbot_workspace'] = workspace if workspace.present?

        project_id = chatbot_context['project_id'] || chatbot_context[:project_id]
        if project_id && !arguments.key?('project_id')
          tool_def = tool_classes.flat_map(&:available_tools).find { |tool| tool[:name] == tool_name }
          if tool_def&.dig(:inputSchema, :properties, :project_id)
            arguments['project_id'] = project_id
          end
        end

        arguments
      end

      def sanitize_schema!(schema)
        props = schema[:properties] || schema['properties']
        return schema unless props.is_a?(Hash)

        props.each_value do |value|
          next unless value.is_a?(Hash)

          value.delete(:required)
          value.delete('required')
        end
        schema
      end

      def deep_dup(obj)
        case obj
        when Hash then obj.each_with_object({}) { |(key, value), memo| memo[key] = deep_dup(value) }
        when Array then obj.map { |value| deep_dup(value) }
        else obj
        end
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
          RedmineTxMcp::Tools::ScriptTool
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
