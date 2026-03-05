# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html

get 'mcp', to: 'mcp#index'
post 'mcp/call_tool', to: 'mcp#call_tool'
get 'mcp/list_tools', to: 'mcp#list_tools'
get 'mcp/get_tool', to: 'mcp#get_tool'

# HTTP MCP Server endpoints
post 'mcp/http', to: 'mcp_http#mcp_request'
options 'mcp/http', to: 'mcp_http#options'

get 'mcp_admin', to: 'mcp_admin#index'
get 'mcp_admin/index', to: 'mcp_admin#index'
get 'mcp_admin/models', to: 'mcp_admin#models'

# Project-specific chatbot
get  'projects/:project_id/chatbot',        to: 'chatbot#index',       as: 'project_chatbot'
post 'projects/:project_id/chatbot/submit', to: 'chatbot#chat_submit', as: 'chat_submit_chatbot'
post 'projects/:project_id/chatbot/reset',  to: 'chatbot#reset',      as: 'reset_chatbot'