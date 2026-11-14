return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local marker = "/tmp/opencode/acp-auth-retry-marker"

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup()
    acp.setup({
      agent = "opencode",
      agents = {
        opencode = {
          command = "python3",
          args = { root .. "tests/mock_agent.py" },
          env = { ACP_MOCK_AUTH_REQUIRED = "1", ACP_MOCK_AUTH_MARKER = marker },
        },
      },
      permissions = { prompt = "native" },
    })
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.conn.phase == "ready"
    end, 20)
    return S
  end

  local function count(session, kind)
    local n = 0
    for _, block in ipairs(session and session.blocks or {}) do
      if block.kind == kind then
        n = n + 1
      end
    end
    return n
  end

  t.describe("auth prompt retry", function()
    t.it("retries the same message without duplicating the user block", function()
      vim.fn.writefile({}, marker)
      local S = setup()
      vim.wait(10000, function()
        return S.sess.current ~= nil
      end, 20)
      t.truthy(S.sess.current, "session was not created")
      vim.fn.delete(marker)
      local runs = {}
      S.view.auth.open_terminal = function(command, opts)
        runs[#runs + 1] = { command = command, opts = opts }
        return 1
      end

      controller.submit("@auth", {})
      vim.wait(6000, function()
        return #runs > 0
      end, 20)
      t.eq(1, #runs)
      -- The message was never delivered, so it must stay visible exactly once.
      t.eq(1, count(S.sess.current, "user"), "the user message was dropped or duplicated")
      t.eq(0, count(S.sess.current, "error"), "the failed attempt left an error block")

      vim.fn.writefile({}, marker)
      runs[1].opts.on_exit(0)
      vim.wait(15000, function()
        local text = ""
        for _, block in ipairs(S.sess.current and S.sess.current.blocks or {}) do
          if block.kind == "agent" then
            text = text .. (block.text or "")
          end
        end
        return text:find("RESULT", 1, true) ~= nil
      end, 20)
      t.eq(1, count(S.sess.current, "user"), "the retried message was added twice")
      t.eq(0, count(S.sess.current, "error"), "a turn that will be retried left an error")
      vim.fn.delete(marker)
      controller.hide()
    end)

    t.it("does not start a second login and keeps the queued message", function()
      vim.fn.writefile({}, marker)
      local S = setup()
      vim.wait(10000, function()
        return S.sess.current ~= nil
      end, 20)
      t.truthy(S.sess.current, "session was not created")
      vim.fn.delete(marker)
      local runs = {}
      S.view.auth.open_terminal = function(command, opts)
        runs[#runs + 1] = { command = command, opts = opts }
        return 1
      end
      local session = S.sess.current

      -- Keep the session busy so both messages are queued behind the turn.
      controller.submit("slow", {})
      vim.wait(4000, function()
        return session.status == "running"
      end, 20)
      t.eq("running", session.status)
      controller.submit("@auth", {})
      controller.submit("second queued", {})
      t.eq(2, #session.queue)

      controller.cancel()
      vim.wait(10000, function()
        return #runs > 0
      end, 20)
      t.eq(1, #runs, "the auth failure did not start a login")
      -- The message behind the failed one must stay parked instead of being
      -- dispatched into the same unauthenticated connection.
      vim.wait(1500)
      t.eq(1, #runs, "a second login was started while the first was running")
      t.eq(1, #session.queue, "the queued message was dispatched into the login")

      vim.fn.writefile({}, marker)
      runs[1].opts.on_exit(0)
      local delivered = vim.wait(25000, function()
        local live = S.sess.current
        return live ~= nil and live.status == "idle" and #live.queue == 0 and count(live, "user") == 2
      end, 20)
      t.truthy(delivered, "the parked messages were never replayed")
      t.eq(2, count(S.sess.current, "user"), "a parked message was lost or duplicated")
      t.eq(1, #runs)
      vim.fn.delete(marker)
      controller.hide()
    end)

    t.it("ends an inline turn instead of replaying its envelope after login", function()
      vim.fn.writefile({}, marker)
      local S = setup()
      vim.wait(10000, function()
        return S.sess.current ~= nil
      end, 20)
      t.truthy(S.sess.current, "session was not created")
      vim.fn.delete(marker)
      local runs = {}
      S.view.auth.open_terminal = function(command, opts)
        runs[#runs + 1] = { command = command, opts = opts }
        return 1
      end
      local notes = {}
      local notify = vim.notify
      vim.notify = function(message)
        notes[#notes + 1] = tostring(message)
      end
      local session = S.sess.current
      local result_ok, finished = nil, 0
      local hooks = {
        local_user = { display_text = "inline: edit" },
        on_result = function(ok)
          result_ok = ok
        end,
        on_finally = function()
          finished = finished + 1
        end,
      }
      local sent = S.sess.prompts:send(session, "@auth", nil, hooks)
      vim.wait(8000, function()
        return #runs > 0
      end, 20)
      vim.wait(500)
      vim.notify = notify
      t.truthy(sent)
      t.eq(1, #runs)
      t.eq(false, result_ok, "the inline turn was not ended")
      t.eq(1, finished, "the inline invocation was not released")
      t.falsy(S.conn.pending_auth_retries and S.conn.pending_auth_retries[1], "an inline retry was parked")
      t.match("re%-run", table.concat(notes, "\n"))
      t.eq(1, count(session, "user"))

      vim.fn.writefile({}, marker)
      runs[1].opts.on_exit(0)
      vim.wait(10000, function()
        return S.conn.phase == "ready"
      end, 20)
      vim.wait(500)
      t.eq(1, count(session, "user"), "the inline envelope was replayed as a chat turn")
      vim.fn.delete(marker)
      controller.hide()
    end)

    t.it("dispatches the queue when a parked retry times out", function()
      vim.fn.writefile({}, marker)
      local S = setup()
      vim.wait(10000, function()
        return S.sess.current ~= nil
      end, 20)
      t.truthy(S.sess.current, "session was not created")
      vim.fn.delete(marker)
      local session = S.sess.current
      local notes = {}
      local notify = vim.notify
      vim.notify = function(message)
        notes[#notes + 1] = tostring(message)
      end
      t.truthy(S.sess.runtime:enqueue(session, "queued after timeout", {}))
      S.conn.flow:park_for_retry(session.id, "lost retry", {})
      S.conn.pending_auth_retries[1].deadline = 0
      session.prompt_task = {} -- pretend another turn is still settling
      t.eq(false, S.conn.flow:flush_auth_retry())
      t.falsy(S.conn.pending_auth_retries[1])
      local sent = vim.wait(10000, function()
        return session.status == "idle" and #session.queue == 0 and count(session, "user") == 1
      end, 20)
      vim.notify = notify
      t.truthy(sent, "the queued message stayed stuck after the parked retry timed out")
      t.eq("queued after timeout", session.blocks[1] and session.blocks[1].text)
      t.match("queued message", table.concat(notes, "\n"))
      vim.fn.delete(marker)
      controller.hide()
    end)

    t.it("does not start a login for a timeout or a crash", function()
      vim.fn.writefile({}, marker)
      local S = setup()
      vim.wait(10000, function()
        return S.sess.current ~= nil
      end, 20)
      local runs = {}
      S.view.auth.open_terminal = function(command, opts)
        runs[#runs + 1] = opts
        return 1
      end

      -- A provider failure with a non-reserved code.
      controller.submit("fail", {})
      vim.wait(6000, function()
        return S.sess.current and S.sess.current.status == "idle"
      end, 20)
      t.eq(0, #runs, "a generic error started a login")

      -- A crash while a turn is in flight. Wait for the connection to report
      -- the loss instead of sleeping for a fixed period.
      controller.submit("slow", {})
      vim.wait(2000, function()
        return S.sess.current and S.sess.current.status == "running"
      end, 20)
      S.conn.client.proc:stop(true)
      local settled = vim.wait(10000, function()
        return S.conn.phase == "disconnected" and (S.sess.current == nil or S.sess.current.status == "idle")
      end, 20)
      t.truthy(settled, "the agent crash was not observed")
      -- Give any (wrong) login decision a chance to run before asserting.
      vim.wait(300)
      t.eq(0, #runs, "an agent crash started a login")
      vim.fn.delete(marker)
      controller.hide()
    end)
  end)
end
