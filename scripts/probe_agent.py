#!/usr/bin/env python3
"""Probe a real ACP agent and report the facts the compatibility plan asks for.

Talks JSON-RPC over stdio with no editor involved, so the output is the agent's
own answer rather than the plugin's interpretation of it. Creates one session and
sends no prompt unless asked, so it does not consume model credits by default.

    python3 scripts/probe_agent.py -- claude-agent-acp
    python3 scripts/probe_agent.py -- npx -y @geohar/pi-acp
    python3 scripts/probe_agent.py --prompt "@plan-approve" -- opencode acp

Answers the three "未核实" items in docs/compat-plan.md §5:
  1. does the agent send plan-mode / plan updates?
  2. what is ExitPlanMode's toolCall.kind?
  3. is there a login method, and what type is it?

Exits non-zero when the handshake fails, so it doubles as a smoke test.
"""

import argparse
import json
import os
import subprocess
import sys
import threading

CLIENT_CAPABILITIES = {
    "elicitation": {"form": {}},
    "auth": {"terminal": True},
    "_meta": {"terminal-auth": True, "terminal_output": True},
    "session": {"configOptions": {"boolean": {}}},
}


class Agent:
    def __init__(self, argv, cwd=None, raw=False):
        self.raw = raw
        self.seq = 0
        self.pending = {}
        self.messages = []
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            text=True,
            bufsize=1,
        )
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                print(f"[non-json] {line[:200]}", file=sys.stderr)
                continue
            with self.lock:
                self.messages.append(msg)
            if self.raw:
                print("[<]", json.dumps(msg, ensure_ascii=False)[:400])
            if "id" in msg and ("result" in msg or "error" in msg):
                event = self.pending.get(msg["id"])
                if isinstance(event, threading.Event):
                    self.pending[msg["id"]] = msg
                    event.set()

    def call(self, method, params, timeout=180):
        self.seq += 1
        msg_id = self.seq
        event = threading.Event()
        self.pending[msg_id] = event
        payload = {"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params}
        if self.raw:
            print("[>]", json.dumps(payload, ensure_ascii=False)[:400])
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        if not event.wait(timeout):
            raise TimeoutError(f"no response to {method}")
        result = self.pending[msg_id]
        if "error" in result:
            raise RuntimeError(f"{method} failed: {json.dumps(result['error'])}")
        return result.get("result")

    def reply(self, msg_id, result):
        payload = {"jsonrpc": "2.0", "id": msg_id, "result": result}
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def notifications(self):
        return [m for m in self.messages if "method" in m and "id" not in m]

    def requests(self, method):
        return [m for m in self.messages if m.get("method") == method and "id" in m]

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def summarize_initialize(caps):
    agent = caps.get("agentCapabilities") or {}
    info = caps.get("agentInfo") or {}
    out = [
        f"  protocolVersion: {caps.get('protocolVersion')}",
        f"  agent: {info.get('name')} {info.get('version') or ''}".rstrip(),
        f"  loadSession: {agent.get('loadSession')}",
    ]
    prompt = agent.get("promptCapabilities") or {}
    keys = ("image", "audio", "embeddedContext")
    out.append(
        "  promptCapabilities: "
        + json.dumps({k: prompt.get(k) for k in keys if prompt.get(k) is not None}, ensure_ascii=False)
    )
    mcp = agent.get("mcpCapabilities") or {}
    if mcp:
        out.append(f"  mcpCapabilities: {json.dumps(mcp, ensure_ascii=False)}")
    sessions = agent.get("sessionCapabilities") or {}
    if sessions:
        out.append(f"  sessionCapabilities: {sorted(sessions.keys())}")
    methods = caps.get("authMethods") or []
    if methods:
        for method in methods:
            meta = method.get("_meta") or {}
            kind = method.get("type") or ("terminal" if "terminal-auth" in meta else "agent")
            out.append(f"  authMethod: id={method.get('id')} type={kind} name={method.get('name')}")
    else:
        out.append("  authMethods: [] (the agent expects credentials from the environment)")
    return "\n".join(out)


def summarize_session(result):
    out = [f"  sessionId: {result.get('sessionId')}"]
    modes = result.get("modes")
    if isinstance(modes, dict):
        available = modes.get("availableModes") or []
        out.append(f"  modes: current={modes.get('currentModeId')} available={[m.get('id') for m in available]}")
        kinds = {
            m.get("id"): (m.get("_meta") or {}).get("kind")
            for m in available
            if (m.get("_meta") or {}).get("kind")
        }
        if kinds:
            out.append(f"  modes._meta.kind: {json.dumps(kinds, ensure_ascii=False)}")
    options = result.get("configOptions")
    if isinstance(options, list):
        for option in options:
            values = [o.get("value") for o in option.get("options") or []]
            out.append(
                f"  configOption: id={option.get('id')} category={option.get('category')} "
                f"type={option.get('type')} current={option.get('currentValue')} values={values}"
            )
        categories = [o.get("category") for o in options]
        if modes and "mode" not in categories:
            out.append("  -> modes duplicates a non-mode category (the pi shape)")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("argv", nargs=argparse.REMAINDER, help="agent command, after --")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--prompt", default=None)
    parser.add_argument("--raw", action="store_true")
    args = parser.parse_args()

    argv = args.argv
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        parser.error("give the agent command after --, e.g. `-- claude-agent-acp`")

    agent = Agent(argv, cwd=args.cwd, raw=args.raw)
    try:
        caps = agent.call(
            "initialize",
            {
                "protocolVersion": 1,
                "clientCapabilities": CLIENT_CAPABILITIES,
                "clientInfo": {"name": "acp.nvim-probe", "version": "0"},
            },
        )
        print("== initialize ==")
        print(summarize_initialize(caps))

        session = agent.call("session/new", {"cwd": args.cwd, "mcpServers": []})
        print("\n== session/new ==")
        print(summarize_session(session))

        if args.prompt:
            try:
                agent.call(
                    "session/prompt",
                    {
                        "sessionId": session.get("sessionId"),
                        "prompt": [{"type": "text", "text": args.prompt}],
                    },
                    timeout=300,
                )
            except Exception as err:  # the updates arrived regardless
                print(f"\n  (prompt finished with: {err})")

            kinds = {}
            tools = []
            for message in agent.notifications():
                if message.get("method") != "session/update":
                    continue
                params = message.get("params") or {}
                update = params.get("update") or params
                if isinstance(update.get("update"), dict) and "sessionUpdate" not in update:
                    update = update["update"]
                kind = update.get("sessionUpdate")
                kinds[kind] = kinds.get(kind, 0) + 1
                if kind == "tool_call":
                    tools.append(update)

            print("\n== session/update kinds ==")
            for kind, count in sorted(kinds.items()):
                print(f"  {kind}: {count}")
            if tools:
                print("\n== tool calls ==")
                for tool in tools:
                    print(
                        f"    name={tool.get('name')} kind={tool.get('kind')} title={tool.get('title')!r}"
                    )
            if "plan" in kinds:
                print("\n  -> the agent DOES send plan updates")
            else:
                print("\n  -> no plan update in this run (a plan-mode prompt may be needed)")

        requests = agent.requests("session/request_permission")
        print("\n== permission requests ==")
        if not requests:
            print("  none")
        for request in requests:
            params = request.get("params") or {}
            tool = params.get("toolCall") or {}
            options = [(o.get("kind"), o.get("name")) for o in params.get("options") or []]
            print(f"  toolCall.name={tool.get('name')} kind={tool.get('kind')}")
            print(f"    options: {options}")
            # Answer so the agent is not left waiting.
            agent.reply(request["id"], {"outcome": {"outcome": "cancelled"}})
    finally:
        agent.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"probe failed: {err}", file=sys.stderr)
        sys.exit(1)
