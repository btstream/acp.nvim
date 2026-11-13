return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local picker = require("acp.ui.picker")
  local state = require("acp.session.state")
  local agents = require("acp.agents")
  local Options = require("acp.app.options")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local mock = root .. "tests/mock_agent.py"

  local function setup(profile)
    acp.setup({
      agent = profile,
      agents = {
        [profile] = {
          command = "python3",
          args = { mock },
          env = { ACP_MOCK_PROFILE = profile },
          profile = profile,
        },
      },
      permissions = { prompt = "native" },
    })
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.session ~= nil
    end, 20)
    return S
  end

  ---Replace the picker for one call and return what it was given.
  local function capture(fn)
    local captured
    local original = picker.select
    picker.select = function(opts)
      captured = opts
    end
    local ok, err = pcall(fn)
    picker.select = original
    if not ok then
      error(err, 0)
    end
    return captured
  end

  ---A minimal session whose only control source is legacy `modes`.
  local function modes_only_session()
    local s = state.new("s", "/tmp")
    s.profile = agents.get({ profile = "generic" })
    s:configure({
      modes = {
        currentModeId = "ask",
        availableModes = { { id = "ask", name = "Ask" }, { id = "code", name = "Code" } },
      },
    })
    return s
  end

  ---An Options instance wired to a stub client that records RPC calls.
  local function stub_options(session, calls)
    local client = {
      set_mode = function(_, session_id, mode_id)
        calls[#calls + 1] = { method = "set_mode", session_id = session_id, value = mode_id }
        return true, {}
      end,
      set_config_option = function(_, session_id, config_id, value)
        calls[#calls + 1] = { method = "set_config_option", session_id = session_id, id = config_id, value = value }
        return true, {}
      end,
    }
    return Options.new({
      config = function()
        return { ui = { icons = true } }
      end,
      current = function()
        return session
      end,
      client = function()
        return client
      end,
      generation = function()
        return 0
      end,
      ui_current = function()
        return true
      end,
      run = function(key, client_arg, s, fn)
        local task = {
          check = function() end,
          call = function(_, method, ...)
            return client_arg[method](client_arg, ...)
          end,
          status = "running",
        }
        fn(task)
        return task
      end,
      on_changed = function() end,
      notify = function() end,
    })
  end

  t.describe("controller session controls", function()
    t.it("switches pi thinking levels through set_config_option", function()
      local S = setup("pi")
      t.truthy(S.session.controls.model)
      t.truthy(S.session.controls.thinking)
      t.eq(nil, S.session.controls.mode, "pi modes are a duplicate of thought_level")

      local sent = {}
      local original = S.client.set_config_option
      S.client.set_config_option = function(_, session_id, config_id, value)
        sent[#sent + 1] = { id = config_id, value = value }
        return true, {}
      end
      local captured = capture(function()
        controller.pick_model()
      end)
      t.truthy(captured, "no model picker")
      captured.on_choice(captured.items[1].value)
      vim.wait(500)
      t.eq("model", sent[1].id)
      S.client.set_config_option = original
      controller.hide()
    end)

    t.it("refuses a work-mode picker when the agent has no work mode", function()
      local S = setup("pi")
      local captured = capture(function()
        controller.pick_mode()
      end)
      t.eq(nil, captured, "pi must not offer its thinking levels as a work mode")
      controller.hide()
    end)

    t.it("toggles a boolean extra instead of opening a picker", function()
      local S = setup("claude")
      local extra
      for _, control in ipairs(S.session.controls.extras) do
        if control.id == "fast" then
          extra = control
        end
      end
      t.truthy(extra, "the boolean config option is missing")

      local sent = {}
      local original = S.client.set_config_option
      S.client.set_config_option = function(_, session_id, config_id, value)
        sent[#sent + 1] = { id = config_id, value = value }
        return true, {}
      end
      local captured = capture(function()
        S.options:toggle(extra, S.client, S.options.generation(), S.session)
      end)
      vim.wait(500)
      t.eq(nil, captured, "a boolean must not open a second picker")
      t.eq("fast", sent[1].id)
      t.eq(true, sent[1].value)
      S.client.set_config_option = original
      controller.hide()
    end)

    t.it("lists every control in :Acp config", function()
      local S = setup("claude")
      local captured = capture(function()
        controller.pick_config()
      end)
      t.truthy(captured)
      local labels = {}
      for _, item in ipairs(captured.items) do
        labels[#labels + 1] = item.label
      end
      local joined = table.concat(labels, "\n")
      t.match("Model", joined)
      t.match("Mode", joined)
      t.match("Fast mode", joined)
      controller.hide()
    end)

    t.it("uses set_mode when modes are the only source", function()
      local session = modes_only_session()
      local calls = {}
      local options = stub_options(session, calls)
      t.truthy(session.controls.mode)
      t.eq("modes", session.controls.mode.source)
      options:apply(session.controls.mode, "code", options.get_client(), options.generation(), session)
      t.eq("set_mode", calls[1].method)
      t.eq("code", calls[1].value)
      t.eq("code", session.current_mode)
      t.eq("code", session.controls.mode.current)
    end)

    t.it("uses set_config_option when configOptions are the source", function()
      local session = state.new("s", "/tmp")
      session.profile = agents.get({ profile = "opencode" })
      session:configure({
        configOptions = {
          {
            id = "model",
            category = "model",
            type = "select",
            currentValue = "m1",
            options = { { value = "m1", name = "One" }, { value = "m2", name = "Two" } },
          },
        },
      })
      local calls = {}
      local options = stub_options(session, calls)
      options:apply(session.controls.model, "m2", options.get_client(), options.generation(), session)
      t.eq("set_config_option", calls[1].method)
      t.eq("model", calls[1].id)
      t.eq("m2", calls[1].value)
      t.eq("m2", session.controls.model.current)
    end)

    t.it("switches agents and keeps session metadata separate", function()
      local S = setup("opencode")
      local opts = vim.deepcopy(S.config)
      opts.agents.claude = {
        command = "python3",
        args = { mock },
        env = { ACP_MOCK_PROFILE = "claude" },
        profile = "claude",
      }
      controller.setup(opts, { discard_queued = true })
      controller.pick_agent("claude")
      local S2 = controller.state()
      vim.wait(10000, function()
        return S2.session ~= nil
      end, 20)
      t.eq("claude", S2.config.agent)
      t.truthy(S2.session, "the new agent did not create a session")
      t.truthy(S2.session.controls.mode)

      controller.pick_agent("opencode")
      local S3 = controller.state()
      vim.wait(10000, function()
        return S3.session ~= nil
      end, 20)
      t.eq("opencode", S3.config.agent)
      controller.hide()
    end)
    t.it("warns about dropped work when switching agents", function()
      local S = setup("opencode")
      -- Register the second agent before the turn so the switch is the only
      -- thing that tears the session down.
      local opts = vim.deepcopy(S.config)
      opts.agents.claude = {
        command = "python3",
        args = { mock },
        env = { ACP_MOCK_PROFILE = "claude" },
        profile = "claude",
      }
      S.config = opts
      controller.submit("slow", {})
      vim.wait(2000, function()
        local now = controller.state().session
        return now ~= nil and now.status == "running"
      end, 20)
      t.truthy(controller.state().session and controller.state().session.status ~= "idle", "no running turn")

      local notices = {}
      local original = vim.notify
      vim.notify = function(message, level)
        notices[#notices + 1] = { message = tostring(message), level = level }
      end
      local ok, err = pcall(controller.pick_agent, "claude")
      vim.notify = original
      t.truthy(ok, tostring(err))
      local warned
      for _, notice in ipairs(notices) do
        if notice.message:find("dropped", 1, true) then
          warned = notice.message
        end
      end
      t.truthy(warned, "switching agents dropped a running turn without a warning")
      t.match("interrupted 1 running turn", warned)
      controller.hide()
    end)
  end)
end
