#!/usr/bin/env python3
import asyncio
import json
import os
import sys
import traceback
from typing import Any


WRITE_TOOL_NAMES = {
    "issue_create",
    "issue_update",
    "issue_bulk_update",
    "insert_bulk_update",
    "issue_delete",
    "issue_relation_create",
    "issue_relation_delete",
    "issue_auto_schedule_apply",
    "version_create",
    "version_update",
    "version_delete",
    "project_create",
    "project_update",
    "project_delete",
    "project_add_member",
    "project_remove_member",
    "user_create",
    "user_update",
    "user_delete",
}

READ_TOOL_NAMES = {
    "issue_list",
    "issue_get",
    "issue_relations_get",
    "issue_children_summary",
    "issue_schedule_tree",
    "issue_auto_schedule_preview",
    "bug_statistics",
    "version_list",
    "version_get",
    "version_overview",
    "version_statistics",
    "version_schedule_report",
    "project_list",
    "project_get",
    "project_members",
    "user_list",
    "user_get",
    "user_projects",
    "user_groups",
    "user_roles",
    "spreadsheet_list_uploads",
    "spreadsheet_list_sheets",
    "spreadsheet_preview_sheet",
    "spreadsheet_extract_rows",
    "run_script",
}


def emit(event: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def attr(obj: Any, name: str, default: Any = None) -> Any:
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def block_type(block: Any) -> str | None:
    explicit = attr(block, "type")
    if explicit:
        return explicit
    if attr(block, "name") is not None and attr(block, "input") is not None:
        return "tool_use"
    if attr(block, "text") is not None:
        return "text"
    if attr(block, "tool_use_id") is not None:
        return "tool_result"
    return None


def unqualified_tool_name(tool_name: str) -> str:
    parts = tool_name.split("__")
    return parts[-1] if len(parts) >= 3 and parts[0] == "mcp" else tool_name


def tool_label(tool_name: str) -> str:
    return unqualified_tool_name(tool_name).replace("_", " ")


def build_permission_callback(
    server_name: str,
    max_write_tools: int,
    allowed_tool_names: set[str],
    mutation_requires_read: bool,
    tool_state: dict[str, Any],
):
    from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny

    prefix = f"mcp__{server_name}__"

    async def can_use_tool(tool_name: str, input_data: dict[str, Any], context: Any):
        if not tool_name.startswith(prefix):
            return PermissionResultDeny(
                message="Only Redmine MCP tools are available in this chatbot.",
                interrupt=False,
            )

        bare_name = unqualified_tool_name(tool_name)
        if allowed_tool_names and bare_name not in allowed_tool_names:
            return PermissionResultDeny(
                message=(
                    f"The tool `{bare_name}` is not relevant to this request. "
                    "Use one of the selected Redmine MCP tools instead."
                ),
                interrupt=False,
            )

        if bare_name in WRITE_TOOL_NAMES:
            if mutation_requires_read and tool_state.get("successful_read_count", 0) <= 0:
                return PermissionResultDeny(
                    message=(
                        "Read the current Redmine state with an MCP read tool before running a write tool."
                    ),
                    interrupt=False,
                )

            if tool_state.get("write_pending_readback"):
                return PermissionResultDeny(
                    message=(
                        "Read back and verify the previous Redmine write before attempting another write."
                    ),
                    interrupt=False,
                )

            if tool_state["write_count"] >= max_write_tools:
                return PermissionResultDeny(
                    message=(
                        f"At most {max_write_tools} Redmine write tool call(s) may run for this request. "
                        "Ask the user to continue after verifying the current changes."
                    ),
                    interrupt=False,
                )
            tool_state["write_count"] += 1
            tool_state["write_pending_readback"] = True

        return PermissionResultAllow()

    return can_use_tool


async def prompt_stream(message: str):
    yield {
        "type": "user",
        "message": {"role": "user", "content": message},
        "parent_tool_use_id": None,
        "session_id": "redmine-chatbot",
    }


def message_type(message: Any) -> str:
    explicit = attr(message, "type")
    if explicit:
        return explicit

    class_name = message.__class__.__name__
    if class_name.endswith("SystemMessage"):
        return "system"
    if class_name.endswith("AssistantMessage"):
        return "assistant"
    if class_name.endswith("UserMessage"):
        return "user"
    if class_name.endswith("ResultMessage"):
        return "result"
    if class_name.endswith("RateLimitEvent"):
        return "rate_limit"
    if class_name.endswith("StreamEvent"):
        return "stream_event"
    return class_name


def emit_assistant_events(message: Any, tool_state: dict[str, Any]) -> None:
    content = attr(message, "content", []) or []
    text_parts: list[str] = []

    for block in content:
        btype = block_type(block)
        if btype == "tool_use":
            name = attr(block, "name", "")
            tool_id = attr(block, "id")
            if tool_id:
                tool_state["tool_uses"][tool_id] = {
                    "name": unqualified_tool_name(name),
                    "input": attr(block, "input", {}) or {},
                }
            emit({
                "type": "tool_call",
                "tool": unqualified_tool_name(name),
                "status": f"Calling {tool_label(name)}...",
            })
        elif btype == "text":
            text = attr(block, "text", "")
            if text:
                text_parts.append(text)

    if text_parts:
        emit({"type": "thinking", "message": "응답을 정리 중입니다..."})


def emit_user_events(message: Any, tool_state: dict[str, Any]) -> None:
    tool_result = attr(message, "tool_use_result")
    parent_tool_use_id = attr(message, "parent_tool_use_id")
    content = attr(message, "content", []) or []
    result_blocks = [
        block for block in content
        if block_type(block) == "tool_result"
    ] if isinstance(content, list) else []

    if result_blocks:
        for block in result_blocks:
            tool_use_id = attr(block, "tool_use_id")
            tool_use = tool_state["tool_uses"].get(tool_use_id, {})
            tool_name = tool_use.get("name") or "redmine"
            is_error = bool(attr(block, "is_error", False))
            if not is_error and tool_name in READ_TOOL_NAMES:
                tool_state["successful_read_count"] += 1
                tool_state["write_pending_readback"] = False

            emit({
                "type": "tool_result",
                "tool": tool_name,
                "input": tool_use.get("input") or {},
                "content": attr(block, "content"),
                "is_error": is_error,
            })
        return

    if tool_result is not None or parent_tool_use_id is not None:
        tool_use = tool_state["tool_uses"].get(parent_tool_use_id, {})
        tool_name = tool_use.get("name") or "redmine"
        if tool_name in READ_TOOL_NAMES:
            tool_state["successful_read_count"] += 1
            tool_state["write_pending_readback"] = False

        emit({
            "type": "tool_result",
            "tool": tool_name,
            "input": tool_use.get("input") or {},
            "content": tool_result,
            "is_error": False,
        })


def emit_system_events(message: Any) -> None:
    subtype = attr(message, "subtype")
    data = attr(message, "data", {}) or {}
    session_id = data.get("session_id") if isinstance(data, dict) else None
    if subtype == "init" and session_id:
        emit({"type": "session", "session_id": session_id})
        emit({"type": "phase", "phase": "sdk_session", "status": "Agent SDK session initialized."})


async def main() -> int:
    try:
        request = json.loads(sys.stdin.read())
    except Exception as exc:
        emit({"type": "error", "message": f"Invalid worker request: {exc}"})
        emit({"type": "done"})
        return 2

    try:
        from claude_agent_sdk import ClaudeAgentOptions, query
    except Exception as exc:
        emit({
            "type": "error",
            "message": (
                "Claude Agent SDK is not installed. Install it with "
                "`pip install claude-agent-sdk` in the Python environment used by this worker. "
                f"Import error: {exc}"
            ),
        })
        emit({"type": "done"})
        return 3

    server_name = request.get("mcp_server_name") or "redmine"
    headers = request.get("mcp_headers") or {}
    mcp_url = request.get("mcp_url")
    if not mcp_url:
        emit({"type": "error", "message": "Missing MCP URL for Agent SDK worker."})
        emit({"type": "done"})
        return 4

    allowed_tool_names = {
        str(name) for name in (request.get("allowed_tool_names") or [])
        if str(name).strip()
    }
    tool_state: dict[str, Any] = {
        "tool_uses": {},
        "write_count": 0,
        "successful_read_count": 0,
        "write_pending_readback": False,
    }
    try:
        max_write_tools = int(request.get("max_write_tools") or 1)
    except (TypeError, ValueError):
        max_write_tools = 1
    max_write_tools = max(1, min(max_write_tools, 5))

    options_kwargs: dict[str, Any] = {
        "tools": [],
        "allowed_tools": [],
        "disallowed_tools": [
            "Bash",
            "Read",
            "Write",
            "Edit",
            "Glob",
            "Grep",
            "WebFetch",
            "WebSearch",
            "Agent",
            "AskUserQuestion",
            "TodoWrite",
        ],
        "permission_mode": "default",
        "can_use_tool": build_permission_callback(
            server_name,
            max_write_tools=max_write_tools,
            allowed_tool_names=allowed_tool_names,
            mutation_requires_read=bool(request.get("mutation_requires_read")),
            tool_state=tool_state,
        ),
        "system_prompt": request.get("system_prompt") or None,
        "mcp_servers": {
            server_name: {
                "type": "http",
                "url": mcp_url,
                "headers": headers,
            }
        },
        "max_turns": request.get("max_turns") or 15,
        "model": request.get("model") or None,
        "cwd": request.get("cwd") or os.getcwd(),
        "setting_sources": [],
    }

    resume_session_id = request.get("resume_session_id")
    if resume_session_id:
        options_kwargs["resume"] = resume_session_id

    options = ClaudeAgentOptions(**options_kwargs)
    emit({"type": "phase", "phase": "analysis", "status": "Claude Agent SDK is analyzing the request..."})

    result_text = None
    result_is_error = False

    try:
        async for message in query(prompt=prompt_stream(request.get("message") or ""), options=options):
            mtype = message_type(message)
            if mtype == "system":
                emit_system_events(message)
            elif mtype == "assistant":
                emit_assistant_events(message, tool_state)
            elif mtype == "user":
                emit_user_events(message, tool_state)
            elif mtype == "result":
                session_id = attr(message, "session_id")
                if session_id:
                    emit({"type": "session", "session_id": session_id})
                result_is_error = bool(attr(message, "is_error", False))
                result_text = attr(message, "result") or ""

                usage = attr(message, "usage")
                cost = attr(message, "total_cost_usd")
                emit({
                    "type": "metrics",
                    "num_turns": attr(message, "num_turns", None),
                    "stop_reason": attr(message, "stop_reason", None),
                    "total_cost_usd": cost,
                    "usage": usage,
                })

        if result_is_error:
            emit({"type": "error", "message": result_text or "Claude Agent SDK returned an error."})
            emit({"type": "done"})
            return 5

        emit({"type": "answer", "message": result_text or ""})
        emit({"type": "done"})
        return 0
    except Exception as exc:
        emit({"type": "error", "message": str(exc)})
        emit({"type": "done"})
        traceback.print_exc(file=sys.stderr)
        return 6


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
