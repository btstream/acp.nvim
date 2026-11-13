-- Protocol conformance against the agent profiles of tests/mock_agent.py.
--
-- Each profile reproduces the protocol shapes of a real agent (OpenCode,
-- claude-agent-acp, pi-acp, and a minimal generic agent). Tests marked
-- `pending` describe behaviour that docs/compat-plan.md has not delivered yet;
-- they turn into normal tests when the phase named in the reason lands.
return function(t)
  local client_mod = require("acp.protocol.client")
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")
  local async = require("acp.async")
  local config = require("acp.config")
  local connection = require("acp.app.connection")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local mock = root .. "tests/mock_agent.py"
  local has_python = vim.fn.executable("python3") == 1
  local PROFILES = { "opencode", "claude", "pi", "generic" }

  local function wait_for(cond, timeout, label)
    if not vim.wait(timeout or 5000, cond, 20) then
      error("timed out waiting for " .. (label or "condition"), 2)
    end
  end

  ---The capabilities the plugin really advertises with its default config.
  local function advertised()
    return connection.client_capabilities(config.merge(config.defaults, {}))
  end

  ---Start a client for one profile.
  ---@param profile string
  ---@param opts? {caps?: table, env?: table<string,string>}
  ---@return table client, table ctx
  local function start(profile, opts)
    opts = opts or {}
    local ctx = { events = {}, errors = {}, log = vim.fn.tempname() }
    local env = vim.tbl_extend("force", { ACP_MOCK_PROFILE = profile, ACP_MOCK_LOG = ctx.log }, opts.env or {})
    local client = client_mod.new({
      agent = { command = "python3", args = { mock }, env = env },
      cwd = root,
      client_capabilities = opts.caps or advertised(),
      on_event = function(name, payload)
        ctx.events[#ctx.events + 1] = { name = name, payload = payload }
        if name == "connection_error" then
          ctx.errors[#ctx.errors + 1] = payload
        end
        if ctx.on_event then
          ctx.on_event(name, payload)
        end
      end,
    })
    local ready
    client:start(function(ok, err)
      ready = { ok = ok, err = err }
    end)
    wait_for(function()
      return ready ~= nil
    end, 8000, profile .. " start")
    assert(ready.ok, "failed to start " .. profile .. ": " .. vim.inspect(ready.err))
    return client, ctx
  end

  ---Run `fn` in a coroutine and wait for it.
  local function run(fn, timeout)
    local out
    async.run(function()
      out = { fn() }
    end)
    wait_for(function()
      return out ~= nil
    end, timeout or 8000, "async call")
    return unpack(out)
  end

  ---Create a session, then prompt it while reducing every update into a local
  ---session state. Reducer errors are collected instead of raised.
  local function prompt(client, ctx, text)
    local ok, created = run(function()
      return client:new_session(root)
    end)
    assert(ok, "session/new failed: " .. vim.inspect(created))
    local session = state.new(created.sessionId, root)
    session:configure(created)
    ctx.reduce_errors = {}
    ctx.on_event = function(name, payload)
      if name == "session_update" and payload.sessionId == session.id then
        local applied, err = pcall(reducer.apply, session, payload.update)
        if not applied then
          ctx.reduce_errors[#ctx.reduce_errors + 1] = err
        end
      end
    end
    local prompted, response = run(function()
      session:begin_turn()
      local a, b = client:prompt(session.id, { { type = "text", text = text } })
      session:finish_turn(a and b and b.stopReason or "error")
      return a, b
    end)
    return session, prompted, response, created
  end

  ---Messages the mock received from the client.
  local function received(ctx)
    local out = {}
    if vim.fn.filereadable(ctx.log) == 1 then
      for _, line in ipairs(vim.fn.readfile(ctx.log)) do
        out[#out + 1] = vim.json.decode(line)
      end
    end
    return out
  end

  ---The RESULT:<json> report a scenario ends with.
  local function scenario_result(session)
    for i = #session.blocks, 1, -1 do
      local text = session.blocks[i].kind == "agent" and state.block_text(session.blocks[i]) or ""
      local json = text:match("RESULT:(%b{})")
      if json then
        return vim.json.decode(json)
      end
    end
  end

  t.describe("protocol conformance", function()
    if not has_python then
      return
    end

    for _, profile in ipairs(PROFILES) do
      t.it(profile .. ": initialize, session/new, prompt and cancel", function()
        local client, ctx = start(profile)
        t.truthy(client:is_ready())
        local session, ok, response = prompt(client, ctx, "hello")
        t.truthy(ok, vim.inspect(response))
        t.eq("end_turn", response.stopReason)
        t.eq({}, ctx.reduce_errors)
        local text = ""
        for _, block in ipairs(session.blocks) do
          if block.kind == "agent" then
            text = text .. state.block_text(block)
          end
        end
        t.match("Hello from the mock agent", text)
        client:cancel(session.id)
        t.eq({}, ctx.errors)
        -- Nothing the client sent was malformed enough for the agent to reject.
        for _, msg in ipairs(received(ctx)) do
          t.falsy(msg.error, "client sent an error response: " .. vim.inspect(msg))
        end
        client:shutdown(true)
      end)
    end

    t.it("loads a session on agents that support it", function()
      for _, profile in ipairs({ "opencode", "claude", "pi" }) do
        local client = start(profile)
        t.truthy(client:agent_capabilities().loadSession, profile)
        local ok, value = run(function()
          return client:load_session("sess_old", root)
        end)
        t.truthy(ok, profile .. ": " .. vim.inspect(value))
        client:shutdown(true)
      end
      local generic = start("generic")
      t.falsy(generic:agent_capabilities().loadSession)
      generic:shutdown(true)
    end)

    -- Client capabilities -----------------------------------------------------

    t.pending("advertises form elicitation", "phase 3: elicitation", function()
      local caps = advertised()
      t.truthy(caps.elicitation and caps.elicitation.form, vim.inspect(caps))
    end)

    t.pending("advertises terminal authentication", "phase 4: auth", function()
      local caps = advertised()
      t.truthy(caps.auth and caps.auth.terminal, vim.inspect(caps))
      t.truthy(caps._meta and caps._meta["terminal-auth"], vim.inspect(caps))
    end)

    t.pending("advertises terminal output metadata", "phase 6: terminal output", function()
      local caps = advertised()
      t.truthy(caps._meta and caps._meta.terminal_output, vim.inspect(caps))
    end)

    -- Questions ---------------------------------------------------------------

    t.it("claude asks in plain text when form elicitation is not advertised", function()
      local client, ctx = start("claude", { caps = vim.empty_dict() })
      local session = prompt(client, ctx, "@ask")
      t.eq({ elicitation = "unsupported" }, scenario_result(session))
      client:shutdown(true)
    end)

    t.pending("answers elicitation/create instead of rejecting it", "phase 3: elicitation", function()
      for _, profile in ipairs({ "claude", "opencode" }) do
        local client, ctx = start(profile, { caps = { elicitation = { form = vim.empty_dict() } } })
        local session = prompt(client, ctx, "@ask")
        local result = scenario_result(session) or {}
        -- Without a user, the request must still be settled with a valid
        -- action (cancel on shutdown/turn end), never "method not found".
        t.truthy(type(result.elicitation) == "table" and result.elicitation.action, vim.inspect(result))
        client:shutdown(true)
      end
    end)

    t.it("pi questions arrive as a select permission request", function()
      local client, ctx = start("pi")
      local seen
      local session
      local done = false
      async.run(function()
        local ok, created = client:new_session(root)
        assert(ok)
        session = state.new(created.sessionId, root)
        ctx.on_event = function(name, payload)
          if name == "session_update" then
            reducer.apply(session, payload.update)
          elseif name == "permission_request" then
            seen = payload
            client:resolve_permission(payload.key, "choice-1")
          end
        end
        client:prompt(session.id, { { type = "text", text = "@ask" } })
        done = true
      end)
      wait_for(function()
        return done
      end, 8000, "pi @ask")
      t.eq("select", seen.tool_call.rawInput.method)
      -- Every choice shares one kind: kind alone cannot tell a question from a
      -- tool approval, which is why auto_allow must not answer it.
      t.eq({ "allow_once", "allow_once" }, { seen.options[1].kind, seen.options[2].kind })
      t.eq({ permission = { outcome = { outcome = "selected", optionId = "choice-1" } } }, scenario_result(session))
      client:shutdown(true)
    end)

    -- Robustness --------------------------------------------------------------

    t.it("reduces updates carrying JSON null", function()
      local client, ctx = start("opencode")
      local session = prompt(client, ctx, "@null")
      t.eq({}, ctx.reduce_errors)
      local tool
      for _, block in ipairs(session.blocks) do
        if block.kind == "tool" then
          tool = block
        end
      end
      t.truthy(tool, "tool block missing")
      -- A null title in an update does not erase the title from tool_call.
      t.eq("Null fields", tool.title)
      for key, value in pairs(tool) do
        t.truthy(value ~= vim.NIL, "tool." .. key .. " is vim.NIL")
      end
      t.truthy(session.title ~= vim.NIL, "session.title is vim.NIL")
      client:shutdown(true)
    end)

    t.it("answers a withdrawn permission request at most once", function()
      local client, ctx = start("opencode")
      local key
      local session = prompt(client, ctx, "@cancel-request")
      for _, event in ipairs(ctx.events) do
        if event.name == "permission_request" then
          key = event.payload.key
        end
      end
      t.truthy(key, "permission request not seen")
      local result = scenario_result(session)
      -- The user answers after the agent withdrew the request.
      client:resolve_permission(key, "allow")
      vim.wait(300)
      local replies = 0
      for _, msg in ipairs(received(ctx)) do
        if msg.id == result.request_id and msg.method == nil then
          replies = replies + 1
        end
      end
      t.eq(1, replies)
      client:shutdown(true)
    end)

    -- Modes and terminal output -----------------------------------------------

    t.pending("reads the current legacy mode", "phase 5: controls", function()
      local client, ctx = start("claude")
      local _, _, _, created = prompt(client, ctx, "hello")
      local session = state.new(created.sessionId, root)
      session:configure(created)
      t.eq("default", session.current_mode)
      client:shutdown(true)
    end)

    t.it("claude plan approval carries the plan and its options in order", function()
      local client, ctx = start("claude")
      local seen
      local done = false
      async.run(function()
        local ok, created = client:new_session(root)
        assert(ok)
        ctx.on_event = function(name, payload)
          if name == "permission_request" then
            seen = payload
            client:resolve_permission(payload.key, "exit-plan-default")
          end
        end
        client:prompt(created.sessionId, { { type = "text", text = "@plan-approve" } })
        done = true
      end)
      wait_for(function()
        return done
      end, 8000, "claude @plan-approve")
      t.eq("switch_mode", seen.tool_call.kind)
      t.eq("# Plan\n1. Do it", seen.tool_call.content[1].content.text)
      local ids = {}
      for _, option in ipairs(seen.options) do
        ids[#ids + 1] = option.optionId
      end
      t.eq({ "exit-plan-default", "exit-plan-clear-auto", "exit-plan-auto", "exit-plan-bypass", "reject" }, ids)
      client:shutdown(true)
    end)

    t.pending("shows pi shell output that only travels in _meta", "phase 6: terminal output", function()
      local client, ctx = start("pi")
      local session = prompt(client, ctx, "@bash")
      local tool
      for _, block in ipairs(session.blocks) do
        if block.kind == "tool" then
          tool = block
        end
      end
      t.truthy(tool, "tool block missing")
      t.truthy(vim.inspect(tool):find("a.ts", 1, true), "terminal output was dropped")
      client:shutdown(true)
    end)
  end)
end
