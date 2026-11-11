return function(t)
  local config = require("acp.config")
  local Chat = require("acp.ui.chat")
  local State = require("acp.session.state")
  local Page = require("acp.ui.history_page")
  local viewport = require("acp.ui.viewport")

  local function history(count)
    local s = State.new("paged", "/tmp")
    s:track_changes()
    for i = 1, count do
      s:append({ id = "b" .. i, kind = i % 2 == 1 and "user" or "agent", text = "Message " .. i })
    end
    return s
  end
  local function ready(chat, s)
    t.truthy(
      vim.wait(3000, function()
        return chat.render_version == s.version and not chat.layout_job
      end, 5),
      "page did not finish"
    )
  end
  local function with_view(fn, options)
    local cfg = config.validate(config.merge(config.defaults, options or {
      ui = {
        render = {
          lazy_syntax = true,
          profile = true,
          budget_ms = 1,
          pagination = { enabled = true, page_blocks = 5, max_blocks = 10, page_bytes = 4096 },
        },
      },
    }))
    local chat = Chat.new({ config = cfg })
    local win = vim.api.nvim_open_win(chat.buf, true, { relative = "editor", row = 0, col = 0, width = 72, height = 8 })
    chat.win = win
    local ok, err = xpcall(function()
      fn(chat, cfg)
    end, debug.traceback)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    chat:destroy()
    if not ok then
      error(err, 0)
    end
  end

  t.describe("history pagination", function()
    t.it("can reach old history beyond four times the window budget", function()
      local s = history(100)
      local p = Page.new({ page_blocks = 5, max_blocks = 10, page_bytes = 4096 })
      p:sync(s, true)
      while p.first > 1 do
        local before = p.first
        t.truthy(p:load(s, -1))
        t.truthy(p.first < before, "older loading stopped making progress")
        t.eq(100, p.last)
      end
      p:trim(s, { first = 4, last = 8 })
      t.truthy(p.first <= 4, "trim evicted a pinned block")
    end)
    t.it("materialises only the newest page without changing the Session", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        t.eq(36, chat.page.first)
        t.eq(40, chat.page.last)
        t.eq(5, vim.tbl_count(chat.cache))
        t.eq(40, #s.blocks)
        t.eq(-1, chat.meta[1].page)
        t.eq(nil, chat.meta[1].block_id)
        t.eq(nil, s.blocks[1]._md_user, "unloaded history was laid out")
        t.truthy(chat:render_stats().timings.layout_slice.count > 0)
      end)
    end)

    t.it("keeps the reading anchor when older history is prepended", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        chat.follow = false
        local row = chat.line_starts.b38
        vim.api.nvim_win_set_cursor(chat.win, { row, 0 })
        local before = viewport.capture(chat)
        t.truthy(chat:load_page(-1))
        ready(chat, s)
        t.eq(31, chat.page.first)
        t.eq(40, chat.page.last)
        local after = viewport.capture(chat)
        t.eq(before.cursor.id, after.cursor.id)
        t.eq(before.cursor.offset, after.cursor.offset)
        t.eq(10, vim.tbl_count(chat.cache))
      end)
    end)

    t.it("loads across navigation boundaries and supports earliest/latest jumps", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        chat:scroll_to_top()
        ready(chat, s)
        t.eq(1, chat.page.first)
        t.eq(40, chat.page.last, "the newest block must stay materialised")
        vim.api.nvim_win_set_cursor(chat.win, { chat.line_starts.b5, 0 })
        chat:jump_block(1)
        ready(chat, s)
        t.eq("b6", chat:block_at_cursor().id)
        chat:scroll_to_bottom()
        ready(chat, s)
        t.eq(40, chat.page.last)
        t.truthy(chat.follow)
        t.truthy(chat.page.first < 40)
      end)
    end)
    t.it("exports the complete transcript while native buffer text remains paged", function()
      with_view(function(chat, cfg)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        local eager = Chat.new({
          config = config.merge(cfg, { ui = { render = { lazy_syntax = false, pagination = { enabled = false } } } }),
        })
        eager.width = chat.width
        eager:set_session(s)
        local expected = eager:transcript()
        eager:destroy()
        t.eq(expected, chat:transcript())
        t.eq(5, vim.tbl_count(chat.cache))
        t.eq(nil, s.blocks[1]._md_user)
        t.falsy(table.concat(chat.lines_cache, "\n"):find("Message 1\n", 1, true))
      end)
    end)

    t.it("protects an active Visual selection and refreshes after leaving it", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        chat.follow = false
        vim.cmd("normal! V")
        t.truthy(Page.selected(chat), "test did not establish Visual selection")
        local old = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
        s:append({ id = "b41", kind = "agent", text = "latest" })
        chat:render()
        t.eq(old, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false))
        t.falsy(chat:load_page(-1))
        t.truthy(chat.needs_render)
        vim.cmd("normal! \27")
        chat:render()
        ready(chat, s)
        t.eq(41, chat.page.last, "leaving selection must materialise the new output")
        t.match("latest", table.concat(chat.lines_cache, "\n"))
        t.falsy(chat.follow, "leaving selection must not jump to the bottom")
      end)
    end)

    t.it("discards queued layouts on session replacement and window closure", function()
      with_view(function(chat)
        chat:set_session(history(40))
        local other = history(2)
        other.id = "replacement"
        chat:set_session(other)
        ready(chat, other)
        t.eq(2, vim.tbl_count(chat.cache))
        t.eq(nil, chat.line_starts.b40)
        chat:set_session(history(40))
        vim.api.nvim_win_close(chat.win, true)
        vim.wait(40)
        t.eq(nil, chat.layout_job)
        t.truthy(chat.needs_render)
      end)
    end)

    t.it("recovers a page after model trimming removes its boundary", function()
      local s = history(40)
      local p = Page.new({ page_blocks = 5, max_blocks = 10, page_bytes = 4096 })
      p:beginning(s)
      local kept = {}
      for i = 4, #s.blocks do
        kept[#kept + 1] = s.blocks[i]
      end
      s.blocks = kept
      local first, last = p:sync(s, false)
      t.truthy(first >= 1 and last == #kept)
      t.eq("b40", kept[last].id)
    end)

    t.it("always keeps the newest block and trims the old side on budget", function()
      local s = history(100)
      local p = Page.new({ page_blocks = 5, max_blocks = 10, page_bytes = 4096 })
      p:sync(s, true)
      t.eq(100, p.last)
      t.truthy(p.last - p.first + 1 <= 10)
      for _ = 1, 10 do
        p:load(s, -1)
        t.eq(100, p.last, "loading older history dropped live output")
      end
      -- Loading older pages may grow the window so the reader keeps context;
      -- returning to the bottom trims it back to the configured budget.
      t.truthy(p.last - p.first + 1 > 10)
      p:trim(s)
      t.eq(100, p.last)
      t.truthy(p.last - p.first + 1 <= 10, "trim did not return to the budget")
      -- A block currently visible on the old edge must survive one trim.
      local pinned = p.first
      p:load(s, -1)
      p:trim(s, { first = pinned, last = pinned })
      t.eq(100, p.last)
      local big = history(20)
      for _, block in ipairs(big.blocks) do
        block._bytes = 2048
      end
      local q = Page.new({ page_blocks = 5, max_blocks = 10, page_bytes = 4096 })
      q:sync(big, true)
      t.eq(20, q.last)
      for _ = 1, 5 do
        q:load(big, -1)
        t.eq(20, q.last)
      end
      q:trim(big)
      t.truthy(q.last - q.first + 1 <= 4, "source-byte budget was ignored")
    end)

    t.it("appends live output while the user reads older history", function()
      with_view(function(chat)
        local s = history(20)
        chat:set_session(s)
        ready(chat, s)
        chat.follow = false
        t.truthy(chat:load_page(-1))
        ready(chat, s)
        local before = chat.page.first
        s:append({ id = "live", kind = "agent", text = "live tail" })
        chat:render()
        ready(chat, s)
        t.eq(#s.blocks, chat.page.last, "new output was not materialised")
        t.match("live tail", table.concat(chat.lines_cache, "\n"))
        t.truthy(chat.page.first <= before)
        t.falsy(chat.follow, "reading older history must not jump to the bottom")
      end)
    end)

    t.it("keeps source anchors on the same table row across resize", function()
      with_view(function(chat)
        local s = State.new("table", "/tmp")
        s:track_changes()
        local lines = { "| Row | Content |", "| --- | --- |" }
        for i = 1, 20 do
          lines[#lines + 1] = "| " .. i .. " | " .. string.rep("word ", 12) .. " |"
        end
        s:append({ id = "table", kind = "agent", text = table.concat(lines, "\n") })
        chat:set_session(s)
        ready(chat, s)
        chat.follow = false
        local row
        for i, text in ipairs(chat.lines_cache) do
          if text:find("│ 10 ", 1, true) then
            row = i
            break
          end
        end
        t.truthy(row)
        vim.api.nvim_win_set_cursor(chat.win, { row, 0 })
        local before = viewport.capture(chat)
        vim.api.nvim_win_set_width(chat.win, 40)
        chat:render(true, "layout")
        ready(chat, s)
        local after = viewport.capture(chat)
        t.eq(before.cursor.source, after.cursor.source)
        t.truthy(after.cursor.source ~= nil)
      end)
    end)

    t.it("loads one older page and prefetches on reaching the top edge", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        t.eq(36, chat.page.first)
        vim.api.nvim_win_set_cursor(chat.win, { 1, 0 })
        t.truthy(chat:activate_page())
        ready(chat, s)
        t.eq(31, chat.page.first)
        t.eq(40, chat.page.last)
        vim.api.nvim_win_set_cursor(chat.win, { 1, 0 })
        vim.api.nvim_win_call(chat.win, function()
          vim.cmd("normal! zt")
        end)
        vim.cmd("redraw")
        chat:on_scroll()
        ready(chat, s)
        t.truthy(chat.page.first < 31)
        t.eq(40, chat.page.last)
      end, {
        ui = {
          render = {
            lazy_syntax = true,
            profile = true,
            budget_ms = 1,
            pagination = { enabled = true, page_blocks = 5, max_blocks = 30, page_bytes = 4096 },
          },
        },
      })
    end)

    t.it("rejects superseded width and theme jobs before committing", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        vim.api.nvim_win_set_width(chat.win, 50)
        chat:render(true, "layout")
        require("acp.ui.code_hl").clear_cache()
        vim.api.nvim_win_set_width(chat.win, 42)
        chat:render(true, "layout")
        ready(chat, s)
        t.eq(40, chat.width)
        t.eq(40, chat.page.last)
        t.eq(5, vim.tbl_count(chat.cache))
        t.eq(s.version, chat.render_version)
      end)
    end)

    t.it("does not follow live output from the middle of older history", function()
      with_view(function(chat)
        local s = history(40)
        chat:set_session(s)
        ready(chat, s)
        chat:scroll_to_top()
        ready(chat, s)
        -- Scroll to the middle of the loaded window: not at the newest edge.
        local mid = math.max(1, math.floor(#chat.lines_cache / 2))
        vim.api.nvim_win_set_cursor(chat.win, { mid, 0 })
        chat:on_enter()
        t.falsy(chat.follow)
        local first = chat.page.first
        s:append({ id = "extra", kind = "agent", text = "new output" })
        chat:render()
        ready(chat, s)
        t.eq(#s.blocks, chat.page.last, "new output must still be materialised")
        t.truthy(chat.page.first <= first)
        t.match("new output", table.concat(chat.lines_cache, "\n"))
        t.falsy(chat.follow, "reading older history must not resume following")
      end)
    end)
  end)
end
