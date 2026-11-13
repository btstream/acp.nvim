return function(t)
  local client_mod = require("acp.protocol.client")
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")
  local async = require("acp.async")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local mock = root .. "tests/mock_agent.py"
  local has_python = vim.fn.executable("python3") == 1

  local function wait_for(cond, timeout)
    local ok = vim.wait(timeout or 5000, cond, 20)
    if not ok then
      error("timed out waiting for condition", 2)
    end
  end

  local function new_client(events)
    return client_mod.new({
      agent = { command = "python3", args = { mock } },
      cwd = root,
      client_capabilities = {},
      on_event = function(name, payload)
        events[#events + 1] = { name = name, payload = payload }
      end,
    })
  end

  local function start_client(events)
    local client = new_client(events)
    local ready
    client:start(function(ok, err)
      ready = { ok = ok, err = err }
    end)
    wait_for(function()
      return ready ~= nil
    end)
    if not ready.ok then
      error("failed to start mock agent: " .. vim.inspect(ready.err))
    end
    return client
  end

  t.describe("client", function()
    t.it("routes only registered agent requests through the registry", function()
      local sent = {}
      local client = new_client({})
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function(payload)
          sent[#sent + 1] = vim.json.decode(payload)
          return true
        end,
      })
      client:on_agent_request("custom/ask", function(_, respond)
        respond({ ok = true })
      end)
      client.rpc:handle({ jsonrpc = "2.0", id = 1, method = "custom/ask", params = {} })
      client.rpc:handle({ jsonrpc = "2.0", id = 2, method = "custom/unknown", params = {} })
      t.eq({ ok = true }, sent[1].result)
      t.eq(-32601, sent[2].error.code)
      client:on_agent_notification("custom/event", function(params)
        client.seen = params
      end)
      client.rpc:handle({ jsonrpc = "2.0", method = "custom/event", params = { n = 1 } })
      t.eq(1, client.seen.n)
    end)

    t.it("initializes against the mock agent", function()
      if not has_python then
        return
      end
      local client = start_client({})
      t.truthy(client:is_ready())
      t.eq("mock", client.agent_info.name)
      client:shutdown(true)
    end)

    t.it("creates a session with config options", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local result
      async.run(function()
        local ok, value = client:new_session(root)
        result = { ok = ok, value = value }
      end)
      wait_for(function()
        return result ~= nil
      end)
      t.truthy(result.ok)
      t.eq("sess_mock", result.value.sessionId)
      t.eq("model", result.value.configOptions[1].id)
      client:shutdown(true)
    end)

    t.it("streams a prompt into session state", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local session = state.new("sess_mock", root)
      client.on_event = function(name, payload)
        if name == "session_update" then
          reducer.apply(session, payload.update)
        end
      end
      local done = false
      async.run(function()
        session:begin_turn()
        session:add_local_user("hello")
        client:prompt(session.id, { { type = "text", text = "hello" } })
        session:finish_turn("end_turn")
        done = true
      end)
      wait_for(function()
        return done
      end, 8000)

      local text = ""
      local user_blocks = 0
      for _, block in ipairs(session.blocks) do
        if block.kind == "agent" then
          text = text .. block.text
        end
        if block.kind == "user" then
          user_blocks = user_blocks + 1
        end
      end
      t.match("Hello from the mock agent", text)
      t.eq(1, user_blocks)
      t.eq(1200, session.usage.used)
      client:shutdown(true)
    end)

    t.it("requests and resolves permission", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local event
      client.on_event = function(name, payload)
        if name == "permission_request" then
          event = payload
        end
      end
      local done = false
      async.run(function()
        client:prompt("sess_mock", { { type = "text", text = "permission" } })
        done = true
      end)
      wait_for(function()
        return event ~= nil
      end)
      t.eq(2, #event.options)
      t.eq("call_perm", event.tool_call.toolCallId)
      client:resolve_permission(event.key, "allow")
      wait_for(function()
        return done
      end, 8000)
      t.truthy(done)
      client:shutdown(true)
    end)

    t.it("cancels a running prompt", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local finished
      async.run(function()
        local ok, result = client:prompt("sess_mock", { { type = "text", text = "slow" } })
        finished = { ok = ok, result = result }
      end)
      vim.wait(300)
      client:cancel("sess_mock")
      wait_for(function()
        return finished ~= nil
      end, 8000)
      t.eq("cancelled", finished.result.stopReason)
      client:shutdown(true)
    end)

    t.it("reports a JSON-RPC error without crashing", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local finished
      async.run(function()
        local ok, result = client:prompt("sess_mock", { { type = "text", text = "fail" } })
        finished = { ok = ok, result = result }
      end)
      wait_for(function()
        return finished ~= nil
      end, 8000)
      t.falsy(finished.ok)
      t.match("mock failure", finished.result.message)
      client:shutdown(true)
    end)

    t.it("fails pending requests when the agent exits", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local exited = false
      client.on_event = function(name)
        if name == "exit" then
          exited = true
        end
      end
      local finished
      async.run(function()
        local ok, result = client:prompt("sess_mock", { { type = "text", text = "slow" } })
        finished = { ok = ok, result = result }
      end)
      vim.wait(150)
      client:shutdown(true)
      wait_for(function()
        return finished ~= nil
      end, 8000)
      t.falsy(finished.ok)
    end)

    t.it("replays history on session load", function()
      if not has_python then
        return
      end
      local client = start_client({})
      local session = state.new("sess_mock", root)
      client.on_event = function(name, payload)
        if name == "session_update" then
          reducer.apply(session, payload.update)
        end
      end
      local loaded = false
      async.run(function()
        client:load_session("sess_mock", root)
        loaded = true
      end)
      wait_for(function()
        return loaded
      end, 8000)
      t.eq(4, #session.blocks)
      t.eq("old question", session.blocks[1].text)
      t.eq("old answer", session.blocks[2].text)
      -- The replay also contains a tool with a multi-line title and a plan
      -- entry with a newline. The data keeps them intact; the renderer is
      -- responsible for folding them (see spec_newlines).
      t.eq("tool", session.blocks[3].kind)
      t.truthy(session.blocks[3].title:find("\n"), "the raw title should keep its newline")
      t.eq("plan", session.blocks[4].kind)
      t.truthy(session.blocks[4].entries[1].content:find("\n"), "the raw entry should keep its newline")
      client:shutdown(true)
    end)
  end)
end
