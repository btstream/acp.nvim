return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup(cwd)
    acp.setup({
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = { session_picker = "internal" },
      cwd = cwd,
    })
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.session ~= nil
    end, 20)
    -- Let the title refresh that follows session creation settle, so it cannot
    -- be confused with the requests made by the test itself.
    vim.wait(1500)
    return S
  end

  ---Replace the picker backends with recorders.
  local function capture_pickers()
    local calls = {}
    local snacks = require("acp.ui.session_snacks")
    local internal = require("acp.ui.session_picker")
    local orig_snacks = snacks.open
    local orig_internal = internal.open
    snacks.open = function(opts)
      calls[#calls + 1] = { backend = "snacks", opts = opts }
      return true
    end
    internal.open = function(opts)
      calls[#calls + 1] = { backend = "internal", opts = opts }
    end
    return calls, function()
      snacks.open = orig_snacks
      internal.open = orig_internal
    end
  end

  t.describe("session listing scope", function()
    t.it("uses the editor cwd for the query", function()
      local S = setup()
      local captured, restore = capture_pickers()

      controller.pick_session()
      vim.wait(6000, function()
        return #captured > 0
      end, 20)
      restore()

      t.truthy(captured[1], "no picker was shown")
      -- The mock agent only returns sessions whose cwd matches, so seeing the
      -- session created for this directory proves the cwd was passed through.
      local ids = {}
      for _, session in ipairs(captured[1].opts.sessions) do
        ids[session.sessionId] = true
      end
      t.truthy(ids[S.session.id], "the active session is missing from the list")
      controller.hide()
    end)

    t.it("creates sessions in the editor cwd", function()
      local S = setup()
      t.eq(vim.fn.getcwd(), S.session.cwd, "the session cwd must match Neovim's cwd")
      controller.hide()
    end)

    t.it("falls back to an unscoped list when the directory has none", function()
      -- The mock agent returns nothing for this directory but answers an
      -- unscoped query with every session it knows.
      vim.env.ACP_EMPTY_SCOPE_DIR = root
      local S = setup(root)
      local captured, restore = capture_pickers()

      controller.pick_session()
      vim.wait(6000, function()
        return #captured > 0
      end, 20)
      restore()

      t.truthy(captured[1], "no picker was shown")
      local ids = {}
      for _, session in ipairs(captured[1].opts.sessions) do
        ids[session.sessionId] = true
      end
      -- The unscoped fallback brings in sessions from other directories.
      t.truthy(ids["sess_elsewhere"], "the unscoped fallback was not used")
      t.truthy(#captured[1].opts.sessions > 1, "expected more than one session")
      vim.env.ACP_EMPTY_SCOPE_DIR = nil
      controller.hide()
    end)

    t.it("reports an empty result only when the agent has nothing at all", function()
      local S = setup()
      local captured, restore = capture_pickers()
      local original = S.client.list_sessions
      S.client.list_sessions = function(_, cwd)
        return true, { sessions = {} }
      end

      controller.pick_session()
      -- Give the request time to finish; the picker must not open.
      vim.wait(2500, function()
        return false
      end, 50)
      restore()
      S.client.list_sessions = original

      t.eq(0, #captured, "a picker should not open for an empty list")
      controller.hide()
    end)

    t.it("loads a session with the session's own cwd", function()
      local S = setup()
      local used
      local original = S.client.load_session
      S.client.load_session = function(_, session_id, cwd)
        used = cwd
        return original(S.client, session_id, cwd)
      end
      -- A session stored under another directory, as reported by session/list.
      S.session_cwds["sess_other"] = "/some/other/project"
      controller.load_session("sess_other")
      vim.wait(6000, function()
        return used ~= nil
      end, 20)
      S.client.load_session = original
      t.eq("/some/other/project", used, "loading must use the session's own directory")
      controller.hide()
    end)

    t.it("sends an object, not an array, for an unscoped request", function()
      local client_mod = require("acp.protocol.client")
      local inst = client_mod.new({
        agent = { command = "true" },
        cwd = "/tmp",
        client_capabilities = {},
        on_event = function() end,
      })
      local sent
      inst.rpc = {
        request = function(_, _, params)
          sent = params
          return 1
        end,
      }
      -- list_sessions yields, so drive it through a coroutine.
      local async = require("acp.async")
      local finished = false
      async.run(function()
        inst:list_sessions(nil)
        finished = true
      end)
      vim.wait(2000, function()
        return finished
      end, 20)
      t.truthy(sent, "no request was made")
      t.eq("{}", vim.json.encode(sent), "empty params must encode as an object")
    end)
  end)
end
