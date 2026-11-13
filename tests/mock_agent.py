#!/usr/bin/env python3
"""Minimal ACP agent used by acp.nvim's test suite.

Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout. Behavior is driven by
the prompt text so tests can request specific flows:

  contains "hello"      -> one streamed text message
  contains "permission" -> tool call + session/request_permission
  contains "slow"       -> streams, then waits for session/cancel
  contains "fail"       -> returns a JSON-RPC error
  contains "toolfail"   -> tool call that completes with failed status
  contains "subagent"   -> a delegated turn: tool call plus agent text, both
                           tagged with `opencode/child-session` metadata

Agent profiles (ACP_MOCK_PROFILE=opencode|claude|pi|generic, default opencode)
reproduce the protocol shapes of real agents. Shapes are taken from upstream
sources and recorded scenarios: sst/opencode packages/cli/src/acp,
agentclientprotocol/claude-agent-acp src/tests/acp-scenarios, svkozak/pi-acp
src/acp. The default profile keeps the historic mock behaviour.

Scenario triggers (prompt text starts with):

  @ask          ask the user a question the way the profile does
                (claude/opencode/generic: elicitation/create form when the
                client declared elicitation.form; pi: select permission)
  @plan-approve claude ExitPlanMode plan approval permission
  @bash         a shell tool: claude text or terminal _meta, pi terminal
                content whose output only travels in _meta
  @null         updates carrying JSON null in optional fields
  @cancel-request  a permission request the agent withdraws via $/cancel_request

Each scenario ends with an agent message "RESULT:<json>" describing what the
client answered, so tests can assert it from the transcript.

Environment:

  ACP_MOCK_LOG=path        append every message received from the client
  ACP_MOCK_EARLY_UPDATE=1  send session updates before the session/new response
  ACP_MOCK_AUTH_REQUIRED=1 session/new fails with auth_required until login
  ACP_MOCK_AUTH_MARKER=path  login marker; `mock_agent.py --mock-login` creates it
"""
import json
import os
import sys
import threading
import time

SESSION_ID = "sess_mock"
SESSION_CWD = None  # set from session/new, so filtering matches the client
SESSIONS = {
    SESSION_ID: {"sessionId": SESSION_ID, "title": None, "updatedAt": "2026-01-01T00:00:00Z"},
    # Lives in the same directory as the active session.
    "sess_old": {
        "sessionId": "sess_old",
        "title": "Old conversation",
        "updatedAt": "2026-01-01T00:00:00Z",
        "cwd": None,  # filled in from session/new
    },
    # Deliberately stored under another directory, so cwd filtering is testable.
    "sess_elsewhere": {
        "sessionId": "sess_elsewhere",
        "title": "Elsewhere session",
        "updatedAt": "2026-01-01T00:00:00Z",
        "cwd": "/some/other/project",
    },
}
write_lock = threading.Lock()
cancel_event = threading.Event()
# Active prompt requests: msg_id -> True
active_prompts = {}
# Image block summaries from the most recent prompts, for the image suite only.
image_blocks = []


class PendingPermission:
    def __init__(self, msg_id):
        self.msg_id = msg_id
        self.event = threading.Event()
        self.option = None


permissions = {}
permissions_lock = threading.Lock()

PROFILE = os.environ.get("ACP_MOCK_PROFILE", "opencode")
LOG_PATH = os.environ.get("ACP_MOCK_LOG")
# Capabilities the client declared in initialize.
CLIENT_CAPS = {}
# Generic agent -> client requests: id -> PendingPermission (reused as a slot).
client_requests = {}
next_request_id = [9100]


def log_incoming(msg):
    if not LOG_PATH:
        return
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(msg) + "\n")


def client_declares(*path):
    """Whether the client declared a capability, e.g. ("elicitation", "form")."""
    node = CLIENT_CAPS
    for key in path:
        if not isinstance(node, dict) or node.get(key) is None:
            return False
        node = node[key]
    return node is not False


def request_client(method, params, timeout=10, before_wait=None):
    """Send an agent -> client request and wait for its response message."""
    with permissions_lock:
        req_id = next_request_id[0]
        next_request_id[0] += 1
        slot = PendingPermission(None)
        client_requests[req_id] = slot
    send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
    if before_wait:
        before_wait(req_id)
    slot.event.wait(timeout=timeout)
    with permissions_lock:
        client_requests.pop(req_id, None)
    return req_id, slot.option


def say(msg_id, text):
    update({"sessionUpdate": "agent_message_chunk", "messageId": "result_" + str(msg_id),
            "content": {"type": "text", "text": text}})


def report(msg_id, payload):
    say(msg_id, "RESULT:" + json.dumps(payload, sort_keys=True, ensure_ascii=False))


def send(obj):
    with write_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def result(msg_id, payload):
    send({"jsonrpc": "2.0", "id": msg_id, "result": payload})


def error(msg_id, code, message):
    send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def update(update_obj):
    notify("session/update", {"sessionId": SESSION_ID, "update": update_obj})


def finish(msg_id, stop_reason="end_turn"):
    with permissions_lock:
        active_prompts.pop(msg_id, None)
    cancel_event.clear()
    result(msg_id, {"stopReason": stop_reason})


# --- Profiles -----------------------------------------------------------------

MOCK_PATH = os.path.abspath(__file__)
AUTH_MARKER = os.environ.get("ACP_MOCK_AUTH_MARKER")
authenticated = [False]

CLAUDE_MODES = [
    ("default", "Manual", "standard"),
    ("acceptEdits", "Accept edits", "standard"),
    ("plan", "Plan", "plan"),
    ("auto", "Auto", "auto_review"),
    ("bypassPermissions", "Bypass permissions", "full_access"),
]
PI_LEVELS = ["off", "minimal", "low", "medium", "high"]
current_mode = {"claude": "default", "pi": "medium"}


def initialize_result():
    if PROFILE == "claude":
        caps = {
            "loadSession": True,
            "promptCapabilities": {"embeddedContext": True, "image": True},
            "mcpCapabilities": {"http": True, "sse": True},
            "sessionCapabilities": {"list": {}, "resume": {}, "close": {}, "delete": {}, "fork": {}},
            "auth": {"logout": {}},
        }
        info = {"name": "@agentclientprotocol/claude-agent-acp", "title": "Claude Agent", "version": "0.106.0"}
    elif PROFILE == "pi":
        caps = {
            "loadSession": True,
            "promptCapabilities": {"image": True, "audio": False, "embeddedContext": False},
            "mcpCapabilities": {"http": False, "sse": False},
            "sessionCapabilities": {"list": {}, "delete": {}},
        }
        info = {"name": "pi-acp", "title": "pi", "version": "0.0.34"}
    elif PROFILE == "generic":
        caps = {"loadSession": False, "promptCapabilities": {}}
        info = {"name": "generic-mock", "version": "0.1.0"}
    else:
        caps = {
            "loadSession": True,
            # ACP_IMAGE_CAPABILITY=1 lets the image regression suite assert
            # that a real `image` block arrives; the default stays false so
            # the capability gate is exercised too.
            "promptCapabilities": {
                "embeddedContext": True,
                "image": os.environ.get("ACP_IMAGE_CAPABILITY") == "1",
            },
            "sessionCapabilities": {"list": {}, "resume": {}, "delete": {}, "close": {}},
        }
        info = {"name": "mock", "title": "Mock Agent", "version": "0.1.0"}
    return {"protocolVersion": 1, "agentCapabilities": caps, "agentInfo": info, "authMethods": auth_methods()}


def auth_methods():
    """Login methods, only offered in the shapes the client declared support for."""
    if PROFILE == "generic":
        return [{"id": "mock-agent-login", "name": "Log in", "description": "Log in through the agent"}]
    terminal = client_declares("auth", "terminal")
    meta = client_declares("_meta", "terminal-auth")
    if not terminal and not meta:
        return []
    method = {
        "id": PROFILE + "-login",
        "name": "Log in to " + PROFILE,
        "description": "Run the login command in a terminal",
    }
    if terminal:
        method["type"] = "terminal"
        method["args"] = ["--mock-login"]
    if meta:
        method["_meta"] = {"terminal-auth": {
            "command": "python3", "args": [MOCK_PATH, "--mock-login"], "label": PROFILE + " login",
        }}
    return [method]


def logged_in():
    if authenticated[0]:
        return True
    return bool(AUTH_MARKER) and os.path.exists(AUTH_MARKER)


def new_session_result():
    if PROFILE == "claude":
        mode = current_mode["claude"]
        return {
            "sessionId": SESSION_ID,
            "modes": {
                "currentModeId": mode,
                "availableModes": [
                    {"id": i, "name": n, "description": n, "_meta": {"kind": k}} for i, n, k in CLAUDE_MODES
                ],
            },
            "configOptions": [
                {
                    "id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": mode,
                    "options": [{"value": i, "name": n, "_meta": {"kind": k}} for i, n, k in CLAUDE_MODES],
                },
                {
                    "id": "model", "name": "Model", "category": "model", "type": "select",
                    "currentValue": "claude-sonnet-5-5",
                    "options": [{"value": "claude-sonnet-5-5", "name": "Sonnet"},
                                {"value": "claude-opus-5-5", "name": "Opus"}],
                },
                {"id": "fast", "name": "Fast mode", "category": "other", "type": "boolean", "currentValue": False},
            ],
        }
    if PROFILE == "pi":
        level = current_mode["pi"]
        return {
            "sessionId": SESSION_ID,
            # pi exposes thinking levels both as legacy modes and as a
            # thought_level config option.
            "modes": {
                "currentModeId": level,
                "availableModes": [{"id": i, "name": "Thinking: " + i, "description": None} for i in PI_LEVELS],
            },
            "configOptions": [
                {
                    "id": "model", "name": "Model", "category": "model", "type": "select",
                    "currentValue": "pi-model-1",
                    "options": [{"value": "pi-model-1", "name": "Pi Model One", "description": None}],
                },
                {
                    "id": "thinking", "name": "Thinking", "category": "thought_level", "type": "select",
                    "currentValue": level,
                    "options": [{"value": i, "name": "Thinking: " + i, "description": None} for i in PI_LEVELS],
                },
            ],
        }
    if PROFILE == "generic":
        return {"sessionId": SESSION_ID}
    return {
        "sessionId": SESSION_ID,
        "configOptions": [
            {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": "mock-1",
                "options": [
                    {"value": "mock-1", "name": "Mock One"},
                    {"value": "mock-2", "name": "Mock Two"},
                ],
            },
            {
                "id": "mode",
                "name": "Mode",
                "category": "mode",
                "type": "select",
                "currentValue": "ask",
                "options": [
                    {"value": "ask", "name": "Ask"},
                    {"value": "code", "name": "Code"},
                ],
            },
        ],
    }


# --- Scenarios ----------------------------------------------------------------

ASK_FORM = {
    "type": "object",
    "properties": {
        "database": {
            "type": "string", "title": "Database",
            "oneOf": [{"const": "postgres", "title": "Postgres", "description": "Relational"},
                      {"const": "redis", "title": "Redis", "description": "Key-value"}],
        },
        "database_custom": {"type": "string", "title": "Database (other)", "description": "Type your own answer"},
        "features": {
            "type": "array", "title": "Features",
            "items": {"anyOf": [{"const": "auth", "title": "Auth"}, {"const": "cache", "title": "Cache"}]},
        },
        "confirm": {"type": "boolean", "title": "Proceed", "default": True},
    },
    "required": ["database"],
}

CLAUDE_ASK_FORM = {
    "type": "object",
    "properties": {
        "question_0": {
            "type": "string", "title": "Database",
            "oneOf": [
                {"const": "Postgres", "title": "Postgres", "description": "Relational",
                 "_meta": {"_claude/askUserQuestionOption": {"preview": "CREATE TABLE t ();"}}},
                {"const": "Redis", "title": "Redis", "description": "Key-value"},
            ],
        },
        "question_0_custom": {
            "type": "string", "title": "Other",
            "description": "Type your own answer, or add a note to the option you chose above (optional).",
        },
    },
}


def scenario_ask(msg_id):
    if PROFILE == "pi":
        # pi extension UI `select`: every option is allow_once, the optionId
        # index maps back to the choice (pi-acp src/acp/session.ts).
        req, response = request_client("session/request_permission", {
            "sessionId": SESSION_ID,
            "toolCall": {
                "toolCallId": "pi-ui-1", "title": "Pick a database", "kind": "other", "status": "pending",
                "rawInput": {"method": "select", "title": "Pick a database", "options": ["Postgres", "Redis"]},
            },
            "options": [{"optionId": "choice-0", "name": "Postgres", "kind": "allow_once"},
                        {"optionId": "choice-1", "name": "Redis", "kind": "allow_once"}],
        })
        report(msg_id, {"permission": response_body(response)})
        return finish(msg_id)
    if PROFILE == "claude":
        tool = {"toolCallId": "toolu_ask", "kind": "other", "title": "Which database?",
                "_meta": {"claudeCode": {"toolName": "AskUserQuestion"}}}
        update(dict(tool, sessionUpdate="tool_call", status="pending", content=[], rawInput={}))
        if not client_declares("elicitation", "form"):
            # claude-agent-acp disables AskUserQuestion entirely without form
            # elicitation; the model then asks in plain text.
            say(msg_id, "Which database should I use?")
            report(msg_id, {"elicitation": "unsupported"})
            return finish(msg_id)
        req, response = request_client("elicitation/create", {
            "sessionId": SESSION_ID, "toolCallId": "toolu_ask", "mode": "form",
            "message": "Which database?", "requestedSchema": CLAUDE_ASK_FORM,
        })
        update({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_ask", "status": "completed"})
        report(msg_id, {"elicitation": response_body(response)})
        return finish(msg_id)
    if not client_declares("elicitation", "form"):
        # OpenCode cancels an unshown question and lets the model continue.
        report(msg_id, {"elicitation": "unsupported"})
        return finish(msg_id)
    req, response = request_client("elicitation/create", {
        "sessionId": SESSION_ID, "mode": "form", "message": "Answer a few questions",
        "requestedSchema": ASK_FORM,
    })
    report(msg_id, {"elicitation": response_body(response)})
    return finish(msg_id)


def scenario_plan_approve(msg_id):
    # Recorded shape: claude-agent-acp tests/acp-scenarios exit-plan-approve.
    plan = "# Plan\n1. Do it"
    tool = {"toolCallId": "toolu_plan", "kind": "switch_mode", "name": "ExitPlanMode", "title": "Approve Plan",
            "rawInput": {"plan": plan},
            "content": [{"type": "content", "content": {"type": "text", "text": plan}}]}
    update(dict(tool, sessionUpdate="tool_call", status="pending"))
    req, response = request_client("session/request_permission", {
        "_meta": {"permission": {"title": "Ready to code?", "version": 1}},
        "sessionId": SESSION_ID,
        "toolCall": dict(tool, status="pending"),
        "options": [
            {"kind": "allow_once", "name": "Yes, manually approve edits", "optionId": "exit-plan-default"},
            {"kind": "allow_always", "name": "Yes, clear context (0% used) and use auto mode",
             "optionId": "exit-plan-clear-auto"},
            {"kind": "allow_always", "name": "Yes, and use auto mode", "optionId": "exit-plan-auto"},
            {"kind": "allow_always", "name": "Yes, and bypass permissions", "optionId": "exit-plan-bypass"},
            {"kind": "reject_once", "name": "No, keep planning", "optionId": "reject"},
        ],
    })
    body = response_body(response)
    chosen = ((body or {}).get("outcome") or {}).get("optionId") if isinstance(body, dict) else None
    target = {"exit-plan-default": "default", "exit-plan-auto": "auto", "exit-plan-clear-auto": "auto",
              "exit-plan-bypass": "bypassPermissions"}.get(chosen)
    if target:
        current_mode["claude"] = target
        update({"sessionUpdate": "current_mode_update", "currentModeId": target})
        update({"sessionUpdate": "config_option_update",
                "configOptions": new_session_result().get("configOptions", [])})
    update({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_plan",
            "status": "completed" if target else "failed"})
    report(msg_id, {"permission": body})
    return finish(msg_id)


def scenario_bash(msg_id):
    output = "a.ts\nb.ts\n"
    if PROFILE == "pi":
        # pi-acp src/acp/translate/bash.ts: terminal content that was never
        # created through terminal/create; output only travels in _meta.
        update({"sessionUpdate": "tool_call", "toolCallId": "bash_1", "title": "ls", "kind": "execute",
                "status": "pending", "content": [{"type": "terminal", "terminalId": "bash_1"}],
                "_meta": {"terminal_info": {"terminal_id": "bash_1", "cwd": SESSION_CWD_REF[0]}}})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "bash_1", "status": "in_progress",
                "_meta": {"terminal_output": {"terminal_id": "bash_1", "data": output}}})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "bash_1", "status": "completed",
                "_meta": {"terminal_exit": {"terminal_id": "bash_1", "exit_code": 0, "signal": None}}})
        report(msg_id, {"terminal": "pi"})
        return finish(msg_id)
    if PROFILE == "claude" and client_declares("_meta", "terminal_output"):
        meta = {"claudeCode": {"toolName": "Bash"}}
        update({"sessionUpdate": "tool_call", "toolCallId": "toolu_bash", "title": "ls -la", "kind": "execute",
                "status": "in_progress", "rawInput": {"command": "ls -la"},
                "_meta": dict(meta, terminal_info={"terminal_id": "toolu_bash"})})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_bash",
                "_meta": dict(meta, terminal_output={"terminal_id": "toolu_bash", "data": output})})
        update({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_bash", "status": "completed",
                "_meta": dict(meta, terminal_exit={"terminal_id": "toolu_bash", "exit_code": 0, "signal": None})})
        report(msg_id, {"terminal": "meta"})
        return finish(msg_id)
    update({"sessionUpdate": "tool_call", "toolCallId": "toolu_bash", "title": "ls -la", "kind": "execute",
            "status": "in_progress", "rawInput": {"command": "ls -la"}})
    update({"sessionUpdate": "tool_call_update", "toolCallId": "toolu_bash", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "```console\na.ts\nb.ts\n```"}}],
            "rawOutput": "a.ts\nb.ts"})
    report(msg_id, {"terminal": "text"})
    return finish(msg_id)


def scenario_null(msg_id):
    update({"sessionUpdate": "tool_call", "toolCallId": "call_null", "title": "Null fields", "kind": "read",
            "status": "pending", "content": None, "locations": None, "rawInput": None, "_meta": None})
    update({"sessionUpdate": "tool_call_update", "toolCallId": "call_null", "status": "completed",
            "title": None, "content": None, "rawOutput": None, "kind": None})
    update({"sessionUpdate": "session_info_update", "title": None, "updatedAt": None, "_meta": None})
    update({"sessionUpdate": "agent_message_chunk", "messageId": "m_null",
            "content": {"type": "text", "text": "after nulls", "annotations": None}, "_meta": None})
    report(msg_id, {"ok": True})
    return finish(msg_id)


def scenario_cancel_request(msg_id):
    update({"sessionUpdate": "tool_call", "toolCallId": "call_withdrawn", "title": "Write a.txt",
            "kind": "edit", "status": "pending"})

    def withdraw(req_id):
        time.sleep(0.2)
        notify("$/cancel_request", {"id": req_id})

    req, response = request_client("session/request_permission", {
        "sessionId": SESSION_ID,
        "toolCall": {"toolCallId": "call_withdrawn", "title": "Write a.txt", "kind": "edit"},
        "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"}],
    }, timeout=1, before_wait=withdraw)
    update({"sessionUpdate": "tool_call_update", "toolCallId": "call_withdrawn", "status": "failed"})
    report(msg_id, {"request_id": req, "first_response": response_body(response)})
    return finish(msg_id)


def response_body(msg):
    if msg is None:
        return None
    if "error" in msg:
        return {"error": (msg["error"] or {}).get("code")}
    return msg.get("result")


SCENARIOS = {
    "@ask": scenario_ask,
    "@plan-approve": scenario_plan_approve,
    "@bash": scenario_bash,
    "@null": scenario_null,
    "@cancel-request": scenario_cancel_request,
}
SESSION_CWD_REF = [None]


def run_prompt(msg_id, text):
    """Runs in a worker thread so stdin stays responsive."""
    for trigger, fn in SCENARIOS.items():
        if text.startswith(trigger):
            fn(msg_id)
            return
    # Inline editing: the prompt names a private copy. Make one deterministic
    # change. Exercise real permission RPCs, rather than bypassing the policy
    # as the original inline mock did.
    if text.startswith("INLINE_BUFFER_EDIT:"):
        import re

        # The scope instruction depends on how the request was opened. Visual
        # mode gets a byte range; normal mode must not be described as an
        # insert-only point.
        if "INLINE_NORMAL" in text and "INSERT ONLY" in text:
            error(msg_id, -32000, "normal-mode inline was described as insert-only")
            with permissions_lock:
                active_prompts.pop(msg_id, None)
            return
        if "INLINE_VISUAL" in text and "Rewrite only" not in text:
            error(msg_id, -32000, "visual inline lost its range instruction")
            with permissions_lock:
                active_prompts.pop(msg_id, None)
            return

        match = re.search(r"`([^`]*acp-inline-[^`]*)`", text)
        if match and os.path.isfile(match.group(1)):
            path = match.group(1)
            choices = []
            for kind, target in [("read", path), ("edit", path), ("edit", path + ".other")]:
                pending = PendingPermission(msg_id)
                with permissions_lock:
                    permissions[9001] = pending
                send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission", "params": {
                    "sessionId": SESSION_ID,
                    "toolCall": {"toolCallId": "inline_permission", "kind": kind, "locations": [{"path": target}]},
                    "options": [{"kind": "allow_once", "optionId": "allow"}, {"kind": "reject_once", "optionId": "reject"}],
                }})
                pending.event.wait(timeout=5)
                choices.append(pending.option)
                with permissions_lock:
                    permissions.pop(9001, None)
            if choices != ["allow", "allow", "reject"]:
                error(msg_id, -32000, "inline permission policy failed: " + repr(choices))
                with permissions_lock:
                    active_prompts.pop(msg_id, None)
                return
            if "INLINE_SLOW" in text:
                for _ in range(300):
                    if cancel_event.is_set():
                        finish(msg_id, "cancelled")
                        return
                    time.sleep(0.01)
            if "INLINE_DELAY" in text:
                time.sleep(0.2)
            with open(path, "r", encoding="utf-8") as handle:
                content = handle.read()
            if "INLINE_OLD" in content:
                content = content.replace("INLINE_OLD", "INLINE_NEW", 1)
                if "INLINE_OUTSIDE" in text:
                    # Appending keeps the selected line's edit intact, so a
                    # visual range can be checked to drop only this line.
                    content = content.rstrip("\n") + "\nOUTSIDE\n"
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
                update(
                    {
                        "sessionUpdate": "agent_message_chunk",
                        "messageId": "inline",
                        "content": {"type": "text", "text": "edited"},
                    }
                )
                finish(msg_id)
                return
        update(
            {
                "sessionUpdate": "agent_message_chunk",
                "messageId": "inline",
                "content": {"type": "text", "text": "nothing to change"},
            }
        )
        finish(msg_id)
        return
    if text.startswith("ORDER_PROBE"):
        update({"sessionUpdate": "agent_message_chunk", "messageId": "order_probe", "content": {"type": "text", "text": text}})
        finish(msg_id)
        return
    if "fail" in text:
        error(msg_id, -32000, "mock failure")
        with permissions_lock:
            active_prompts.pop(msg_id, None)
        return

    if "permission" in text:
        update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call_perm",
            "title": "Write src/main.lua",
            "kind": "edit",
            "status": "pending",
        })
        pending = PendingPermission(msg_id)
        with permissions_lock:
            permissions[9001] = pending
        send({
            "jsonrpc": "2.0",
            "id": 9001,
            "method": "session/request_permission",
            "params": {
                "sessionId": SESSION_ID,
                "toolCall": {"toolCallId": "call_perm", "title": "Write src/main.lua"},
                "options": [
                    {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                ],
            },
        })
        got = pending.event.wait(timeout=10)
        with permissions_lock:
            permissions.pop(9001, None)
        if not got or pending.option is None:
            update({"sessionUpdate": "tool_call_update", "toolCallId": "call_perm", "status": "cancelled"})
            finish(msg_id, "cancelled")
            return
        update({"sessionUpdate": "tool_call_update", "toolCallId": "call_perm", "status": "completed"})
        update({"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": "done"}})
        finish(msg_id)
        return

    if "slow" in text:
        update({"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": "working"}})
        for _ in range(500):
            if cancel_event.is_set():
                finish(msg_id, "cancelled")
                return
            time.sleep(0.01)
        finish(msg_id)
        return

    if "toolfail" in text:
        update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call_fail",
            "title": "Run tests",
            "kind": "execute",
            "status": "in_progress",
        })
        update({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "call_fail",
            "status": "failed",
            "rawOutput": "exit code 1",
        })
        finish(msg_id)
        return

    if "subagent" in text:
        child = {"title": "Explore the repo", "sessionId": "child_1"}
        update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call_child",
            "title": "Read src/main.lua",
            "kind": "read",
            "status": "pending",
            "_meta": {"opencode/child-session": child},
        })
        update({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "call_child",
            "status": "completed",
            "_meta": {"opencode/child-session": child},
        })
        # Text produced by the delegated turn, tagged so the client can label it.
        update({
            "sessionUpdate": "agent_message_chunk",
            "messageId": "m_child",
            "content": {"type": "text", "text": "The helper found two call sites."},
            "_meta": {"opencode/child-session": child},
        })
        # Updates for the child session itself must never reach the transcript.
        notify("session/update", {
            "sessionId": "child_1",
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "messageId": "c1",
                "content": {"type": "text", "text": "CHILD-INTERNAL-ONLY"},
            },
        })
        finish(msg_id)
        return

    update({
        "sessionUpdate": "plan",
        "entries": [
            {"content": "Read the file", "priority": "high", "status": "completed"},
            {"content": "Apply the change", "priority": "medium", "status": "in_progress"},
        ],
    })
    update({"sessionUpdate": "user_message_chunk", "messageId": "u1", "content": {"type": "text", "text": text}})
    for chunk in ["Hello", " from ", "the mock agent."]:
        update({"sessionUpdate": "agent_message_chunk", "messageId": "m2", "content": {"type": "text", "text": chunk}})
        time.sleep(0.01)
    update({
        "sessionUpdate": "usage_update",
        "used": 1200,
        "size": 200000,
        "cost": {"amount": 0.01, "currency": "USD"},
    })
    # Mimic auto-titling: the title only shows up in session/list.
    entry = SESSIONS.get(SESSION_ID)
    if entry is not None and not entry["title"]:
        entry["title"] = "Mock titled session"
    finish(msg_id)


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    params = msg.get("params") or {}

    log_incoming(msg)
    if method is None:
        with permissions_lock:
            slot = client_requests.get(msg_id)
        if slot is not None:
            if slot.option is None:
                slot.option = msg
            slot.event.set()
            return
        # Response to our permission request.
        if msg_id in (9001,) and "result" in msg:
            outcome = (msg["result"] or {}).get("outcome") or {}
            with permissions_lock:
                pending = permissions.get(9001)
            if pending:
                if outcome.get("outcome") == "selected":
                    pending.option = outcome.get("optionId")
                pending.event.set()
        return

    if method == "initialize":
        CLIENT_CAPS.clear()
        CLIENT_CAPS.update(params.get("clientCapabilities") or {})
        result(msg_id, initialize_result())
    elif method == "authenticate":
        authenticated[0] = True
        result(msg_id, {})
    elif method == "session/new":
        if os.environ.get("ACP_MOCK_AUTH_REQUIRED") == "1" and not logged_in():
            send({"jsonrpc": "2.0", "id": msg_id, "error": {
                "code": -32000, "message": "Authentication required",
                "data": {"authMethods": auth_methods()}}})
            return
        SESSION_CWD = params.get("cwd")
        SESSION_CWD_REF[0] = SESSION_CWD
        SESSIONS[SESSION_ID]["cwd"] = SESSION_CWD
        # Sessions created without an explicit directory belong to the session
        # directory, so cwd filtering behaves like a real agent.
        for info in SESSIONS.values():
            if info.get("cwd") is None:
                info["cwd"] = SESSION_CWD
        if os.environ.get("ACP_MOCK_EARLY_UPDATE") == "1":
            # Real agents may stream updates for a session before the client
            # has seen the session/new response.
            update({"sessionUpdate": "available_commands_update", "availableCommands": [
                {"name": "early", "description": "Sent before session/new returned"}]})
        result(msg_id, new_session_result())
    elif method == "session/load":
        # Like OpenCode, refuse to load a session under a different directory.
        session_id = params.get("sessionId")
        load_cwd = params.get("cwd")
        entry = SESSIONS.get(session_id)
        if entry is not None and entry.get("cwd") and load_cwd and entry["cwd"] != load_cwd:
            error(msg_id, -32602, "session cwd mismatch")
            return
        update({"sessionUpdate": "user_message_chunk", "messageId": "u0", "content": {"type": "text", "text": "old question"}})
        update({"sessionUpdate": "agent_message_chunk", "messageId": "m0", "content": {"type": "text", "text": "old answer"}})
        # Titles and plan entries may contain newlines.
        update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call_nl",
            "title": "Read\nconfig.json",
            "kind": "read",
            "status": "completed",
        })
        update({
            "sessionUpdate": "plan",
            "entries": [{"content": "step one\nstep two", "priority": "high", "status": "pending"}],
        })
        result(msg_id, {})
    elif method == "session/list":
        # Like OpenCode, filter strictly by cwd when one is supplied, and treat
        # an omitted cwd as "every session".
        cwd = params.get("cwd")
        listed = []
        for info in SESSIONS.values():
            if cwd and info.get("cwd") and info["cwd"] != cwd:
                continue
            item = dict(info)
            item["cwd"] = cwd or item.get("cwd")
            listed.append(item)
        # ACP_EMPTY_SCOPE_DIR switches the mock into "no sessions in this
        # directory" mode, so the client has to fall back to an unscoped list.
        empty_scope = os.environ.get("ACP_EMPTY_SCOPE_DIR")
        if cwd and empty_scope and cwd == empty_scope:
            listed = []
        result(msg_id, {"sessions": listed})
    elif method == "session/delete":
        SESSIONS.pop(params.get("sessionId"), None)
        result(msg_id, {})
    elif method == "session/prompt":
        text = "".join(b.get("text", "") for b in params.get("prompt") or [] if b.get("type") == "text")
        order = None
        if text.startswith("ORDER_PROBE"):
            order = [
                "text:" + block.get("text", "") if block.get("type") == "text"
                else "image:" + block.get("data", "") if block.get("type") == "image"
                else block.get("type", "unknown")
                for block in params.get("prompt") or []
            ]
        # Echo image blocks back so a test can prove the real payload arrived
        # with a decodable body, not just that a chip was shown locally.
        for block in params.get("prompt") or []:
            if block.get("type") == "image":
                summary = "IMAGE:%s:%d" % (block.get("mimeType"), len(block.get("data") or ""))
                image_blocks.append(summary)
                text = text + " " + summary
        if order is not None:
            text += "\nORDER:" + json.dumps(order, ensure_ascii=False, separators=(",", ":"))
        with permissions_lock:
            # OpenCode refuses a second prompt while one is running. Mirroring
            # that here turns the client-side race into a test failure instead
            # of silently letting two turns overlap.
            if active_prompts:
                error(msg_id, -32000, "Internal error: Session already has an active ACP prompt: " + SESSION_ID)
                return
            active_prompts[msg_id] = True
        cancel_event.clear()
        threading.Thread(target=run_prompt, args=(msg_id, text), daemon=True).start()
    elif method == "session/cancel":
        cancel_event.set()
        with permissions_lock:
            pending = permissions.get(9001)
        if pending and not pending.event.is_set():
            pending.event.set()
    elif method == "$/cancel_request":
        target = params.get("id")
        if target in active_prompts:
            cancel_event.set()
            with permissions_lock:
                active_prompts.pop(target, None)
            result(target, {"stopReason": "cancelled"})
    elif method == "session/set_config_option":
        result(msg_id, {"configOptions": [
            {
                "id": params.get("configId"),
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": params.get("value"),
                "options": [{"value": params.get("value"), "name": str(params.get("value"))}],
            }
        ]})
    elif method == "session/set_mode":
        if PROFILE in current_mode:
            current_mode[PROFILE] = params.get("modeId")
        result(msg_id, {})
        update({"sessionUpdate": "current_mode_update", "currentModeId": params.get("modeId")})
    elif msg_id is not None:
        error(msg_id, -32601, "Method not found: " + str(method))


def main():
    if "--mock-login" in sys.argv:
        # Terminal login: the client runs this in a terminal.
        if AUTH_MARKER:
            with open(AUTH_MARKER, "w", encoding="utf-8") as marker:
                marker.write("ok")
        print("logged in")
        sys.exit(0)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        try:
            handle(msg)
        except Exception as exc:  # noqa: BLE001
            if isinstance(msg, dict) and msg.get("id") is not None:
                error(msg["id"], -32603, "mock internal error: %s" % exc)
    sys.exit(0)


if __name__ == "__main__":
    main()
