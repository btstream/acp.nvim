return function(t)
  local Chat = require("acp.ui.chat")
  local Config = require("acp.config")
  local State = require("acp.session.state")
  local viewport = require("acp.ui.viewport")

  local function ready(chat)
    t.truthy(
      vim.wait(5000, function()
        local committed = not chat.layout_job
          and not chat.commit_job
          and not chat.needs_render
          and chat.render_version == chat.session.version
        -- Headless vim.wait does not paint frames like an attached UI. Let the
        -- post-redraw tail correction observe real screen positions here too.
        if committed then
          vim.cmd("redraw")
        end
        return committed and not chat.tail_follow_pending
      end, 1),
      "tail render did not settle"
    )
    vim.cmd("redraw")
  end

  local function fixture(overrides, fn)
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 120, 40
    local cfg = Config.validate(Config.merge(Config.defaults, overrides or {}))
    local chat = Chat.new({ config = cfg })
    -- Other specs may leave edgy's acp_chat rule active.
    vim.bo[chat.buf].filetype = "acp_tail_test"
    local win = vim.api.nvim_open_win(
      chat.buf,
      true,
      { relative = "editor", row = 0, col = 0, width = 60, height = 14, zindex = 300 }
    )
    chat.win = win
    vim.wo[win].winbar = "Transcript"
    vim.wo[win].scrolloff = 2
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    local s = State.new("tail", "/tmp")
    s:track_changes()
    local ok, err = pcall(fn, chat, s, win)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    chat:destroy()
    vim.o.columns, vim.o.lines = columns, lines
    if not ok then
      error(err, 0)
    end
  end

  local function at_bottom(chat)
    local info = vim.fn.getwininfo(chat.win)[1]
    local last = #chat.lines_cache
    t.eq("", chat.lines_cache[last], "the existing trailing blank line was lost")
    local height = vim.api.nvim_win_text_height(chat.win, { start_row = 0, end_row = last - 1 }).all
    local expected = info.winrow + info.winbar + math.min(info.height, height) - 1
    t.eq(
      expected,
      vim.fn.screenpos(chat.win, last, 1).row,
      "short content was not top-aligned or overflowing content lost its tail anchor"
    )
    t.truthy(chat.follow, "programmatic reflow disabled following")
  end

  local function at_top(chat)
    local info = vim.fn.getwininfo(chat.win)[1]
    t.eq(info.winrow + info.winbar, vim.fn.screenpos(chat.win, 1, 1).row)
    local view = vim.api.nvim_win_call(chat.win, vim.fn.winsaveview)
    t.eq(1, view.topline)
    t.eq(0, view.topfill)
    t.eq(0, view.skipcol)
    t.eq(0, chat.tail_padding)
  end

  t.describe("transcript tail anchoring", function()
    for _, mode in ipairs({ "incremental", "paged", "chunked" }) do
      t.it("keeps Thought and its blank tail at the bottom: " .. mode, function()
        local render = mode == "paged"
            and { pagination = { enabled = true, page_blocks = 5, max_blocks = 10, page_bytes = 4096 } }
          or { commit_rows = mode == "chunked" and 3 or 0 }
        fixture({ ui = { render = render } }, function(chat, s)
          for i = 1, 30 do
            s:append({ id = "h" .. i, kind = "agent", text = "history " .. i })
          end
          chat:set_session(s)
          ready(chat)
          -- A wrapped streaming line reproduces the stale topline after shrink.
          s:append_text("thought", string.rep("reasoning ", 250), "t")
          chat:render()
          ready(chat)
          at_bottom(chat)
          s:finish_thought()
          chat:render()
          ready(chat)
          at_bottom(chat)
          t.match("Thought", chat.lines_cache[#chat.lines_cache - 1])
          for i = 1, 5 do
            s:append_text("agent", "answer " .. i .. "\n", "a")
            chat:render()
            ready(chat)
            chat:on_scroll()
            at_bottom(chat)
          end
        end)
      end)
    end

    t.it("top-aligns a short collapsed card without adding buffer lines", function()
      fixture(nil, function(chat, s)
        s:append_text("thought", string.rep("line\n", 40), "t")
        chat:set_session(s)
        ready(chat)
        s:finish_thought()
        chat:render()
        ready(chat)
        t.eq(2, #chat.lines_cache)
        t.eq(2, vim.api.nvim_buf_line_count(chat.buf))
        at_top(chat)
        s:append_text("agent", "short reply", "a")
        chat:render()
        ready(chat)
        at_top(chat)
        t.eq(4, vim.api.nvim_buf_line_count(chat.buf))
        vim.api.nvim_win_call(chat.win, function()
          vim.fn.winrestview({ topline = 3, lnum = 4 })
        end)
        chat:on_scroll()
        vim.cmd("redraw")
        at_top(chat)
      end)
    end)

    t.it("handles a collapse and next reply coalesced in one render", function()
      fixture(nil, function(chat, s)
        s:append_text("thought", string.rep("line\n", 40), "t")
        chat:set_session(s)
        ready(chat)
        s:append_text("agent", string.rep("wrapped reply ", 100), "a")
        chat:render()
        ready(chat)
        at_bottom(chat)
        t.match("Thought", chat.lines_cache[1])
        t.eq(0, chat.tail_padding)
      end)
    end)

    t.it("clamps overscroll without moving the reading cursor or changing scrolloff", function()
      fixture(nil, function(chat, s, win)
        for i = 1, 40 do
          s:append({ id = "h" .. i, kind = "agent", text = "history " .. i })
        end
        chat:set_session(s)
        ready(chat)
        local count = #chat.lines_cache
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview({ topline = count - 3, lnum = count - 2, col = 0 })
        end)
        local cursor = vim.api.nvim_win_get_cursor(win)
        chat.follow = false
        chat:on_scroll()
        t.eq(cursor, vim.api.nvim_win_get_cursor(win))
        t.eq(2, vim.wo[win].scrolloff)
        t.falsy(chat.follow)
        local info = vim.fn.getwininfo(win)[1]
        t.eq(info.winrow + info.winbar + info.height - 1, vim.fn.screenpos(win, count, 1).row)
        local before = vim.api.nvim_win_call(win, vim.fn.winsaveview)
        t.falsy(viewport.clamp_tail(chat), "a clamped viewport kept moving")
        t.eq(before, vim.api.nvim_win_call(win, vim.fn.winsaveview))
      end)
    end)

    t.it("does not pull a history reader to the bottom on automatic collapse", function()
      fixture(nil, function(chat, s, win)
        for i = 1, 40 do
          s:append({ id = "h" .. i, kind = "agent", text = "history " .. i })
        end
        s:append_text("thought", string.rep("line\n", 40), "t")
        chat:set_session(s)
        ready(chat)
        chat:scroll_to_top()
        local before = viewport.capture(chat)
        s:finish_thought()
        chat:render()
        ready(chat)
        local after = viewport.capture(chat)
        t.falsy(chat.follow)
        t.eq(before.cursor.id, after.cursor.id)
        t.eq(before.top.id, after.top.id)
        t.truthy(vim.api.nvim_win_get_cursor(win)[1] < #chat.lines_cache - 1)
      end)
    end)

    t.it("keeps short content at the top when the window height changes", function()
      fixture(nil, function(chat, s, win)
        s:append_text("thought", "short thought", "t")
        s:finish_thought()
        chat:set_session(s)
        ready(chat)
        at_top(chat)
        vim.api.nvim_win_set_config(win, { height = 20 })
        chat:on_resize()
        ready(chat)
        at_top(chat)
        t.eq(2, #chat.lines_cache)
      end)
    end)

    t.it("shows the empty conversation hint at the top", function()
      fixture(nil, function(chat, s)
        chat:set_session(s)
        ready(chat)
        at_top(chat)
        t.eq("Start a conversation with the agent.", chat.lines_cache[1])
        t.eq(1, vim.api.nvim_buf_line_count(chat.buf))
      end)
    end)

    t.it("keeps a manually toggled card under the cursor rather than following EOF", function()
      fixture(nil, function(chat, s, win)
        for i = 1, 30 do
          s:append({ id = "h" .. i, kind = "agent", text = "history " .. i })
        end
        local thought = s:append_text("thought", string.rep("line\n", 30), "t")
        chat:set_session(s)
        ready(chat)
        chat.follow = false
        vim.api.nvim_win_set_cursor(win, { chat.line_starts[thought.id], 0 })
        t.truthy(chat:toggle_current())
        t.truthy(vim.wait(5000, function()
          return not chat.dirty and not chat.keep_block
        end, 1))
        t.eq(chat.line_starts[thought.id], vim.api.nvim_win_get_cursor(win)[1])
        t.falsy(chat.follow)
      end)
    end)
  end)
end
