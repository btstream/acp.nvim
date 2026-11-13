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
      return S.connection == "ready"
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
        return S.session ~= nil
      end, 20)
      t.truthy(S.session, "session was not created")
      vim.fn.delete(marker)
      local runs = {}
      S.auth.open_terminal = function(command, opts)
        runs[#runs + 1] = { command = command, opts = opts }
        return 1
      end

      controller.submit("@auth", {})
      vim.wait(6000, function()
        return #runs > 0
      end, 20)
      t.eq(1, #runs)
      -- The message was never delivered, so it must stay visible exactly once.
      t.eq(1, count(S.session, "user"), "the user message was dropped or duplicated")
      t.eq(0, count(S.session, "error"), "the failed attempt left an error block")

      vim.fn.writefile({}, marker)
      runs[1].opts.on_exit(0)
      vim.wait(15000, function()
        local text = ""
        for _, block in ipairs(S.session and S.session.blocks or {}) do
          if block.kind == "agent" then
            text = text .. (block.text or "")
          end
        end
        return text:find("RESULT", 1, true) ~= nil
      end, 20)
      t.eq(1, count(S.session, "user"), "the retried message was added twice")
      t.eq(0, count(S.session, "error"), "a turn that will be retried left an error")
      vim.fn.delete(marker)
      controller.hide()
    end)

    t.it("does not start a login for a timeout or a crash", function()
      vim.fn.writefile({}, marker)
      local S = setup()
      vim.wait(10000, function()
        return S.session ~= nil
      end, 20)
      local runs = {}
      S.auth.open_terminal = function(command, opts)
        runs[#runs + 1] = opts
        return 1
      end

      -- A provider failure with a non-reserved code.
      controller.submit("fail", {})
      vim.wait(6000, function()
        return S.session and S.session.status == "idle"
      end, 20)
      t.eq(0, #runs, "a generic error started a login")

      -- A crash while a turn is in flight. Wait for the connection to report
      -- the loss instead of sleeping for a fixed period.
      controller.submit("slow", {})
      vim.wait(2000, function()
        return S.session and S.session.status == "running"
      end, 20)
      S.client.proc:stop(true)
      local settled = vim.wait(10000, function()
        return S.connection == "disconnected" and (S.session == nil or S.session.status == "idle")
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
