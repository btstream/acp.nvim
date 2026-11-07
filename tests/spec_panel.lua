return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local state = require("acp.session.state")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup()
    acp.setup({
      agent = "opencode",
      agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
      ui = {},
      permissions = { prompt = "native" },
      layout = { input_height = 5 },
    })
    return controller.state()
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

    t.it("toggle restores the views", function()
      local S = setup()
      controller.open()
      controller.toggle()
      t.falsy(S.chat:is_visible())
      controller.toggle()
      t.truthy(S.chat:is_visible())
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
      local idle = toolbar.render({ status = "idle" }, 60)
      local running = toolbar.render({ status = "running" }, 60)
      local waiting = toolbar.render({ status = "running", waiting = true }, 60)
      t.match("Idle", idle)
      t.match("Running", running)
      t.match("Waiting", waiting)
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
