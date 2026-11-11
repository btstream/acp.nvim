return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local state = require("acp.session.state")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup(overrides)
    acp.setup(vim.tbl_deep_extend("force", {
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = {},
      permissions = { prompt = "native" },
      layout = { input_height = 5 },
    }, overrides or {}))
    return controller.state()
  end

  -- Snapshot before the explicit Escape: feedkeys("x") itself returns to normal
  -- mode when typeahead runs out, which would make a final mode() check vacuous.
  local function probe(keys)
    local samples, previous = {}, _G._acp_panel_mode_probe
    _G._acp_panel_mode_probe = function(name)
      samples[name] = { mode = vim.fn.mode(), buf = vim.api.nvim_get_current_buf() }
    end
    local sequence = keys .. "<Cmd>lua _G._acp_panel_mode_probe('after')<CR><Esc>"
    local ok, err =
      pcall(vim.api.nvim_feedkeys, vim.api.nvim_replace_termcodes(sequence, true, false, true), "xt", false)
    _G._acp_panel_mode_probe = previous
    if not ok then
      error(err, 0)
    end
    return samples
  end

  t.describe("panel", function()
    t.it("creates both views and focuses the composer", function()
      vim.o.laststatus = 3
      local before_statusline = vim.o.statusline
      local S = setup()
      controller.open()
      t.truthy(S.chat and S.chat:is_visible(), "chat window missing")
      t.truthy(S.input and S.input:is_visible(), "composer missing")
      t.eq("acp_chat", vim.bo[S.chat.buf].filetype)
      t.eq("acp_input", vim.bo[S.input.buf].filetype)
      t.eq(before_statusline, vim.o.statusline, "global statusline was modified")
      t.eq(3, vim.o.laststatus, "laststatus was modified")
      controller.hide()
    end)

    t.it("hides without dropping the session", function()
      local S = setup()
      controller.open()
      vim.wait(4000, function()
        return S.session ~= nil
      end, 20)
      local session = S.session
      controller.hide()
      t.falsy(S.chat.win, "chat window still recorded")
      t.eq(session, S.session, "session was dropped")
    end)

    t.it("never leaves the transcript in insert mode", function()
      local S = setup()
      controller.open()
      controller.focus("chat")
      for _, key in ipairs({ "I", "a", "A", "o", "O", "s", "c", "C", "gR", "gi", "gI" }) do
        local result = probe(key).after
        t.eq("n", result.mode, key .. " entered insert mode")
        t.eq(S.chat.buf, result.buf)
      end
      t.eq("acp: add diagnostics", vim.fn.maparg("R", "n", false, true).desc)
      t.eq("acp: add selection", vim.fn.maparg("S", "n", false, true).desc)
      -- `i` is deliberately bound to the composer instead.
      local result = probe("i").after
      t.eq(S.input.buf, result.buf)
      t.eq("i", result.mode, "composer no longer enters insert mode")
      controller.hide()
    end)

    t.it("leaves insert mode when switching directly from the composer to chat", function()
      local S = setup()
      controller.open()
      vim.api.nvim_set_current_win(S.input.win)
      local samples =
        probe("i<Cmd>lua _G._acp_panel_mode_probe('before'); vim.api.nvim_set_current_win(" .. S.chat.win .. ")<CR>")
      t.eq("i", samples.before.mode)
      t.eq("n", samples.after.mode)
      t.eq(S.chat.buf, samples.after.buf)
      controller.hide()
    end)

    t.it("leaves insert mode when the current window switches buffers to chat", function()
      local S = setup()
      controller.open()
      local scratch = vim.api.nvim_create_buf(false, true)
      local win =
        vim.api.nvim_open_win(scratch, true, { relative = "editor", row = 0, col = 0, width = 40, height = 5 })
      local samples =
        probe("i<Cmd>lua _G._acp_panel_mode_probe('before'); vim.api.nvim_set_current_buf(" .. S.chat.buf .. ")<CR>")
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(scratch, { force = true })
      t.eq("i", samples.before.mode)
      t.eq("n", samples.after.mode)
      t.eq(S.chat.buf, samples.after.buf)
      controller.hide()
    end)

    t.it("ignores i when the composer focus mapping is disabled", function()
      local S = setup({ keymaps = { chat = { focus_input = false } } })
      controller.open()
      controller.focus("chat")
      t.eq("<Nop>", vim.fn.maparg("i", "n", false, true).rhs)
      local result = probe("i").after
      t.eq("n", result.mode)
      t.eq(S.chat.buf, result.buf)
      controller.hide()
    end)

    t.it("automatically inserts on direct composer entry and stops on direct window exit", function()
      local S = setup()
      controller.open()
      local editor_buf = vim.api.nvim_create_buf(false, true)
      local editor =
        vim.api.nvim_open_win(editor_buf, true, { relative = "editor", row = 0, col = 0, width = 40, height = 5 })
      local entered = probe("<Cmd>lua vim.api.nvim_set_current_win(" .. S.input.win .. ")<CR>").after
      t.eq(S.input.buf, entered.buf)
      t.eq("i", entered.mode)
      vim.api.nvim_set_current_win(editor)
      local samples = probe(
        "<Cmd>lua vim.api.nvim_set_current_win("
          .. S.input.win
          .. ")<CR>"
          .. "<Cmd>lua _G._acp_panel_mode_probe('before'); vim.api.nvim_set_current_win("
          .. editor
          .. ")<CR>"
      )
      t.eq("i", samples.before.mode)
      t.eq(editor_buf, samples.after.buf)
      t.eq("n", samples.after.mode)
      vim.api.nvim_win_close(editor, true)
      vim.api.nvim_buf_delete(editor_buf, { force = true })
      controller.hide()
    end)

    t.it("automatically inserts and stops when switching the current window's buffer", function()
      local S = setup()
      controller.open()
      local scratch = vim.api.nvim_create_buf(false, true)
      local win =
        vim.api.nvim_open_win(scratch, true, { relative = "editor", row = 0, col = 0, width = 40, height = 5 })
      local entered = probe("<Cmd>lua vim.api.nvim_set_current_buf(" .. S.input.buf .. ")<CR>").after
      t.eq(S.input.buf, entered.buf)
      t.eq("i", entered.mode)
      local samples =
        probe("i<Cmd>lua _G._acp_panel_mode_probe('before'); vim.api.nvim_set_current_buf(" .. scratch .. ")<CR>")
      t.eq("i", samples.before.mode)
      t.eq(scratch, samples.after.buf)
      t.eq("n", samples.after.mode)
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(scratch, { force = true })
      controller.hide()
    end)

    t.it("rejects programmatic insert entry even if modifiable is temporarily enabled", function()
      local S = setup()
      controller.open()
      controller.focus("chat")
      local entered = 0
      local autocmd = vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = S.chat.buf,
        callback = function()
          entered = entered + 1
        end,
      })
      vim.bo[S.chat.buf].modifiable = true
      local result = probe("<Cmd>startinsert<CR>").after
      vim.bo[S.chat.buf].modifiable = false
      vim.api.nvim_del_autocmd(autocmd)
      t.eq(1, entered, "test did not exercise InsertEnter")
      t.eq("n", result.mode)
      t.eq(S.chat.buf, result.buf)
      controller.hide()
    end)

    t.it("keeps configured chat actions ahead of the insertion fallback", function()
      local S = setup({ keymaps = { chat = { focus_input = { "a", "<C-s>" } } } })
      controller.open()
      controller.focus("chat")
      local result = probe("a").after
      t.eq(S.input.buf, result.buf)
      t.eq("i", result.mode)
      controller.hide()
    end)

    t.it("does not stop the composer after another InsertEnter handler redirects focus", function()
      local S = setup()
      controller.open()
      controller.focus("chat")
      local autocmd = vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = S.chat.buf,
        callback = function()
          vim.api.nvim_set_current_win(S.input.win)
        end,
      })
      vim.bo[S.chat.buf].modifiable = true
      local result = probe("<Cmd>startinsert<CR>").after
      vim.bo[S.chat.buf].modifiable = false
      vim.api.nvim_del_autocmd(autocmd)
      t.eq(S.input.buf, result.buf)
      t.eq("i", result.mode)
      controller.hide()
    end)

    t.it("toggle restores the views", function()
      local S = setup()
      controller.open()
      controller.toggle()
      t.falsy(S.chat:is_visible())
      controller.toggle()
      t.truthy(S.chat:is_visible())
      controller.hide()
    end)

    t.it("hides signs and numbers with a single-space statuscolumn", function()
      local S = setup()
      controller.open()
      for _, pair in ipairs({ { "chat", S.chat.win }, { "composer", S.input.win } }) do
        local win = pair[2]
        t.eq(
          " ",
          vim.api.nvim_get_option_value("statuscolumn", { win = win }),
          pair[1] .. " should use a single-space statuscolumn"
        )
        t.eq("no", vim.api.nvim_get_option_value("signcolumn", { win = win }))
      end
      controller.hide()
    end)

    t.it("keeps every chrome element local to its window", function()
      local S = setup()
      controller.open()
      local chat_bar = vim.api.nvim_get_option_value("winbar", { win = S.chat.win })
      local input_bar = vim.api.nvim_get_option_value("winbar", { win = S.input.win })
      t.truthy(#chat_bar > 0)
      t.truthy(#input_bar > 0)
      controller.hide()
    end)

    t.it("survives laststatus transitions while open", function()
      local S = setup()
      local original = vim.o.laststatus
      controller.open()
      for _, status in ipairs({ 0, 2, 3 }) do
        vim.o.laststatus = status
        controller.open()
        t.truthy(S.input:is_visible())
      end
      vim.o.laststatus = original
      controller.hide()
    end)

    t.it("renders composer context chips in the winbar", function()
      local S = setup()
      controller.open()
      vim.wait(4000, function()
        return S.session ~= nil
      end, 20)
      S.input:add_attachment({ kind = "file", label = "main.lua", path = "/tmp/main.lua" })
      local bar = vim.api.nvim_get_option_value("winbar", { win = S.input.win })
      local res = vim.api.nvim_eval_statusline(bar, {
        winid = S.input.win,
        maxwidth = vim.api.nvim_win_get_width(S.input.win),
        use_winbar = true,
      })
      t.match("main%.lua", res.str)
      controller.hide()
    end)

    t.it("keeps the composer winbar within the window width", function()
      local S = setup()
      controller.open()
      for _, width in ipairs({ 24, 28, 42, 60 }) do
        vim.api.nvim_win_set_width(S.input.win, width)
        local win_width = vim.api.nvim_win_get_width(S.input.win)
        local bar = vim.api.nvim_get_option_value("winbar", { win = S.input.win })
        local res = vim.api.nvim_eval_statusline(bar, {
          winid = S.input.win,
          maxwidth = win_width,
          use_winbar = true,
        })
        t.truthy(res.width <= win_width, string.format("winbar overflows at %d: %d", win_width, res.width))
        t.falsy(res.str:find("<", 1, true), "winbar shows a truncation marker at width " .. win_width)
      end
      controller.hide()
    end)

    t.it("exposes clickable model and mode regions", function()
      local S = setup()
      controller.open()
      vim.wait(4000, function()
        return S.session ~= nil
      end, 20)
      -- The winbar is an expression; inspect what it actually renders.
      local rendered = controller.composer_bar(S.input.win)
      t.match("AcpPickModel", rendered)
      t.match("AcpPickMode", rendered)
      t.eq("function", type(_G.AcpPickModel))
      t.eq("function", type(_G.AcpPickMode))
      controller.hide()
    end)

    t.it("shows idle, running and waiting states in the toolbar", function()
      local S = setup()
      controller.open()
      local toolbar = require("acp.ui.toolbar")
      local ic = require("acp.ui.icons").get(true)
      local idle = toolbar.render({ status = "idle", icons = true }, 60)
      local running = toolbar.render({ status = "running", icons = true, spinner = "*" }, 60)
      local waiting = toolbar.render({ status = "running", icons = true, waiting = true }, 60)
      t.match(vim.pesc(ic.status_idle), idle)
      t.match(vim.pesc("*"), running)
      t.match(vim.pesc(ic.status_waiting), waiting)
      controller.hide()
    end)

    t.it("keeps the transcript read-only after updates", function()
      local S = setup()
      local session = state.new("s9", "/tmp")
      S.session = session
      S.chat:set_session(session)
      session:add_local_user("hello")
      S.chat:render()
      t.falsy(vim.bo[S.chat.buf].modifiable)
      S.session = nil
    end)
  end)
end
