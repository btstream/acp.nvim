#!/usr/bin/env python3
"""Minimal ACP agent used by acp.nvim's test suite.

Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout. Behavior is driven by
the prompt text so tests can request specific flows:

  contains "hello"      -> one streamed text message
  contains "permission" -> tool call + session/request_permission
  contains "slow"       -> streams, then waits for session/cancel
  contains "fail"       -> returns a JSON-RPC error
  contains "toolfail"   -> tool call that completes with failed status
"""
import json
import sys
import threading
import time

SESSION_ID = "sess_mock"
SESSIONS = {
    SESSION_ID: {"sessionId": SESSION_ID, "title": None, "updatedAt": "2026-01-01T00:00:00Z"},
    "sess_old": {"sessionId": "sess_old", "title": "Old conversation", "updatedAt": "2026-01-01T00:00:00Z"},
}
write_lock = threading.Lock()
cancel_event = threading.Event()
# Active prompt requests: msg_id -> True
active_prompts = {}


class PendingPermission:
    def __init__(self, msg_id):
        self.msg_id = msg_id
        self.event = threading.Event()
        self.option = None


permissions = {}
permissions_lock = threading.Lock()


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


def run_prompt(msg_id, text):
    """Runs in a worker thread so stdin stays responsive."""
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

    if method is None:
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
        result(msg_id, {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": True,
                "promptCapabilities": {"embeddedContext": True, "image": False},
                "sessionCapabilities": {"list": {}, "resume": {}, "delete": {}, "close": {}},
            },
            "agentInfo": {"name": "mock", "title": "Mock Agent", "version": "0.1.0"},
            "authMethods": [],
        })
    elif method == "authenticate":
        result(msg_id, {})
    elif method == "session/new":
        result(msg_id, {
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
        })
    elif method == "session/load":
        update({"sessionUpdate": "user_message_chunk", "messageId": "u0", "content": {"type": "text", "text": "old question"}})
        update({"sessionUpdate": "agent_message_chunk", "messageId": "m0", "content": {"type": "text", "text": "old answer"}})
        result(msg_id, {})
    elif method == "session/list":
        cwd = params.get("cwd")
        listed = []
        for info in SESSIONS.values():
            item = dict(info)
            item["cwd"] = cwd
            listed.append(item)
        result(msg_id, {"sessions": listed})
    elif method == "session/delete":
        SESSIONS.pop(params.get("sessionId"), None)
        result(msg_id, {})
    elif method == "session/prompt":
        text = "".join(b.get("text", "") for b in params.get("prompt") or [] if b.get("type") == "text")
        with permissions_lock:
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
        result(msg_id, {})
    elif msg_id is not None:
        error(msg_id, -32601, "Method not found: " + str(method))


def main():
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
