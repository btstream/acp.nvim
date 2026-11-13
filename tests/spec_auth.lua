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
      reconnect = function()
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
      t.truthy(auth.is_auth_error({ code = -1, data = { code = -32000 } }))
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

    t.it("prefers the command carried by _meta", function()
      local spec = auth.terminal_spec({
        id = "m",
        _meta = { ["terminal-auth"] = { command = "claude", args = { "login" } } },
      }, { command = "claude-agent-acp", args = {} })
      t.eq("claude", spec.command)
      t.eq({ "login" }, spec.args)
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
      -- The terminal exits successfully: reconnect, then retry once ready.
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
    end)
  end)
end
