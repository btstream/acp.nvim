return function(t)
  local toolbar = require("acp.ui.toolbar")
  local config = require("acp.config")

  t.describe("audit regressions", function()
    t.it("keeps internal session navigation ahead of text mappings", function()
      local browser = require("acp.ui.session_picker").open({
        sessions = { { sessionId = "aaa", title = "First" }, { sessionId = "bbb", title = "Old" } },
      })
      local maps = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(browser.buf, "n")) do
        maps[map.lhs] = map
      end
      t.eq("next", maps.j.desc)
      t.eq("previous", maps.k.desc)
      t.eq("close", maps.q.desc)
      maps.O.callback()
      local lines = table.concat(browser.symbols(), "\n")
      t.truthy(lines:find("Old", 1, true))
      t.eq(nil, lines:find("First", 1, true))
      maps.q.callback()
    end)

    t.it("keeps the session browser open during floating delete confirmation", function()
      local select = vim.ui.select
      local confirmation, complete
      vim.ui.select = function(_, _, cb)
        complete = cb
        confirmation = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
          relative = "editor",
          row = 1,
          col = 1,
          width = 20,
          height = 2,
          style = "minimal",
        })
      end
      local browser
      local ok, err = pcall(function()
        browser = require("acp.ui.session_picker").open({
          sessions = { { sessionId = "one", title = "First" } },
          can_delete = true,
        })
        browser.delete_current()
        t.truthy(vim.api.nvim_win_is_valid(browser.win))
        vim.api.nvim_win_close(confirmation, true)
        complete("Cancel")
        vim.wait(30)
        t.truthy(vim.api.nvim_win_is_valid(browser.win))
      end)
      vim.ui.select = select
      if confirmation and vim.api.nvim_win_is_valid(confirmation) then
        vim.api.nvim_win_close(confirmation, true)
      end
      if browser and vim.api.nvim_win_is_valid(browser.win) then
        vim.api.nvim_win_close(browser.win, true)
      end
      if not ok then
        error(err)
      end
    end)

    t.it("ships syntactically valid Lua examples", function()
      for _, path in ipairs({ "examples/minimal/init.lua", "examples/edgy/init.lua" }) do
        local chunk, err = loadfile(path)
        t.truthy(chunk, err)
      end
    end)
    t.it("keeps the log rotation counter out of the global namespace", function()
      local original = _G.lines_since_check
      _G.lines_since_check = nil
      require("acp.log").setup({})
      local leaked = _G.lines_since_check
      _G.lines_since_check = original
      t.eq(nil, leaked)
    end)
    t.it("honours the configured close key in both panel buffers", function()
      local controller = require("acp.controller")
      -- `close_panel` exists in both views, so it has to be set in both.
      controller.setup({ keymaps = { input = { close_panel = "Q" }, chat = { close_panel = "Q" } } })
      local state = controller.state()
      state.connection = "starting" -- Exercise the UI without spawning an agent.
      controller.open()
      for _, view in ipairs({ state.chat, state.input }) do
        local found = false
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
          if map.lhs == "Q" then
            found = true
          end
        end
        t.truthy(found)
      end
      controller.hide()
      state.connection = "stopped"
    end)

    t.it("restores either missing view into the same panel column", function()
      -- Like spec_layout_sizing, isolate geometry from other specs' windows.
      local script = string.format(
        [[
        vim.opt.runtimepath:append(%q)
        local controller = require("acp.controller")
        local config = require("acp.config")
        controller.setup({})
        local state = controller.state()
        state.connection = "starting"
        controller.open()
        for _, name in ipairs({ "input", "chat" }) do
          vim.api.nvim_win_close(state[name].win, true)
          controller.open()
          local chat_pos = vim.api.nvim_win_get_position(state.chat.win)
          local input_pos = vim.api.nvim_win_get_position(state.input.win)
          assert(chat_pos[2] == input_pos[2], "different panel columns")
          assert(chat_pos[1] < input_pos[1], "chat not above input")
          assert(config.panel_width(state.config, vim.o.columns) == vim.api.nvim_win_get_width(state.input.win), "wrong width")
          assert(vim.api.nvim_win_get_height(state.input.win) == 8, "wrong input height")
        end
        vim.cmd("qa!")
      ]],
        vim.fn.getcwd()
      )
      local tmp = vim.fn.tempname() .. ".lua"
      vim.fn.writefile(vim.split(script, "\n"), tmp)
      local output = vim.fn.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", tmp })
      local status = vim.v.shell_error
      vim.fn.delete(tmp)
      t.eq(0, status, output)
    end)

    t.it("replaces cached history when loading the same session again", function()
      local controller = require("acp.controller")
      controller.setup({})
      local state = controller.state()
      state.connection = "ready"
      state.client = {
        has_session_capability = function()
          return false
        end,
        load_session = function(_, id)
          controller.on_client_event("session_update", {
            sessionId = id,
            update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "History" } },
          })
          return true, {}
        end,
        shutdown = function() end,
      }
      controller.load_session("audit-history")
      local first = state.chat:transcript()
      controller.load_session("audit-history")
      t.eq(first, state.chat:transcript())
      t.eq(1, #state.session.blocks)
      state.client = nil
    end)

    t.it("disables ordinary request timeouts when configured as zero", function()
      local client = require("acp.protocol.client").new({
        agent = {},
        cwd = vim.fn.getcwd(),
        limits = { request_timeout = 0 },
      })
      local called = false
      client.request = function(_, method, _, timeout)
        called = true
        t.eq("session/new", method)
        t.eq(nil, timeout)
        return true, { sessionId = "test" }
      end
      client:new_session(vim.fn.getcwd())
      t.truthy(called)
    end)

    t.it("renders legacy winbars without unsupported highlight syntax", function()
      local original = vim.fn.has
      vim.fn.has = function(feature)
        return feature == "nvim-0.12" and 0 or original(feature)
      end
      local ok, err = pcall(function()
        for _, bar in ipairs({
          toolbar.render({ mode = "Build", model = "Test", status = "idle" }, 42),
          toolbar.chat_title({ agent = "test", title = "Title", pending_new = true }, 42),
        }) do
          t.eq(nil, bar:find("%$", 1, true))
          local result = vim.api.nvim_eval_statusline(bar, { maxwidth = 42, use_winbar = true })
          t.truthy(#result.str > 0)
        end
      end)
      vim.fn.has = original
      if not ok then
        error(err)
      end
    end)

    t.it("escapes unknown mode names exactly once", function()
      local bar = toolbar.render({ mode = "Custom 50%", model = "Test", status = "idle" }, 80)
      local result = vim.api.nvim_eval_statusline(bar, { maxwidth = 80, use_winbar = true })
      t.truthy(result.str:find("Custom 50%", 1, true))
      t.eq(nil, result.str:find("50%%", 1, true))
    end)

    t.it("drops an oversized mode badge instead of overflowing", function()
      local bar = toolbar.render({ mode = string.rep("custom", 20), status = "idle" }, 8)
      local result = vim.api.nvim_eval_statusline(bar, { maxwidth = 1000, use_winbar = true })
      t.truthy(result.width <= 8)
    end)

    t.it("reports invalid width bounds as configuration errors", function()
      for _, bounds in ipairs({ { min_width = "bad" }, { max_width = "bad" } }) do
        local ok, err = pcall(config.validate, config.merge(config.defaults, { layout = bounds }))
        t.eq(false, ok)
        t.truthy(tostring(err):find("acp.nvim: layout.", 1, true))
      end
    end)

    t.it("does not retain stderr when its retention limit is zero", function()
      local original = vim.fn.jobstart
      local callbacks
      vim.fn.jobstart = function(_, opts)
        callbacks = opts
        return 123
      end
      local ok, err = pcall(function()
        local process = require("acp.transport.process").spawn({
          command = "mock",
          stderr_keep_bytes = 0,
          on_line = function() end,
          on_exit = function() end,
        })
        callbacks.on_stderr(123, { "secret diagnostic" })
        t.eq("", process:stderr())
      end)
      vim.fn.jobstart = original
      if not ok then
        error(err)
      end
    end)

    t.it("rolls back the first split when the second split fails", function()
      local layout = require("acp.layout")
      layout.setup(config.merge(config.defaults, {}))
      local before = #vim.api.nvim_list_wins()
      local equalalways = vim.o.equalalways
      local original = vim.cmd
      vim.cmd = function(cmd)
        if cmd == "belowright split" then
          error("simulated split failure")
        end
        return original(cmd)
      end
      local buf = vim.api.nvim_create_buf(false, true)
      local ok, err = pcall(function()
        local chat, input = layout.create_panel(buf, buf)
        t.eq(nil, chat)
        t.eq(nil, input)
        t.eq(before, #vim.api.nvim_list_wins())
        t.eq(equalalways, vim.o.equalalways)
      end)
      vim.cmd = original
      vim.api.nvim_buf_delete(buf, { force = true })
      if not ok then
        error(err)
      end
    end)

    t.it("does not warn for the default nvi mouse setting", function()
      local controller = require("acp.controller")
      local mouse, notify = vim.o.mouse, vim.notify
      local state = controller.state()
      local hint = state.click_hint_shown
      local messages = {}
      vim.o.mouse = "nvi"
      vim.notify = function(message)
        messages[#messages + 1] = message
      end
      state.click_hint_shown = false
      local ok, err = pcall(function()
        controller.setup({})
        vim.wait(30)
        for _, message in ipairs(messages) do
          t.eq(nil, message:find("not clickable", 1, true))
        end
      end)
      vim.o.mouse, vim.notify = mouse, notify
      state.click_hint_shown = hint
      if not ok then
        error(err)
      end
    end)
  end)
end
