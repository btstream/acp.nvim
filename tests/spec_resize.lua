return function(t)
  local Chat = require("acp.ui.chat")
  local State = require("acp.session.state")
  local config = require("acp.config")

  local function fixture(fn)
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    local cfg = config.validate(config.merge(config.defaults, {}))
    local chat = Chat.new({ config = cfg })
    -- Other specs may leave edgy active. These are isolated view tests; do not
    -- let a third-party filetype rule turn the fixture's float into a split.
    vim.bo[chat.buf].filetype = "acp_resize_test"
    chat.win = vim.api.nvim_open_win(chat.buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 68,
      height = 12,
      style = "minimal",
    })
    vim.wo[chat.win].wrap = false
    vim.wo[chat.win].scrolloff = 0
    local session = State.new("resize", "/tmp/opencode")
    session:track_changes()
    session:append({
      id = "table",
      kind = "agent",
      text = "| 场景 | 行为 |\n|---|---|\n"
        .. string.rep("| 保存文件 | `enew() + delete` keeps nvim running without losing the current buffer |\n", 5),
    })
    session:append({ id = "reading", kind = "agent", text = string.rep("Reading line.\n", 40) })
    session:append({ id = "tail", kind = "agent", text = "Tail.\n" })
    chat:set_session(session)
    local ok, err = pcall(fn, chat, session, cfg)
    if chat:is_visible() then
      pcall(vim.api.nvim_win_close, chat.win, true)
    end
    chat:destroy()
    vim.o.columns, vim.o.lines = columns, lines
    if not ok then
      error(err, 0)
    end
  end

  local function resize(chat, width, event)
    vim.api.nvim_win_set_config(chat.win, { width = width })
    vim.api.nvim_exec_autocmds(event or "WinResized", { modeline = false })
  end

  local function settled(chat, width)
    t.truthy(
      vim.wait(600, function()
        return chat.width == width - 2 and chat.resize_timer == nil
      end, 5),
      "resize did not settle at width " .. width
    )
  end

  local function marks(chat)
    local out = {}
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, vim.api.nvim_get_namespaces().acp_chat, 0, -1, { details = true }))
    do
      local d = mark[4]
      out[#out + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group, d.conceal }
    end
    table.sort(out, function(a, b)
      return vim.inspect(a) < vim.inspect(b)
    end)
    return out
  end

  t.describe("chat resize", function()
    t.it("reflows an idle transcript on WinResized without a new session update", function()
      fixture(function(chat, session, cfg)
        local version, previous = session.version, chat:transcript()
        resize(chat, 36)
        settled(chat, 36)
        t.eq(version, session.version)
        t.falsy(previous == chat:transcript(), "table should wrap to the new width")
        local reference = Chat.new({ config = cfg })
        reference.width = chat.width
        reference:set_session(session)
        local ok, err = pcall(function()
          t.eq(reference:transcript(), chat:transcript())
          t.eq(reference.meta, chat.meta)
          t.eq(marks(reference), marks(chat))
        end)
        reference:destroy()
        if not ok then
          error(err)
        end
      end)
    end)

    t.it("also handles editor-wide VimResized events", function()
      fixture(function(chat)
        resize(chat, 44, "VimResized")
        settled(chat, 44)
      end)
    end)

    t.it("debounces a burst of drag events into one layout pass", function()
      fixture(function(chat)
        local calls, original = 0, chat.render
        chat.render = function(self, ...)
          calls = calls + 1
          return original(self, ...)
        end
        for width = 60, 38, -2 do
          resize(chat, width)
        end
        vim.wait(25)
        t.eq(0, calls)
        settled(chat, 38)
        vim.wait(130)
        t.eq(1, calls, "only the last drag width should be rendered")
      end)
    end)

    t.it("skips unrelated resize events and height-only changes", function()
      fixture(function(chat)
        local original_cache, calls, original = chat.cache, 0, chat.render
        chat.render = function(self, ...)
          calls = calls + 1
          return original(self, ...)
        end
        vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
        vim.api.nvim_win_set_config(chat.win, { height = 8 })
        vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
        vim.wait(160)
        t.eq(0, calls)
        t.truthy(original_cache == chat.cache)
        t.eq(nil, chat.resize_timer)
        t.eq(vim.api.nvim_buf_line_count(chat.buf), vim.api.nvim_win_get_cursor(chat.win)[1])
      end)
    end)

    t.it("does not postpone pending reflow for repeated unrelated window events", function()
      fixture(function(chat)
        resize(chat, 36)
        local timer = chat.resize_timer
        for _ = 1, 20 do
          vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
        end
        t.truthy(timer == chat.resize_timer, "unchanged pending width must keep the original deadline")
        settled(chat, 36)
      end)
    end)

    t.it("cancels pending reflow when a drag returns to the rendered width", function()
      fixture(function(chat)
        local cache = chat.cache
        resize(chat, 38)
        resize(chat, 68)
        vim.wait(160)
        t.eq(66, chat.width)
        t.eq(nil, chat.resize_timer)
        t.truthy(cache == chat.cache)
      end)
    end)

    t.it("preserves cursor and viewport block anchors without a new-output badge", function()
      fixture(function(chat)
        local old_start = chat.line_starts.reading
        vim.api.nvim_win_call(chat.win, function()
          vim.fn.winrestview({ lnum = old_start + 10, col = 3, topline = old_start + 6 })
        end)
        chat.follow, chat.pending_new = false, false
        local notifications = 0
        chat.on_pending_new = function()
          notifications = notifications + 1
        end
        resize(chat, 36)
        settled(chat, 36)
        local start = chat.line_starts.reading
        local view = vim.api.nvim_win_call(chat.win, vim.fn.winsaveview)
        t.falsy(old_start == start, "the preceding table must change height")
        t.eq(start + 10, view.lnum)
        t.eq(start + 6, view.topline)
        t.eq(3, view.col)
        t.eq(false, chat.follow)
        t.eq(false, chat.pending_new)
        t.eq(0, notifications)
      end)
    end)

    t.it("keeps following the latest output after reflow", function()
      fixture(function(chat)
        resize(chat, 36)
        settled(chat, 36)
        t.eq(true, chat.follow)
        t.eq(vim.api.nvim_buf_line_count(chat.buf), vim.api.nvim_win_get_cursor(chat.win)[1])
        t.eq(false, chat.pending_new)
      end)
    end)

    t.it("preserves an existing new-output badge while reading history", function()
      fixture(function(chat)
        chat:scroll_to_top()
        chat.pending_new = true
        local notifications = 0
        chat.on_pending_new = function()
          notifications = notifications + 1
        end
        resize(chat, 36)
        settled(chat, 36)
        t.eq(true, chat.pending_new)
        t.eq(false, chat.follow)
        t.eq(0, notifications)
      end)
    end)

    t.it("does not delay stream ticks and retains a real new-output badge", function()
      fixture(function(chat, session)
        chat:scroll_to_top()
        resize(chat, 36)
        session:append_text("agent", "New streamed content.\n", "stream")
        local width_at_content, original = nil, chat.render
        chat.render = function(self, force, reason)
          local result = original(self, force, reason)
          if reason == "content" then
            width_at_content = self.width
          end
          return result
        end
        chat:schedule_render()
        t.truthy(
          vim.wait(80, function()
            return width_at_content ~= nil
          end, 2),
          "content must render before resize debounce finishes"
        )
        t.eq(66, width_at_content, "stream ticks should reuse the last settled width during a drag")
        t.truthy(chat:transcript():find("New streamed content.", 1, true))
        settled(chat, 36)
        t.eq(true, chat.pending_new)
        t.eq(false, chat.follow)
        t.truthy(chat:transcript():find("New streamed content.", 1, true))
      end)
    end)

    t.it("does not render hidden windows and uses their actual width on reopen", function()
      fixture(function(chat)
        resize(chat, 36)
        local closed = chat.win
        vim.api.nvim_win_close(closed, true)
        chat.win = nil
        vim.wait(150)
        t.eq(nil, chat.resize_timer)
        t.eq(66, chat.width)
        chat.win = vim.api.nvim_open_win(chat.buf, false, {
          relative = "editor",
          row = 0,
          col = 0,
          width = 42,
          height = 12,
          style = "minimal",
        })
        chat:render(true)
        t.eq(40, chat.width)
      end)
    end)

    t.it("discards resize and stream callbacks after destroying the view", function()
      fixture(function(chat)
        resize(chat, 36)
        local resize_timer = chat.resize_timer
        chat:schedule_render()
        local render_timer = chat.render_timer
        local calls = 0
        chat.render = function()
          calls = calls + 1
        end
        vim.api.nvim_win_close(chat.win, true)
        chat:destroy()
        vim.wait(150)
        t.eq(0, calls)
        t.eq(nil, chat.resize_timer)
        t.eq(nil, chat.render_timer)
        t.truthy(resize_timer:is_closing())
        t.truthy(render_timer:is_closing())
      end)
    end)

    t.it("cancels old reflow when switching sessions during resize", function()
      fixture(function(chat)
        resize(chat, 36)
        local timer = chat.resize_timer
        local session = State.new("other-session", "/tmp/opencode")
        session:track_changes()
        session:append({ id = "new", kind = "agent", text = "New session." })
        chat:set_session(session)
        t.eq(nil, chat.resize_timer)
        t.truthy(timer:is_closing())
        t.eq(34, chat.width)
        vim.wait(150)
        t.truthy(chat:transcript():find("New session.", 1, true))
        t.eq(false, chat.pending_new)
      end)
    end)
  end)
end
