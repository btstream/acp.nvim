return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local picker = require("acp.ui.picker")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local marker = "/tmp/opencode/acp-auth-marker"

  local function setup(overrides, opts)
    if not (opts and opts.logged_in) then
      vim.fn.delete(marker)
    end
    acp.setup(vim.tbl_deep_extend("force", {
      agent = "opencode",
      agents = {
        opencode = {
          command = "python3",
          args = { root .. "tests/mock_agent.py" },
          env = { ACP_MOCK_AUTH_REQUIRED = "1", ACP_MOCK_AUTH_MARKER = marker },
        },
      },
      permissions = { prompt = "native" },
    }, overrides or {}))
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.connection == "ready" or S.connection == "disconnected"
    end, 20)
    return S
  end

  ---Replace the terminal runner with a stub that records the command.
  local function capture_terminal(S)
    local runs = {}
    S.auth.open_terminal = function(command, opts)
      runs[#runs + 1] = { command = command, opts = opts }
      return 1
    end
    return runs
  end

  t.describe("controller authentication", function()
    t.it("offers the agent's login methods when the agent declares one", function()
      local S = setup()
      t.eq("ready", S.connection)
      t.truthy(S.client)
      t.eq(1, #S.client.auth_methods)
      t.eq("opencode-login", S.client.auth_methods[1].id)
      controller.hide()
    end)

    t.it("runs the terminal login, then retries the failed prompt", function()
      -- Start logged in so the session can be created; then drop the marker so
      -- the *prompt* is the operation that hits auth_required.
      vim.fn.writefile({}, marker)
      local S = setup(nil, { logged_in = true })
      vim.wait(10000, function()
        return S.session ~= nil
      end, 20)
      t.truthy(S.session, "session was not created while logged in")
      vim.fn.delete(marker)
      local runs = capture_terminal(S)
      local auth_requests = 0
      local original_require = S.auth.require
      S.auth.require = function(self, err, opts)
        auth_requests = auth_requests + 1
        return original_require(self, err, opts)
      end
      controller.submit("@auth", {})
      vim.wait(8000, function()
        return #runs > 0
      end, 20)
      t.eq(1, auth_requests, "the auth error was not routed to the login flow")
      t.eq(1, #runs)
      t.truthy(
        runs[1].command:find("--mock-login", 1, true) or runs[1].command:find("mock_agent.py", 1, true),
        "unexpected login command: " .. runs[1].command
      )
      -- The mock's login command creates the marker file, exactly like a real
      -- `opencode auth login` would store credentials.
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
      local text = ""
      for _, block in ipairs(S.session.blocks) do
        if block.kind == "agent" then
          text = text .. (block.text or "")
        end
      end
      t.match("RESULT", text)
      vim.fn.delete(marker)
      controller.hide()
    end)

    t.it("does not route a non-auth error through login", function()
      local S = setup({ capabilities = { auth_terminal = false } })
      vim.wait(8000, function()
        return S.session ~= nil
      end, 20)
      local ran = false
      S.auth.open_terminal = function()
        ran = true
        return 1
      end
      controller.submit("plain", {})
      vim.wait(8000, function()
        return S.session ~= nil and S.session.status == "idle"
      end, 20)
      t.falsy(ran)
      -- The mock only offers methods to clients that declared support.
      t.eq(0, #S.client.auth_methods, "auth must stay unadvertised when disabled")
      controller.hide()
    end)

    t.it("logs out only when the agent declares it", function()
      local S = setup()
      vim.wait(8000, function()
        return S.session ~= nil
      end, 20)
      local original = S.auth.can_logout
      S.auth.can_logout = function()
        return false
      end
      local notified
      local previous = vim.notify
      vim.notify = function(message)
        notified = message
      end
      S.auth:logout()
      vim.notify = previous
      t.match("does not support", notified or "")
      S.auth.can_logout = original
      controller.hide()
    end)

    t.it("picks a login method when several are offered", function()
      local S = setup()
      local original = S.client.auth_methods
      S.client.auth_methods = {
        { id = "claude-ai", name = "claude.ai" },
        { id = "console", name = "Console", type = "terminal", args = { "login" } },
      }
      local seen, runs
      local picker_original = picker.select
      picker.select = function(opts)
        seen = opts
      end
      local ok, err = pcall(function()
        runs = capture_terminal(S)
        S.auth:login()
        t.eq(2, #seen.items)
        seen.on_choice(seen.items[2].value)
        t.eq(1, #runs)
      end)
      picker.select = picker_original
      S.client.auth_methods = original
      if not ok then
        error(err, 0)
      end
      controller.hide()
    end)
  end)
end
