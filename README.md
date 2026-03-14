# Redmine TX MCP Plugin

Model Context Protocol (MCP) integration plugin for Redmine that enables Claude API connectivity and other LLM integrations.

## Features

- **STDIO-based MCP Server**: Runs as a standard MCP server using STDIO communication
- **Comprehensive API Access**: Full CRUD operations for Issues, Projects, and Users
- **Permission-aware**: Respects Redmine's permission system
- **RESTful Web API**: HTTP endpoints for direct integration
- **Admin Interface**: Web-based configuration and monitoring
- **Security Features**: API key authentication and origin restrictions

## Available Tools

### Issue Management
- `issue_list`: List and filter issues with pagination
- `issue_get`: Get detailed issue information
- `issue_create`: Create new issues
- `issue_update`: Update existing issues
- `issue_delete`: Delete issues

### Project Management
- `project_list`: List and filter projects
- `project_get`: Get detailed project information
- `project_create`: Create new projects
- `project_update`: Update existing projects
- `project_delete`: Delete projects
- `project_members`: Get project members
- `project_add_member`: Add members to projects
- `project_remove_member`: Remove members from projects

### User Management
- `user_list`: List and filter users
- `user_get`: Get detailed user information
- `user_create`: Create new users
- `user_update`: Update existing users
- `user_delete`: Delete users
- `user_projects`: Get user's projects
- `user_groups`: Get user's groups
- `user_roles`: Get user's roles across projects

## Installation

1. Clone the plugin to your Redmine plugins directory:
```bash
cd {REDMINE_ROOT}/plugins/
git clone [repository-url] redmine_tx_mcp
```

2. Install dependencies and run migrations:
```bash
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

3. Restart your Redmine server

4. Configure permissions in Redmine Admin → Roles and permissions:
   - `use_mcp_api`: Allow users to access MCP tools
   - `admin_mcp`: Allow users to manage MCP settings

## Configuration

### Admin Settings

Access the MCP settings via **Administration → MCP Settings**:

- **Enable MCP Server**: Toggle MCP server functionality
- **API Key**: Authentication key for MCP connections
- **Allowed Origins**: Restrict access to specific domains (leave blank to allow all origins)
- **Log Level**: Control logging verbosity
- **Caching Settings**: Configure response caching for performance

### Claude Desktop Integration (Local)

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "redmine": {
      "command": "cd",
      "args": ["/path/to/redmine", "&&", "bundle", "exec", "ruby", "-e", "require_relative 'config/environment'; RedmineTxMcp::McpServer.start_server"]
    }
  }
}
```

### Claude Web Integration (Remote HTTP)

For remote access from other machines (like Windows Claude), use the HTTP MCP endpoint:

**Endpoint**: `POST http://your-redmine-server.com/mcp/http`

**Browser session mode**

If the caller is already logged into Redmine in the same browser, the plugin can use the existing Redmine session instead of a user API key. In that case:

- the user must have the `use_mcp_api` permission
- requests must be same-origin and include a valid CSRF token
- no `X-Redmine-API-Key` header is required

**External client mode**

For non-browser clients that do not share the Redmine login session, keep using a plugin API key plus a Redmine user API key.

**Headers**:
```
Content-Type: application/json
Authorization: Bearer YOUR_API_KEY
X-Redmine-API-Key: USER_API_KEY
```

**Example Request**:
```bash
curl -X POST "http://your-redmine-server.com/mcp/http" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "X-Redmine-API-Key: USER_API_KEY" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list"
  }'
```

**Claude Web Configuration**:
Unfortunately, Claude Web doesn't support custom MCP servers directly. You'll need to use the HTTP API manually or integrate it through a proxy service.

**Alternative: SSH Tunnel**
For Claude Desktop on Windows to access the Ubuntu server:
```bash
# On Windows, create SSH tunnel
ssh -L 3001:localhost:3000 user@your-ubuntu-server.com

# Then use in claude_desktop_config.json
{
  "mcpServers": {
    "redmine": {
      "command": "curl",
      "args": ["-X", "POST", "http://localhost:3001/mcp/http",
               "-H", "Authorization: Bearer YOUR_API_KEY",
               "-H", "X-Redmine-API-Key: USER_API_KEY",
               "-H", "Content-Type: application/json",
               "-d", "@-"]
    }
  }
}
```

## Usage Examples

### STDIO Mode (Recommended)

Start the MCP server directly:

```bash
cd /path/to/redmine
bundle exec ruby -e "require_relative 'config/environment'; RedmineTxMcp::McpServer.start_server"
```

### HTTP API Mode

Direct API calls to Redmine:

```bash
# List projects
curl -X GET "http://your-redmine/mcp/list_tools" \
  -H "Authorization: Bearer YOUR_API_KEY"

# Create an issue
curl -X POST "http://your-redmine/mcp/call_tool" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "name": "issue_create",
    "arguments": {
      "project_id": 1,
      "tracker_id": 1,
      "subject": "New issue from MCP",
      "description": "Created via Model Context Protocol"
    }
  }'
```

## Architecture

The plugin implements the Model Context Protocol specification with:

- **McpServer**: Main server handling STDIO communication
- **Tool Classes**: Specialized classes for each domain (Issues, Projects, Users)
- **Base Tool**: Common functionality and error handling
- **Web Controllers**: HTTP API endpoints for direct access
- **Admin Interface**: Web-based management and monitoring

## Development

### Running Tests

```bash
bundle exec rake redmine:plugins:test NAME=redmine_tx_mcp
```

### Adding New Tools

1. Create a new tool class in `lib/redmine_tx_mcp/tools/`
2. Inherit from `BaseTool` and implement `available_tools` and `call_tool` methods
3. Register the tool in `McpServer` and controllers

### Debugging

Check the MCP server logs:

```bash
tail -f log/mcp_server.log
```

Enable debug logging in the admin settings for detailed request/response information.

## Security Considerations

- Always use strong API keys in production
- Restrict allowed origins to trusted domains
- Monitor access logs for suspicious activity
- Regularly rotate API keys
- Keep Redmine and plugin updated

## Requirements

- Redmine 5.0.0 or higher
- Ruby 2.7 or higher
- Rails 6.1 or higher

## License

This plugin is released under the same license as Redmine (GPL-2.0).

## Support

For issues and feature requests, please use the project's issue tracker.

## Contributing

1. Fork the project
2. Create a feature branch
3. Make your changes
4. Add tests
5. Submit a pull request
