return function(t)
  local controller = require("acp.controller")
  local async = require("acp.async")
  local drafts = require("acp.storage.drafts")

  local function fixture(fn)
    drafts.flush()
    local original = drafts.path
    local path = "/tmp/opencode/acp-lifecycle-" .. vim.uv.os_getpid() .. ".json"
    drafts.path = function()
      return path
    end
    drafts.clear()
    controller.setup({ cwd = "/tmp/project-a" })
    local s = controller.state()
    local sent, pending = {}, {}
    local client = {
      shutdown = function() end,
      has_session_capability = function()
        return false
      end,
      load_session = function()
        return true, {}
      end,
      prompt = function(_, id, prompt)
        sent[#sent + 1] = { id = id, prompt = prompt }
        return async.await(function(done)
          pending[id] = done
        end)
      end,
    }
    s.client, s.connection = client, "ready"
    s.session_cwds.a, s.session_cwds.b = "/tmp/project-a", "/tmp/project-b"
    controller.load_session("a")
    local notify = vim.notify
    vim.notify = function() end -- expected failure paths are asserted below
    local ok, err = pcall(fn, s, client, sent, pending)
    controller.setup({}, { discard_queued = true }) -- explicit teardown of fixture-owned messages
    drafts.clear()
    drafts.path = original
    vim.notify = notify
    if not ok then
      error(err)
    end
  end

  local function with_browser(s, client, fn)
    local browser = require("acp.ui.session_picker")
    local original, options = browser.open, nil
    browser.open = function(opts)
      options = opts
      return {}
    end
    s.config.ui.session_picker = "internal"
    client.has_session_capability = function()
      return true
    end
    client.list_sessions = function()
      return true,
        {
          sessions = {
            { sessionId = "a", title = "A", cwd = "/tmp/project-a" },
            { sessionId = "b", title = "B", cwd = "/tmp/project-b" },
          },
        }
    end
    local ok, err = pcall(function()
      controller.pick_session()
      fn(options)
    end)
    browser.open = original
    if not ok then
      error(err)
    end
  end

  t.describe("runtime ownership", function()
    t.it("keeps the composer when a send fails synchronously", function()
      fixture(function(s, client)
        client.prompt = function()
          return false, { message = "failed to send" }
        end
        s.input:restore("keep this draft")
        controller.submit("keep this draft", {})
        t.eq("keep this draft", s.input:text())
        t.eq("idle", s.session.status)
        t.eq(nil, s.session.prompt_task)
      end)
    end)

    t.it("reopening a dead client installs fresh event bindings", function()
      fixture(function(s, client)
        client.is_ready = function()
          return false
        end
        local mod, event = require("acp.protocol.client"), nil
        local original = mod.new
        local fresh = {
          shutdown = function() end,
          has_session_capability = function()
            return false
          end,
          agent_capabilities = function()
            return { loadSession = true }
          end,
          load_session = function()
            return true, {}
          end,
        }
        local ready = false
        fresh.is_ready = function()
          return ready
        end
        fresh.start = function(_, cb)
          ready = true
          cb(true)
        end
        mod.new = function(opts)
          event = opts.on_event
          return fresh
        end
        local ok, err = pcall(function()
          controller.on_client_event("exit", {})
          controller.open()
          vim.wait(30)
          t.truthy(s.client == fresh)
          event("session_update", {
            sessionId = "a",
            update = {
              sessionUpdate = "agent_message_chunk",
              content = { type = "text", text = "fresh reply" },
            },
          })
          t.eq("fresh reply", s.session.blocks[1].text)
          controller.hide()
        end)
        mod.new = original
        if not ok then
          error(err)
        end
      end)
    end)

    t.it("cancels a deleted background turn without sending its outbox", function()
      fixture(function(s, client, sent, pending)
        controller.submit("first A", {})
        controller.submit("queued A", {})
        local old_done = pending.a
        controller.load_session("b")
        client.delete_session = function()
          return true, {}
        end
        with_browser(s, client, function(browser)
          local calls = 0
          browser.on_delete("a", function(ok)
            t.truthy(ok)
            calls = calls + 1
          end)
          t.eq(1, calls)
          t.eq(nil, s.sessions.a)
          old_done(false, { message = "late deleted-session failure" })
          vim.wait(30)
          t.eq(1, #sent)
          t.eq("b", s.session.id)
          t.eq(0, #s.session.blocks)
        end)
      end)
    end)

    t.it("cancels a deleted staging replay and releases the replay lock", function()
      fixture(function(s, client)
        local done
        client.load_session = function()
          return async.await(function(cb)
            done = cb
          end)
        end
        client.delete_session = function()
          return true, {}
        end
        controller.load_session("b")
        with_browser(s, client, function(browser)
          browser.on_delete("b", function(ok)
            t.truthy(ok)
          end)
          t.eq(false, s.replaying)
          t.eq(nil, s.runtime.replays.b)
          done(true, {})
          vim.wait(30)
          t.eq("a", s.session.id)
          t.eq(nil, s.sessions.b)
        end)
      end)
    end)

    t.it("settles a cancelled delete callback exactly once", function()
      fixture(function(s, client)
        local done
        client.delete_session = function()
          return async.await(function(cb)
            done = cb
          end)
        end
        with_browser(s, client, function(browser)
          local results = {}
          browser.on_delete("b", function(ok)
            results[#results + 1] = ok
          end)
          controller.disconnect()
          t.eq({ false }, results)
          done(true, {})
          vim.wait(30)
          t.eq({ false }, results)
        end)
      end)
    end)

    t.it("refuses silent outbox loss during reconfiguration", function()
      fixture(function(s)
        s.runtime:enqueue(s.session, "unsent", {})
        local session, config = s.session, s.config
        local ok = pcall(controller.setup, { cwd = "/tmp/other" })
        t.eq(false, ok)
        t.truthy(s.session == session and s.config == config)
        t.eq(1, #session.queue)
        controller.setup({ cwd = "/tmp/other" }, { discard_queued = true })
        t.eq(nil, s.session)
      end)
    end)

    t.it("shares a reserved outbox across a history transaction", function()
      fixture(function(s)
        local runtime, previous = s.runtime, s.session
        runtime:enqueue(previous, "unsent", {})
        local item = runtime:next_message(previous)
        local staged = runtime:stage("a", previous.cwd)
        t.truthy(runtime:commit(staged))
        t.eq(nil, runtime:next_message(staged), "a reserved send must not be duplicated")
        runtime:restore_message(previous, item)
        t.eq(1, #staged.queue)
        t.eq(item.bytes, staged.queue_bytes)
        t.eq(item, runtime:next_message(staged))
        runtime:ack_message(staged, item)
        t.eq(nil, staged.outbox.reserved)
      end)
    end)

    t.it("marks a staged replay as history", function()
      fixture(function(s)
        local runtime = s.runtime
        local staged = runtime:stage("a", "/tmp/project-a")
        t.truthy(staged.historical, "a replayed session must be marked as history")
        runtime:rollback(staged)
        -- A freshly created session is live, so its cards may open themselves.
        local fresh = runtime:create("live", "/tmp/project-a", {})
        t.falsy(fresh.historical, "a new session was marked as history")
        runtime:remove("live")
      end)
    end)

    t.it("keeps a staged replay's cards closed", function()
      fixture(function(s)
        local runtime, reducer = s.runtime, require("acp.session.reducer")
        local staged = runtime:stage("a", "/tmp/project-a")
        reducer.apply(staged, {
          sessionUpdate = "tool_call",
          toolCallId = "c1",
          kind = "edit",
          status = "completed",
          rawInput = { path = "/tmp/project-a/f.lua", oldString = "a", newString = "b" },
        })
        t.falsy(staged.blocks[1].expanded, "a replayed card opened itself")
        runtime:rollback(staged)
      end)
    end)

    t.it("does not clear a newly selected composer during a reentrant send", function()
      fixture(function(s, client)
        s.input:restore("draft A")
        client.prompt = function()
          controller.load_session("b")
          s.input:restore("draft B")
          return true, { stopReason = "end_turn" }
        end
        controller.submit("draft A", {})
        t.eq("b", s.session.id)
        t.eq("draft B", s.input:text())
        t.eq(nil, drafts.get("/tmp/project-a", "a"))
      end)
    end)

    t.it("keeps queued messages when recovery history fails to load", function()
      fixture(function(s, client)
        local a = s.session
        s.runtime:enqueue(a, "unsent", {})
        s.runtime:connection_lost()
        client.load_session = function()
          return false, { message = "load rejected" }
        end
        controller.load_session("a")
        t.truthy(s.session == a)
        t.eq(1, #a.queue)
        t.eq(true, a.needs_load)
      end)
    end)

    t.it("rejects a late model picker from an earlier connection", function()
      fixture(function(s, client)
        local picker = require("acp.ui.picker")
        local original, choice = picker.select, nil
        picker.select = function(opts)
          choice = opts
        end
        local ok, err = pcall(function()
          s.session:configure({
            configOptions = {
              {
                id = "model",
                name = "Model",
                category = "model",
                currentValue = "one",
                options = { { value = "one", name = "One" } },
              },
            },
          })
          controller.pick_model()
          controller.disconnect()
          local calls = 0
          client.set_config_option = function()
            calls = calls + 1
            return true, {}
          end
          s.client, s.connection = client, "ready"
          choice.on_choice("one")
          t.eq(0, calls)
        end)
        picker.select = original
        if not ok then
          error(err)
        end
      end)
    end)

    t.it("reduces protocol notifications inside the transport dispatch budget", function()
      fixture(function(s, client)
        local mod = require("acp.protocol.client")
        local original_new, original_event = mod.new, controller.on_client_event
        local opts, count = nil, 0
        mod.new = function(value)
          opts = value
          return client
        end
        controller.on_client_event = function()
          count = count + 1
        end
        client.is_ready = function()
          return true
        end
        local ok, err = pcall(function()
          s.client = nil
          controller.connect()
          opts.on_event("session_update", {})
          t.eq(1, count, "the reducer must not escape into a second unbudgeted queue")
        end)
        mod.new, controller.on_client_event = original_new, original_event
        if not ok then
          error(err)
        end
      end)
    end)

    t.it("clears durable drafts only after their message is accepted", function()
      fixture(function(s)
        s.input:restore("send this")
        s.input:save_draft()
        t.truthy(drafts.get("/tmp/project-a", "a"))
        controller.submit("send this", {})
        t.eq(nil, drafts.get("/tmp/project-a", "a"))
      end)
    end)

    t.it("retains attachment-only drafts across session switches", function()
      fixture(function(s)
        s.input:add_attachment({ kind = "file", label = "a.lua", path = "/tmp/a.lua" })
        controller.load_session("b")
        local draft = drafts.get("/tmp/project-a", "a")
        t.truthy(draft)
        t.eq(1, #draft.attachments)
      end)
    end)

    t.it("persists a draft under its original project and session", function()
      fixture(function(s)
        s.input:restore("draft for A")
        controller.load_session("b")
        t.eq("draft for A", drafts.get("/tmp/project-a", "a").text)
        t.eq(nil, drafts.get("/tmp/project-b", "b"))
      end)
    end)

    t.it("continues an accepted queue while another session is visible", function()
      fixture(function(s, _, sent, pending)
        controller.submit("first A", {})
        controller.submit("second A", {})
        local a = s.session
        controller.load_session("b")
        pending.a(true, { stopReason = "end_turn" })
        vim.wait(30)
        t.eq(2, #sent)
        t.eq("a", sent[2].id)
        t.eq("second A", sent[2].prompt[1].text)
        t.eq("b", s.session.id)
        controller.load_session("a")
        t.truthy(s.session == a, "view selection must not replace the running runtime")
      end)
    end)

    t.it("routes a background prompt error to its originating session", function()
      fixture(function(s, _, _, pending)
        controller.submit("first A", {})
        local a = s.session
        controller.load_session("b")
        pending.a(false, { message = "error from A" })
        vim.wait(30)
        t.truthy(a.blocks[#a.blocks].text:find("error from A", 1, true))
        t.eq(0, #s.session.blocks)
      end)
    end)

    t.it("does not adopt a stale creation result after setup", function()
      fixture(function(s, client)
        local complete
        client.new_session = function()
          return async.await(function(done)
            complete = done
          end)
        end
        controller.new_session()
        complete(true, { sessionId = "old-result" })
        controller.setup({ cwd = "/tmp/new-project" })
        vim.wait(30)
        t.eq(nil, s.session)
        t.eq(nil, s.sessions["old-result"])
      end)
    end)

    t.it("does not let old cleanup unlock a new creation", function()
      fixture(function(s, client)
        local old_done, new_done
        client.new_session = function()
          return async.await(function(done)
            old_done = done
          end)
        end
        controller.new_session()
        old_done(true, { sessionId = "old" })
        controller.setup({ cwd = "/tmp/new-project" })
        s.client, s.connection = client, "ready"
        client.new_session = function()
          return async.await(function(done)
            new_done = done
          end)
        end
        controller.new_session()
        vim.wait(30)
        t.truthy(s.creating_session)
        new_done(true, { sessionId = "new" })
        vim.wait(30)
        t.eq("new", s.session.id)
        t.eq(false, s.creating_session)
      end)
    end)

    t.it("keeps old history and selection when a replay fails", function()
      fixture(function(s, client)
        local done
        local a = s.session
        a:add_local_user("old history")
        client.load_session = function()
          return async.await(function(cb)
            done = cb
          end)
        end
        controller.load_session("b")
        controller.on_client_event("session_update", {
          sessionId = "b",
          update = {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = "partial replay" },
          },
        })
        t.truthy(s.session == a)
        t.eq(nil, s.sessions.b)
        done(false, { message = "load rejected" })
        vim.wait(30)
        t.truthy(s.session == a)
        t.eq("old history", a.blocks[1].text)
        t.eq(nil, s.runtime.replays.b)
        t.eq(false, s.replaying)
      end)
    end)

    t.it("does not steal selection when a newer intent completes first", function()
      fixture(function(s, client)
        local done
        client.load_session = function()
          return async.await(function(cb)
            done = cb
          end)
        end
        client.new_session = function()
          return true, { sessionId = "c" }
        end
        controller.load_session("b")
        controller.new_session()
        t.eq("c", s.session.id)
        done(true, {})
        vim.wait(30)
        t.eq("c", s.session.id)
        t.truthy(s.sessions.b)
      end)
    end)

    t.it("resumes only unsent queued messages after reconnection and replay", function()
      fixture(function(s, client, sent, pending)
        controller.submit("in flight", {})
        controller.submit("queued", {})
        local old_done = pending.a
        controller.disconnect()
        t.eq(1, #s.sessions.a.queue)
        t.eq(true, s.sessions.a.needs_load)
        s.client, s.connection = client, "ready"
        controller.load_session("a")
        t.eq(2, #sent)
        t.eq("queued", sent[2].prompt[1].text)
        old_done(false, { message = "old disconnect error" })
        vim.wait(30)
        t.eq("running", s.session.status)
        t.eq(2, #sent)
      end)
    end)

    t.it("has one turn owner despite duplicate prompt_finished events", function()
      fixture(function(s, client, sent, pending)
        local prompt = client.prompt
        client.prompt = function(self, id, blocks, turn)
          local ok, result = prompt(self, id, blocks)
          controller.on_client_event("prompt_finished", { session_id = id, turn = turn, ok = ok, result = result })
          return ok, result
        end
        controller.submit("first", {})
        controller.submit("second", {})
        pending.a(true, { stopReason = "end_turn" })
        vim.wait(30)
        t.eq(2, #sent)
        t.eq("running", s.session.status)
        controller.on_client_event("prompt_finished", { session_id = "a", turn = 1, ok = true, result = {} })
        t.eq("running", s.session.status)
        pending.a(true, { stopReason = "end_turn" })
        vim.wait(30)
        t.eq("idle", s.session.status)
      end)
    end)

    t.it("does not resolve a new permission through an old picker", function()
      fixture(function(s, client)
        local picker = require("acp.ui.picker")
        local original, choices = picker.select, {}
        picker.select = function(opts)
          choices[#choices + 1] = opts
        end
        local ok, err = pcall(function()
          local resolved = 0
          client.resolve_permission = function()
            resolved = resolved + 1
          end
          local request = { sessionId = "a", options = { { optionId = "allow", name = "Allow", kind = "allow_once" } } }
          s.interactions:open("permission", request, function() end, 1, "same")
          controller.show_permission({ key = "same" })
          controller.disconnect()
          s.client, s.connection = client, "ready"
          s.interactions:open("permission", request, function() end, 2, "same")
          choices[1].on_choice({ id = "allow" })
          choices[1].on_cancel()
          t.eq(0, resolved)
          t.truthy(s.interactions:get("same").state == "pending")
          controller.show_permission({ key = "same" })
          choices[2].on_choice({ id = "allow" })
          -- The current interaction resolves directly, not through the old
          -- client path.
          t.eq("answered", s.interactions:get("same").state)
        end)
        picker.select = original
        if not ok then
          error(err)
        end
      end)
    end)
  end)

  t.describe("task terminal states", function()
    t.it("closes a partially written stream before another request can follow", function()
      local start, stop, send = vim.fn.jobstart, vim.fn.jobstop, vim.fn.chansend
      local writes, stops = 0, 0
      vim.fn.jobstart = function()
        return 999999
      end
      vim.fn.jobstop = function()
        stops = stops + 1
      end
      vim.fn.chansend = function()
        writes = writes + 1
        if writes == 1 then
          return 3
        end
        error("broken pipe")
      end
      local ok, err = pcall(function()
        local proc = require("acp.transport.process").spawn({
          command = "mock",
          on_line = function() end,
          on_exit = function() end,
        })
        t.eq(false, proc:write("partial request\n"))
        t.eq(1, stops)
        t.eq(false, proc:is_alive())
        t.eq(false, proc:write("must not follow\n"))
        t.eq(2, writes)
      end)
      vim.fn.jobstart, vim.fn.jobstop, vim.fn.chansend = start, stop, send
      if not ok then
        error(err)
      end
    end)

    t.it("runs await cancellation cleanup exactly once", function()
      local done, cleanup, continued = nil, 0, false
      local co = async.run(function()
        async.await(function(cb)
          done = cb
          return function()
            cleanup = cleanup + 1
          end
        end)
        continued = true
      end)
      t.truthy(async.cancel(co))
      t.eq(false, async.cancel(co))
      done(true, {})
      vim.wait(30)
      t.eq(1, cleanup)
      t.eq(false, continued)
    end)

    t.it("settles failed client writes even with request timeouts disabled", function()
      local client = require("acp.protocol.client").new({ agent = {}, cwd = "/tmp", limits = { request_timeout = 0 } })
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function()
          return false
        end,
      })
      local result
      async.run(function()
        local ok = client:new_session("/tmp")
        result = ok
      end)
      vim.wait(30)
      t.eq(false, result)
      t.eq(0, vim.tbl_count(client.rpc.pending))
    end)

    t.it("propagates initialization errors after suspension to every waiter", function()
      local client = require("acp.protocol.client").new({ agent = {}, cwd = "/tmp" })
      local done, errors = nil, {}
      client.do_start = function()
        async.await(function(cb)
          done = cb
        end)
        error("startup exploded")
      end
      for _ = 1, 2 do
        client:start(function(ok, err)
          errors[#errors + 1] = { ok = ok, err = tostring(err) }
        end)
      end
      done(true, {})
      vim.wait(30)
      t.eq(2, #errors)
      for _, value in ipairs(errors) do
        t.eq(false, value.ok)
        t.truthy(value.err:find("startup exploded", 1, true))
      end
      t.eq(false, client.starting)
    end)

    t.it("cancels a task's pending RPC and ignores its late result", function()
      local client = require("acp.protocol.client").new({ agent = {}, cwd = "/tmp", limits = { request_timeout = 0 } })
      client.rpc = require("acp.transport.jsonrpc").new({
        send = function()
          return true
        end,
      })
      local state = { client = client, sessions = {} }
      local scope = require("acp.tasks").new(function()
        return state
      end)
      local resumed, finalized = false, 0
      local task = scope:run(
        "test",
        client,
        nil,
        function(op)
          op:call("new_session", "/tmp")
          resumed = true
        end,
        nil,
        function()
          finalized = finalized + 1
        end
      )
      t.eq(1, vim.tbl_count(client.rpc.pending))
      scope:reset()
      t.eq(0, vim.tbl_count(client.rpc.pending))
      client.rpc:handle({ jsonrpc = "2.0", id = 1, result = { sessionId = "late" } })
      vim.wait(30)
      t.eq("cancelled", task.status)
      t.eq(false, resumed)
      t.eq(1, finalized)
    end)

    t.it("releases creation state after a post-yield exception", function()
      fixture(function(s, client)
        local done
        client.new_session = function()
          async.await(function(cb)
            done = cb
          end)
          error("bad creation result")
        end
        controller.new_session()
        done(true, {})
        vim.wait(30)
        t.eq(false, s.creating_session)
        t.eq("a", s.session.id)
      end)
    end)

    t.it("joins initialization callers instead of reporting premature success", function()
      local client = require("acp.protocol.client").new({ agent = {}, cwd = "/tmp" })
      local done, callbacks = nil, 0
      client.do_start = function()
        return async.await(function(cb)
          done = cb
        end)
      end
      client:start(function(ok)
        t.truthy(ok)
        callbacks = callbacks + 1
      end)
      client:start(function(ok)
        t.truthy(ok)
        callbacks = callbacks + 1
      end)
      t.eq(0, callbacks)
      done(true, {})
      vim.wait(30)
      t.eq(2, callbacks)
    end)

    t.it("cancels initialization and settles all waiters once", function()
      local client = require("acp.protocol.client").new({ agent = {}, cwd = "/tmp" })
      local done, results = nil, {}
      client.do_start = function()
        return async.await(function(cb)
          done = cb
        end)
      end
      client:start(function(ok)
        results[#results + 1] = ok
      end)
      client:start(function(ok)
        results[#results + 1] = ok
      end)
      client:shutdown(true)
      done(true, {})
      vim.wait(30)
      t.eq({ false, false }, results)
      t.eq(false, client.starting)
    end)

    t.it("runs the local error handler after a yield and finalizes once", function()
      local complete, errors, cleanups = nil, 0, 0
      async.run(function()
        async.finally(function()
          cleanups = cleanups + 1
        end)
        async.await(function(done)
          complete = done
        end)
        error("late error")
      end, function()
        errors = errors + 1
      end)
      complete(true, {})
      vim.wait(30)
      t.eq(1, errors)
      t.eq(1, cleanups)
    end)

    t.it("settles failed RPC writes immediately without a pending leak", function()
      local rpc = require("acp.transport.jsonrpc").new({
        send = function()
          return false
        end,
      })
      local calls, success = 0, nil
      local id = rpc:request("example", {}, function(ok)
        calls, success = calls + 1, ok
      end)
      t.eq(nil, id)
      t.eq(1, calls)
      t.eq(false, success)
      t.eq(0, vim.tbl_count(rpc.pending))
    end)
  end)

  t.describe("manager leases across setup", function()
    t.it("releases the previous connection's lease when reconfiguring", function()
      local root = string.format("/tmp/opencode/acp-lifecycle-lease-%d", vim.uv.hrtime())
      vim.fn.mkdir(root, "p")
      controller.setup({ agent = "opencode", manager = { root = root } })
      local S = controller.state()
      local locks = S.conn.locks
      local lease = assert(locks:lease("pi", "rel-x"))
      t.truthy(lease)
      t.truthy(locks:install_in_use("pi", "rel-x"))
      t.eq(1, vim.tbl_count(locks.timers))
      controller.setup({ agent = "claude", manager = { root = root } }, { discard_queued = true })
      t.falsy(locks:install_in_use("pi", "rel-x"), "the old lease survived the reconfiguration")
      t.eq(0, vim.tbl_count(locks.timers), "the old lease heartbeat timer keeps running")
      controller.setup({}, { discard_queued = true })
      vim.fn.delete(root, "rf")
    end)
  end)
end
