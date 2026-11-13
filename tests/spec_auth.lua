return function(t)
  local auth = require("acp.app.auth")

  local function config(overrides)
    return function()
      return vim.tbl_deep_extend("force", {
        agent = "opencode",
        cwd = "/tmp",
        agents = {
          opencode = { command = "opencode", args = { "acp" } },
          claude = { command = "claude-agent-acp", args = {} },
        },
      }, overrides or {})
    end
  end

  local function harness(overrides)
    local notices, terminals, classifications = {}, {}, {}
    local client = {
      auth_methods = {},
      capabilities = {},
      authenticate = function(_, method_id)
        classifications[#classifications + 1] = { method = method_id }
        return true, {}
      end,
      logout = function()
        classifications[#classifications + 1] = { logout = true }
        return true, {}
      end,
    }
    local retries = 0
    local deferred = {}
    local a = auth.new({
      config = config(overrides),
      client = function()
        return client
      end,
      notify = function(message, level)
        notices[#notices + 1] = { message = message, level = level }
      end,
      restart = function()
        terminals.reconnects = (terminals.reconnects or 0) + 1
      end,
      after_ready = function(fn)
        deferred[#deferred + 1] = fn
      end,
      open_terminal = function(command, opts)
        terminals[#terminals + 1] = { command = command, opts = opts }
        return 1
      end,
    })
    return {
      auth = a,
      client = client,
      notices = notices,
      terminals = terminals,
      calls = classifications,
      deferred = deferred,
      retried = function()
        return retries
      end,
    }
  end

  t.describe("auth", function()
    t.it("recognises the auth_required error code only", function()
      t.truthy(auth.is_auth_error({ code = -32000 }))
      t.truthy(auth.is_auth_error({ code = -32000, message = "Authentication required" }))
      -- A local failure (timeout, closed transport) must not look like a login.
      t.falsy(auth.is_auth_error({ code = -32099, message = "request timed out: session/prompt" }))
      t.falsy(auth.is_auth_error({ code = -32601, message = "auth is not supported" }))
      t.falsy(auth.is_auth_error("auth required"))
      t.falsy(auth.is_auth_error(nil))
    end)

    t.it("reads methods from the error payload", function()
      local methods = { { id = "x", name = "X" } }
      t.eq(methods, auth.methods_from({ code = -32000, data = { authMethods = methods } }))
      t.eq(nil, auth.methods_from({ code = -32000 }))
    end)

    t.it("builds a login command from the agent when no terminal-auth meta exists", function()
      local spec = auth.terminal_spec({ id = "m", type = "terminal", args = { "--login" } }, {
        command = "opencode",
        args = { "acp" },
      })
      t.eq("opencode", spec.command)
      t.eq({ "acp", "--login" }, spec.args)
      t.eq("'opencode' 'acp' '--login'", auth.command_line(spec))
    end)

    t.it("prefers the client's configured command over any _meta command", function()
      -- ACP: "The descriptor cannot provide a command." Only args/env are used.
      local spec = auth.terminal_spec({
        id = "m",
        _meta = { ["terminal-auth"] = { command = "/tmp/evil", args = { "login" } } },
        args = { "--login" },
      }, { command = "opencode", args = { "acp" }, env = { A = "1" } })
      t.eq("opencode", spec.command)
      t.eq({ "acp", "--login" }, spec.args)
      t.eq({ A = "1" }, spec.env)
    end)

    t.it("merges the method env over the configured launch env", function()
      local spec = auth.terminal_spec(
        { id = "m", type = "terminal", args = { "--login" }, env = { A = "2", B = "3" } },
        { command = "opencode", args = { "acp" }, env = { A = "1" } }
      )
      t.eq("2", spec.env.A)
      t.eq("3", spec.env.B)
    end)

    t.it("quotes arguments that contain spaces or quotes", function()
      local line = auth.command_line({ command = "a b", args = { "it's", "c$d" } })
      t.eq("'a b' 'it'\\''s' 'c$d'", line)
    end)

    t.it("runs a single terminal method and retries after a successful exit", function()
      local h = harness()
      h.client.auth_methods = {
        { id = "opencode-login", name = "Log in", type = "terminal", args = { "auth", "login" } },
      }
      local retried = 0
      t.truthy(h.auth:login(nil, function()
        retried = retried + 1
      end))
      t.eq(1, #h.terminals)
      t.match("auth", h.terminals[1].command)
      -- The terminal exits successfully: restart the agent, then retry.
      h.terminals[1].opts.on_exit(0)
      t.eq(1, h.terminals.reconnects)
      t.eq(1, #h.deferred)
      h.deferred[1]()
      t.eq(1, retried)
    end)

    t.it("does not retry when the login command fails", function()
      local h = harness()
      h.client.auth_methods = { { id = "m", type = "terminal", args = { "--login" } } }
      local retried = 0
      h.auth:login(nil, function()
        retried = retried + 1
      end)
      h.terminals[1].opts.on_exit(2)
      t.eq(0, retried)
      t.eq(nil, h.terminals.reconnects)
      t.match("exited with 2", h.notices[#h.notices].message)
    end)

    t.it("gives up instead of looping when the agent still refuses", function()
      local h = harness()
      h.client.auth_methods = { { id = "m", type = "terminal", args = { "--login" } } }
      for _ = 1, 5 do
        h.auth:login()
        h.terminals[#h.terminals].opts.on_exit(0)
      end
      -- MAX_LOGIN_ATTEMPTS is 2: further successes stop instead of restarting.
      t.eq(2, h.terminals.reconnects, "restarted more than the attempt limit")
      t.match("gave up", h.notices[#h.notices].message)
      -- A deliberate :Acp login resets the counter.
      h.auth:reset()
      h.auth:login()
      h.terminals[#h.terminals].opts.on_exit(0)
      t.eq(3, h.terminals.reconnects)
    end)

    t.it("cancels an in-flight login without restarting", function()
      local h = harness()
      h.client.auth_methods = { { id = "m", type = "terminal", args = { "--login" } } }
      local retried = 0
      h.auth:login(nil, function()
        retried = retried + 1
      end)
      t.truthy(h.auth:is_running())
      h.auth:cancel()
      t.falsy(h.auth:is_running())
      h.terminals[1].opts.on_exit(0)
      t.eq(nil, h.terminals.reconnects)
      t.eq(0, retried)
    end)

    t.it("reports a terminal that cannot be opened", function()
      local h = harness()
      h.client.auth_methods = { { id = "m", type = "terminal", args = { "--login" } } }
      h.auth.open_terminal = function()
        error("E36: Not enough room")
      end
      h.auth:login()
      t.falsy(h.auth:is_running(), "running flag leaked after a failed terminal")
      t.match("unable to open", h.notices[#h.notices].message)
    end)

    t.it("prefers the remembered editor window for the login terminal", function()
      local origin = vim.api.nvim_get_current_win()
      local editor = vim.api.nvim_create_buf(true, false)
      local editor_win = vim.api.nvim_open_win(editor, true, {
        relative = "editor",
        row = 0,
        col = 0,
        width = math.max(10, vim.o.columns - 2),
        height = math.max(2, vim.o.lines - 4),
        border = "none",
      })
      local original = auth.open_terminal
      local seen_base
      local h = harness()
      h.auth.base_window = function()
        return editor_win
      end
      h.auth.open_terminal = function(command, opts)
        seen_base = opts.base
        return 1
      end
      h.client.auth_methods = { { id = "m", type = "terminal", args = { "--login" } } }
      h.auth:login()
      auth.open_terminal = original
      t.eq(editor_win, seen_base)
      pcall(vim.api.nvim_win_close, editor_win, true)
      pcall(vim.api.nvim_buf_delete, editor, { force = true })
      if vim.api.nvim_win_is_valid(origin) then
        pcall(vim.api.nvim_set_current_win, origin)
      end
    end)

    t.it("falls back to a tab when a split does not fit", function()
      -- The real runner, not the stub: force the horizontal split to fail.
      local original = vim.cmd
      local failed = false
      vim.cmd = function(cmd)
        if cmd == "belowright split" and not failed then
          failed = true
          error("E36: Not enough room")
        end
        return original(cmd)
      end
      local tabs = vim.fn.tabpagenr("$")
      local ok, buf = pcall(auth.open_terminal, "sleep 1", { cwd = "/tmp", on_exit = function() end })
      vim.cmd = original
      local opened = ok and buf or nil
      -- Read the tab count before cleanup: deleting the only buffer of a tab
      -- also closes that tab.
      local tabs_after = vim.fn.tabpagenr("$")
      if opened and vim.api.nvim_buf_is_valid(opened) then
        pcall(vim.api.nvim_buf_delete, opened, { force = true })
      end
      t.truthy(ok, "open_terminal raised: " .. tostring(buf))
      t.truthy(opened, "no terminal buffer was created")
      t.eq(tabs + 1, tabs_after, "a tab was not opened as the fallback")
    end)

    t.it("shows the command and env before launching", function()
      local h = harness()
      h.client.auth_methods = {
        { id = "m", type = "terminal", args = { "--login" }, env = { ACP_LOGIN = "1" } },
      }
      h.auth:login()
      local shown
      for _, notice in ipairs(h.notices) do
        if notice.message:find("running login command", 1, true) then
          shown = notice.message
        end
      end
      t.truthy(shown, "the command was not shown before launch")
      t.match("ACP_LOGIN=1", shown)
      t.match("--login", shown)
    end)

    t.it("calls authenticate for an agent method", function()
      local h = harness()
      h.client.auth_methods = { { id = "agent-login", name = "Log in" } }
      local retried = 0
      h.auth:login(nil, function()
        retried = retried + 1
      end)
      vim.wait(200, function()
        return #h.calls > 0
      end)
      t.eq("agent-login", h.calls[1].method)
      vim.wait(200, function()
        return retried == 1
      end)
      t.eq(1, retried)
    end)

    t.it("offers a picker when several methods exist", function()
      local h = harness()
      h.client.auth_methods = {
        { id = "a", name = "claude.ai" },
        { id = "b", name = "Console", type = "terminal", args = { "login" } },
      }
      local picker = require("acp.ui.picker")
      local original, seen = picker.select, nil
      picker.select = function(opts)
        seen = opts
      end
      local ok, err = pcall(function()
        h.auth:login()
        t.eq(2, #seen.items)
        seen.on_choice(seen.items[2].value)
        t.eq(1, #h.terminals)
      end)
      picker.select = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("explains the absence of a login method instead of naming OpenCode", function()
      local h = harness()
      t.falsy(h.auth:login())
      local message = h.notices[#h.notices].message
      t.falsy(message:find("OpenCode", 1, true))
      t.match("documentation", message)
    end)

    t.it("handles an auth error only when the code matches", function()
      local h = harness()
      h.client.auth_methods = { { id = "m", name = "Log in" } }
      t.falsy(h.auth:require({ code = -32601, message = "auth unsupported" }))
      t.truthy(h.auth:require({ code = -32000, message = "Authentication required" }))
    end)

    t.it("logs out only when the agent declares it", function()
      local h = harness()
      h.client.capabilities = { auth = {} }
      t.falsy(h.auth:can_logout())
      h.client.capabilities = { auth = { logout = {} } }
      t.truthy(h.auth:can_logout())
      t.truthy(h.auth:logout())
      vim.wait(200, function()
        return #h.calls > 0
      end)
      t.truthy(h.calls[1].logout)
      -- Logging out means the next session needs a new login; say so.
      local told
      for _, notice in ipairs(h.notices) do
        if notice.message:find("require logging in again", 1, true) then
          told = notice.message
        end
      end
      t.truthy(told, "logout did not explain that new sessions need a login")
    end)
  end)
end
