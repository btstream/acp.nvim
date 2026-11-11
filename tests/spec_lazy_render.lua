return function(t)
  local config = require("acp.config")
  local Chat = require("acp.ui.chat")
  local State = require("acp.session.state")
  local decoration = require("acp.ui.decoration")
  local CodeHL = require("acp.ui.code_hl")

  local function with_view(options, fn)
    local cfg = config.merge(config.defaults, {
      ui = {
        follow_output = false,
        render = {
          lazy_syntax = true,
          profile = true,
          budget_ms = 1,
          overscan = 0,
        },
      },
    })
    cfg = config.validate(config.merge(cfg, options or {}))
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

  local function session(count)
    local s = State.new("lazy", "/tmp")
    s:track_changes()
    for i = 1, count do
      s:append({ id = "a" .. i, kind = "agent", text = "```lua\nlocal value" .. i .. " = " .. i .. "\n```\n" })
    end
    return s
  end

  t.describe("lazy syntax", function()
    t.it("does not parse offscreen code during layout and preserves full text", function()
      with_view(nil, function(chat, cfg)
        local original, calls = CodeHL.highlight, 0
        CodeHL.highlight = function(...)
          calls = calls + 1
          return original(...)
        end
        local ok, err = pcall(function()
          local s = session(30)
          chat:set_session(s)
          t.eq(0, calls, "layout eagerly parsed code")
          t.truthy(vim.wait(2000, function()
            return chat.render_version == s.version
          end, 1))
          local text = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
          t.truthy(vim.wait(2000, function()
            return #vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, {}) > 0
          end, 5))
          t.truthy(calls < 30, "offscreen fences were parsed")
          t.eq(text, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false))
          local eager = Chat.new({ config = config.merge(cfg, { ui = { render = { lazy_syntax = false } } }) })
          eager.width = chat.width
          eager:set_session(s)
          t.eq(text, eager.lines_cache, "lazy syntax changed layout")
          eager:destroy()
          t.truthy(chat.metrics.syntax.count > 0)
          t.truthy(chat.metrics.layout.count > 0)
        end)
        CodeHL.highlight = original
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("clears old viewport marks when scrolling and keeps byte offsets correct", function()
      with_view(nil, function(chat)
        chat:set_session(session(30))
        t.truthy(vim.wait(2000, function()
          return #vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, {}) > 0
        end, 5))
        local count = #chat.lines_cache
        vim.api.nvim_win_set_cursor(chat.win, { count, 0 })
        vim.api.nvim_win_call(chat.win, function()
          vim.cmd("normal! zb")
        end)
        vim.cmd("redraw")
        decoration.schedule(chat)
        local settled = vim.wait(2000, function()
          local marks = vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, { details = true })
          local bounds = vim.api.nvim_win_call(chat.win, function()
            return { vim.fn.line("w0"), vim.fn.line("w$") }
          end)
          if #marks == 0 then
            return false
          end
          for _, mark in ipairs(marks) do
            if mark[2] < bounds[1] - 1 or mark[2] >= bounds[2] then
              return false
            end
          end
          return true
        end, 5)
        t.truthy(
          settled,
          vim.inspect({
            marks = vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, {}),
            cursor = vim.api.nvim_win_get_cursor(chat.win),
            bounds = vim.api.nvim_win_call(chat.win, function()
              return { vim.fn.line("w0"), vim.fn.line("w$") }
            end),
            rows = count,
            stats = chat:render_stats(),
          })
        )
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, { details = true })) do
          local text = chat.lines_cache[mark[2] + 1]
          t.truthy(mark[3] >= 4, "syntax reached the gutter")
          t.truthy(mark[4].end_col <= #text)
        end
      end)
    end)

    t.it("does not apply queued syntax to a replacement session or destroyed view", function()
      with_view(nil, function(chat)
        chat:set_session(session(20))
        local other = State.new("other", "/tmp")
        other:append({ id = "plain", kind = "agent", text = "plain text" })
        chat:set_session(other)
        vim.wait(30)
        t.eq(0, #vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, {}))
        chat:set_session(session(20))
        chat:destroy()
        vim.wait(30)
        t.truthy(chat.destroyed)
      end)
    end)

    t.it("defers diff syntax without changing signs, backgrounds or file rules", function()
      local diff = require("acp.ui.diff")
      local entries = {
        { path = "/tmp/a.lua", oldText = "local a = 1\n", newText = "local b = 2\n" },
        { path = "/tmp/b.lua", oldText = "local c = 3\n", newText = "local d = 4\n" },
      }
      local lazy, eager = diff.lines(entries, { lazy_syntax = true }), diff.lines(entries)
      t.eq(#eager, #lazy)
      local count = 0
      for i, line in ipairs(lazy) do
        t.eq(eager[i].text, line.text)
        t.eq(eager[i].bg, line.bg)
        if line.decorations then
          count = count + 1
        end
        for _, seg in ipairs(line.segments or {}) do
          t.falsy(seg.syntax)
        end
      end
      t.eq(4, count)
    end)

    t.it("validates rendering budgets and pagination configuration", function()
      for _, change in ipairs({
        { budget_ms = 0 },
        { overscan = -1 },
        { lazy_syntax = "yes" },
        { pagination = { enabled = 1 } },
        { pagination = { page_blocks = 1.5 } },
        { pagination = { page_blocks = 20, max_blocks = 10 } },
      }) do
        local ok = pcall(config.validate, config.merge(config.defaults, { ui = { render = change } }))
        t.falsy(ok)
      end
    end)

    t.it("keeps the incremental tail path and leaves profiling off when disabled", function()
      with_view({ ui = { render = { profile = false } } }, function(chat)
        local s = session(100)
        chat:set_session(s)
        local blocks = require("acp.ui.blocks")
        local original, calls = blocks.render_block, 0
        blocks.render_block = function(...)
          calls = calls + 1
          return original(...)
        end
        local ok, err = pcall(function()
          s:append_text("agent", "tail", "stream")
          chat:render()
          s:append_text("agent", " more", "stream")
          chat:render()
          t.eq(2, calls, "stable history was re-rendered")
          t.eq(nil, chat.metrics)
        end)
        blocks.render_block = original
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("slices decoration work even when one source row has many captures", function()
      with_view(nil, function(chat)
        local original = CodeHL.highlight
        CodeHL.highlight = function()
          local ranges = {}
          for _ = 1, 20000 do
            ranges[#ranges + 1] = { row = 0, s = 0, e = 5, group = "@keyword" }
          end
          return ranges, true
        end
        local ok, err = pcall(function()
          chat:set_session(session(1))
          t.truthy(vim.wait(3000, function()
            return not chat.decoration_pending
          end, 5))
          t.eq(20000, #vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, {}))
          t.truthy(chat.metrics.decorate_slice.count > 1, "one row monopolised the decoration task")
        end)
        CodeHL.highlight = original
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("rechecks ownership if parsing reenters session selection", function()
      with_view(nil, function(chat)
        local other = State.new("replacement", "/tmp")
        other:append({ id = "plain", kind = "agent", text = "plain first\nplain second\nplain third" })
        local original, switched = CodeHL.highlight, false
        CodeHL.highlight = function()
          if not switched then
            switched = true
            chat:set_session(other)
          end
          return { { row = 0, s = 0, e = 5, group = "@keyword" } }, true
        end
        local ok, err = pcall(function()
          chat:set_session(session(1))
          t.truthy(vim.wait(1000, function()
            return switched and not chat.decoration_pending
          end, 5))
          t.eq(other, chat.session)
          t.eq(0, #vim.api.nvim_buf_get_extmarks(chat.buf, decoration.ns, 0, -1, {}))
        end)
        CodeHL.highlight = original
        if not ok then
          error(err, 0)
        end
      end)
    end)
  end)
end
