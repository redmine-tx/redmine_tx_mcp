#!/usr/bin/env ruby

# Standalone MCP server runner for Claude Desktop integration
# Usage: ruby plugins/redmine_tx_mcp/bin/mcp_server.rb

require_relative '../../../config/environment'

# Ensure proper logging setup
Rails.logger = Logger.new(Rails.root.join('log', 'mcp_server.log'))
Rails.logger.level = Logger::INFO

# Start the MCP server
begin
  Rails.logger.info "Starting Redmine MCP Server (standalone mode)"
  RedmineTxMcp::McpServer.start_server
rescue => e
  Rails.logger.error "Failed to start MCP server: #{e.message}"
  Rails.logger.error e.backtrace.join("\n")
  exit 1
end