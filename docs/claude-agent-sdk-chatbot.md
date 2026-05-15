# Claude Agent SDK Chatbot Backend

The chatbot can run through Anthropic Claude Agent SDK instead of the legacy Ruby
tool loop.

## Install

Install the SDK in a Python virtual environment and configure Redmine to use
that environment's Python executable:

```sh
python3 -m venv plugins/redmine_tx_mcp/.venv
plugins/redmine_tx_mcp/.venv/bin/python -m pip install --upgrade pip
plugins/redmine_tx_mcp/.venv/bin/python -m pip install -r plugins/redmine_tx_mcp/requirements-agent-sdk.txt
```

Then set **Agent SDK Python** in the plugin settings, or set
`REDMINE_TX_MCP_AGENT_SDK_PYTHON`, to the venv Python path:

```sh
/path/to/redmine/plugins/redmine_tx_mcp/.venv/bin/python
```

This avoids installing packages into the system Python, which may be blocked by
PEP 668 `externally-managed-environment` on Debian/Ubuntu Python installs. If
`python3 -m venv` is unavailable, install the OS venv package first, for example
`sudo apt install python3-venv`.

## Runtime Path

Rails still owns:

- project chatbot UI and SSE streaming
- conversation records
- upload/report workspace isolation
- Redmine permission checks

The SDK worker owns:

- the Claude Agent SDK loop
- MCP tool planning and execution
- SDK session resume

Flow:

```text
ChatbotController
  -> ClaudeAgentSdkChatbot
  -> bin/chatbot_agent_sdk_worker.py
  -> Claude Agent SDK
  -> /mcp/http with a short-lived chatbot token
  -> Redmine MCP tools
```

## Settings

- **Chatbot Agent Backend**: choose `Claude Agent SDK` or `Legacy Ruby loop`.
- **Agent SDK Python**: optional Python executable path.
- **Agent SDK Worker Path**: optional custom worker script path.
- **Agent SDK MCP URL**: optional internal URL for this Redmine instance's
  `/mcp/http` endpoint. Leave blank unless the worker cannot reach
  `request.base_url`.

The SDK backend only supports Anthropic Claude models. Use the legacy backend if
you need the OpenAI-compatible provider path.
