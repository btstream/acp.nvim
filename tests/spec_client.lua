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
    t.it("sends session/cancel before withdrawing the prompt RPC", function()
      local sent = {}
      local client = new_client({})
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function(payload)
          sent[#sent + 1] = vim.json.decode(payload)
          return true
        end,
      })
      local id = client.rpc:request("session/prompt", {}, function() end)
      client.active_requests["session/prompt"] = id
      client.prompt_ids["s1"] = id
      client:cancel("s1")
      t.eq("session/cancel", sent[2].method)
      t.eq("$/cancel_request", sent[3].method)
      t.eq(id, sent[3].params.id)
      t.eq(nil, client.active_requests["session/prompt"])
    end)

    t.it("withdraws only the prompt of the cancelled session", function()
      local sent = {}
      local client = new_client({})
      local jsonrpc = require("acp.transport.jsonrpc")
      client.rpc = jsonrpc.new({
        send = function(payload)
          sent[#sent + 1] = vim.json.decode(payload)
          return true
        end,
      })
      local results = {}
      async.run(function()
        results.a = { client:prompt("a", {}, 1) }
      end)
      wait_for(function()
        return client.prompt_ids.a ~= nil
      end, 2000)
      async.run(function()
        results.b = { client:prompt("b", {}, 2) }
      end)
      wait_for(function()
        return client.prompt_ids.b ~= nil
      end, 2000)
      local id_a, id_b = client.prompt_ids.a, client.prompt_ids.b
      t.truthy(id_a ~= id_b)

      client:cancel("a")
      vim.wait(30)
      t.eq(nil, client.prompt_ids.a)
      t.eq(id_b, client.prompt_ids.b, "cancelling A cleared B's prompt id")
      t.eq(id_a, client.draining.a)
      t.eq(nil, client.draining.b, "draining was set for the wrong session")
      t.eq("$/cancel_request", sent[#sent].method)
      t.eq(id_a, sent[#sent].params.id)
      t.truthy(results.a, "A's prompt was not settled")
      t.eq("cancelled", results.a[2].stopReason)
      t.eq(nil, results.b, "cancelling A settled B's prompt")
      t.truthy(client.rpc.pending[id_b], "B's rpc request was withdrawn")

      -- Let B finish so its timer does not outlive the test.
      client.rpc:handle({ jsonrpc = "2.0", id = id_b, result = { stopReason = "end_turn" } })
      wait_for(function()
        return results.b ~= nil
      end, 2000)
    end)

    t.it("answers a cancelled turn's late permission request with cancelled", function()
      -- The prompt is settled locally on cancel, so the next turn can start
      -- before the agent finishes the old one. A permission request in that
      -- gap belongs to the cancelled turn and must not reach the user or the
      -- next turn's policy.
      local sent = {}
      local client = new_client({})
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function(payload)
          sent[#sent + 1] = vim.json.decode(payload)
          return true
        end,
      })
      client:install_handlers()
      local opened = 0
      client.interactions = {
        open = function()
          opened = opened + 1
        end,
        cancel_session = function() end,
      }
      local id = client.rpc:request("session/prompt", {}, function() end)
      client.active_requests["session/prompt"] = id
      client.prompt_ids["s1"] = id
      client:cancel("s1")

      local request = {
        jsonrpc = "2.0",
        id = 77,
        method = "session/request_permission",
        params = { sessionId = "s1", toolCall = { kind = "read" }, options = {} },
      }
      client.rpc:handle(request)
      t.eq(0, opened, "a cancelled turn's request was shown")
      t.eq(77, sent[#sent].id)
      t.eq("cancelled", sent[#sent].result.outcome.outcome)

      -- Once the agent answers the withdrawn prompt, its turn is over and new
      -- requests are asked normally again.
      client.rpc:handle({ jsonrpc = "2.0", id = id, result = { stopReason = "cancelled" } })
      request.id = 78
      client.rpc:handle(request)
      t.eq(1, opened)
    end)

    t.it("extends an extendable timeout while updates keep arriving", function()
      local client = new_client({})
      local rpc = require("acp.transport.jsonrpc").new({
        send = function()
          return true
        end,
      })
      client.rpc = rpc
      local done
      async.run(function()
        done = { client:request("session/load", {}, 500, true) }
      end)
      wait_for(function()
        return next(rpc.pending) ~= nil
      end, 2000)
      for _ = 1, 10 do
        vim.wait(30)
        client:touch_timeout("session/load")
      end
      local id = next(rpc.pending)
      t.truthy(id, "request timed out despite extensions")
      rpc:handle({ jsonrpc = "2.0", id = id, result = {} })
      wait_for(function()
        return done ~= nil
      end, 2000)
      t.truthy(done[1], "extended request timed out")
    end)

    t.it("times out an extendable request that stops being touched", function()
      local client = new_client({})
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function()
          return true
        end,
      })
      local done
      async.run(function()
        done = { client:request("session/load", {}, 30, true) }
      end)
      wait_for(function()
        return done ~= nil
      end, 2000)
      t.falsy(done[1])
      t.eq(require("acp.transport.jsonrpc").LOCAL_ERROR, done[2].code)
    end)

    t.it("cancels the turn before withdrawing a timed-out prompt", function()
      local sent = {}
      local client = new_client({})
      client.limits = { prompt_timeout = 30 }
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function(payload)
          sent[#sent + 1] = vim.json.decode(payload)
          return true
        end,
      })
      local done
      async.run(function()
        done = { client:prompt("s1", {}, 1) }
      end)
      wait_for(function()
        return done ~= nil
      end, 2000)
      t.falsy(done[1])
      t.eq(require("acp.transport.jsonrpc").LOCAL_ERROR, done[2].code)
      local methods = {}
      for _, message in ipairs(sent) do
        methods[#methods + 1] = message.method
      end
      t.eq({ "session/prompt", "session/cancel", "$/cancel_request" }, methods)
      t.truthy(client.draining.s1, "a timed-out turn must drain its late requests")
      t.eq(nil, client.prompt_ids.s1)
    end)

    t.it("extends the load timeout through the real event path", function()
      local events_mod = require("acp.app.events")
      local touched = {}
      local S = {
        conn = {
          replaying = true,
          client = {
            touch_timeout = function(_, key)
              touched[#touched + 1] = key
            end,
          },
        },
        sess = { runtime = { apply = function() end } },
      }
      local events = events_mod.new({
        state = function()
          return S
        end,
        refresh_chrome = function() end,
        notify = function() end,
        add_block = function() end,
        prune = function() end,
        on_exit = function()
          return false
        end,
      })
      events:dispatch("session_update", { sessionId = "s1", update = {} })
      t.eq({ "session/load" }, touched)
    end)

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
