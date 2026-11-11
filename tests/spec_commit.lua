return function(t)
  local Chat = require("acp.ui.chat")
  local State = require("acp.session.state")
  local Config = require("acp.config")
  local work = require("acp.ui.work_scheduler")

  local function cfg()
    return Config.validate(Config.merge(Config.defaults, {
      ui = {
        follow_output = false,
        render = { profile = true, budget_ms = 1, commit_rows = 8 },
      },
    }))
  end

  local function view(config)
    local chat = Chat.new({ config = config or cfg() })
    local win = vim.api.nvim_open_win(chat.buf, true, { relative = "editor", row = 0, col = 0, width = 60, height = 8 })
    chat.win = win
    return chat, win
  end

  local function session(count)
    local s = State.new("commit", "/tmp")
    s:track_changes()
    for i = 1, count do
      s:append({ id = "b" .. i, kind = "agent", text = "line " .. i .. "\n" })
    end
    return s
  end

  local function close(chat, win)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    chat:destroy()
  end

  t.describe("bounded transcript commits", function()
    t.it("slices a large first paint and ends with the full layout", function()
      local chat, win = view()
      local ok, err = pcall(function()
        local s = session(200)
        chat:set_session(s)
        t.truthy(chat.commit_job or chat.layout_job, "test did not exercise deferred work")
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job and not chat.layout_job
        end, 2))
        t.truthy(#chat.lines_cache > 200)
        t.eq(#chat.lines_cache, vim.api.nvim_buf_line_count(chat.buf))
        t.eq(s.version, chat.render_version)
        t.truthy(chat.metrics.write)
        t.truthy(chat:render_stats().timings)
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("does not let a stale commit overwrite a newer session", function()
      local chat, win = view()
      local ok, err = pcall(function()
        local first = session(300)
        chat:set_session(first)
        local replacement = State.new("replacement", "/tmp")
        replacement:track_changes()
        replacement:append({ id = "only", kind = "agent", text = "replacement body" })
        chat:set_session(replacement)
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job and not chat.layout_job
        end, 2))
        t.eq(2, #chat.lines_cache)
        t.match("replacement body", chat.lines_cache[1])
        t.eq(replacement, chat.session)
        t.eq(replacement.version, chat.render_version)
        t.falsy(chat.lines_cache[1]:find("line 1", 1, true))
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("drops a commit when the view is destroyed mid-write", function()
      local chat, win = view()
      local s = session(400)
      chat:set_session(s)
      t.truthy(chat.commit_job)
      local buf = chat.buf
      chat:destroy()
      vim.wait(40)
      t.eq(nil, chat.commit_job)
      t.falsy(vim.api.nvim_buf_is_valid(buf))
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end)

    t.it("marks a partial write as needing a full rewrite", function()
      local chat, win = view()
      local ok, err = pcall(function()
        local s = session(400)
        chat:set_session(s)
        t.truthy(chat.commit_job)
        -- A content update while rows are still being written must not be
        -- appended through the incremental writer against half a layout.
        s:append({ id = "late", kind = "agent", text = "late body" })
        chat:render()
        t.truthy(chat.needs_render or chat.commit_job)
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job and not chat.layout_job and not chat.needs_render
        end, 2))
        t.eq(#chat.lines_cache, vim.api.nvim_buf_line_count(chat.buf))
        t.match("late body", table.concat(chat.lines_cache, "\n"))
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("keeps the composer-equivalent small commit synchronous", function()
      local chat, win = view(Config.validate(Config.merge(Config.defaults, {
        ui = { render = { commit_rows = 0 } },
      })))
      local ok, err = pcall(function()
        local s = session(50)
        chat:set_session(s)
        t.falsy(chat.commit_job, "commit_rows=0 must not defer")
        t.truthy(#chat.lines_cache >= 50)
        t.truthy(vim.api.nvim_buf_line_count(chat.buf) >= 50)
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("slices a large table layout without changing its rows", function()
      local lines = { "| Row | Value |", "| --- | --- |" }
      for i = 1, 120 do
        lines[#lines + 1] = "| " .. i .. " | " .. string.rep("cell ", 6) .. " |"
      end
      local s = State.new("table", "/tmp")
      s:track_changes()
      s:append({ id = "t", kind = "agent", text = table.concat(lines, "\n") })
      local chat, win = view(Config.validate(Config.merge(Config.defaults, {
        ui = {
          render = {
            budget_ms = 1,
            commit_rows = 8,
            profile = true,
            pagination = { enabled = true, page_blocks = 4, max_blocks = 8, page_bytes = 1 << 20 },
          },
        },
      })))
      local ok, err = pcall(function()
        chat:set_session(s)
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job and not chat.layout_job
        end, 2))
        local eager_chat, eager_win = view(Config.validate(Config.merge(Config.defaults, {
          ui = { render = { commit_rows = 0 } },
        })))
        local ok2, err2 = pcall(function()
          eager_chat:set_session(s)
          t.eq(#eager_chat.lines_cache, #chat.lines_cache)
          t.eq(table.concat(eager_chat.lines_cache, "\n"), table.concat(chat.lines_cache, "\n"))
        end)
        close(eager_chat, eager_win)
        if not ok2 then
          error(err2, 0)
        end
        t.match("│ 120 ", table.concat(chat.lines_cache, "\n"))
        t.truthy(
          chat.metrics.layout_slice and chat.metrics.layout_slice.count > 120,
          "single-block table layout was not sliced"
        )
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("lets other queued work run between commit slices", function()
      local chat, win = view()
      local ok, err = pcall(function()
        local s = session(400)
        local ticks = 0
        work.shared:enqueue("layout", function()
          ticks = ticks + 1
          return ticks < 50
        end, { label = "competitor" })
        chat:set_session(s)
        t.truthy(chat.commit_job)
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job and ticks > 0
        end, 2))
        t.truthy(ticks > 1, "no other slice ran during the commit")
        t.truthy(chat.lines_cache[1])
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("keeps metadata actions disabled while a partial buffer is visible", function()
      local chat, win = view()
      local ok, err = pcall(function()
        chat:set_session(session(200))
        t.truthy(chat.commit_job)
        t.eq(nil, chat:block_at_cursor())
        t.eq(nil, chat:location_at_cursor())
        t.falsy(chat:toggle_current())
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job
        end, 2))
        t.falsy(vim.bo[chat.buf].modifiable)
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("recovers from a failed write without leaving the buffer editable", function()
      local chat, win = view()
      local write, failed = vim.api.nvim_buf_set_lines, false
      local ok, err = pcall(function()
        vim.api.nvim_buf_set_lines = function(buf, ...)
          if buf == chat.buf and not failed then
            failed = true
            error("injected write failure")
          end
          return write(buf, ...)
        end
        local s = session(100)
        chat:set_session(s)
        t.truthy(vim.wait(5000, function()
          return failed and not chat.commit_job and not chat.needs_render and chat.render_version == s.version
        end, 2))
        t.falsy(vim.bo[chat.buf].modifiable)
        t.eq(chat.lines_cache, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false))
      end)
      vim.api.nvim_buf_set_lines = write
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("does not mutate thought expansion or published caches before yielding", function()
      local chat, win = view()
      local ok, err = pcall(function()
        local blocks = require("acp.ui.blocks")
        local b = { id = "thought", kind = "thought", expanded = false, text = "first\nsecond\nthird\n" }
        local ctx = { icons = chat.icons, width = 60, show_thoughts = true, thoughts = chat.thoughts }
        blocks.render_block(b, ctx)
        local cache, lines = b._md_thought, vim.deepcopy(b._md_thought.lines)
        b.text = b.text .. "more\nlines\n"
        ctx.checkpoint = coroutine.yield
        local co = coroutine.create(function()
          return blocks.render_block(b, ctx)
        end)
        t.truthy(coroutine.resume(co))
        t.eq("suspended", coroutine.status(co))
        t.falsy(b.expanded, "temporary expansion escaped a yielded render")
        t.eq(cache, b._md_thought)
        t.eq(lines, b._md_thought.lines, "uncommitted render modified a published cache")
        -- Abandon this coroutine, as a superseded layout would.
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("rebuilds a commit invalidated by width and syntax generation", function()
      local chat, win = view()
      local hl = require("acp.ui.code_hl")
      local generation = hl.generation
      local ok, err = pcall(function()
        local s = session(200)
        chat:set_session(s)
        vim.api.nvim_win_set_width(win, 45)
        hl.generation = generation + 1
        chat:render(true, "layout")
        local done = vim.wait(5000, function()
          return not chat.commit_job
            and not chat.needs_render
            and chat.width == math.max(20, vim.api.nvim_win_get_width(win) - 2)
        end, 2)
        t.truthy(done, "invalidated commit did not settle at the current width")
        t.eq(s.version, chat.render_version)
        t.eq(chat.lines_cache, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false))
        t.falsy(vim.bo[chat.buf].modifiable)
      end)
      hl.generation = generation
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("applies a page jump only after its chunked commit finishes", function()
      local chat, win = view(Config.validate(Config.merge(cfg(), {
        ui = { render = { pagination = { enabled = true, page_blocks = 5, max_blocks = 10, page_bytes = 4096 } } },
      })))
      local ok, err = pcall(function()
        chat:set_session(session(40))
        local function ready()
          t.truthy(vim.wait(5000, function()
            return not chat.commit_job and not chat.layout_job
          end, 2))
        end
        ready()
        chat:scroll_to_top()
        ready()
        t.eq(chat.line_starts.b1, vim.api.nvim_win_get_cursor(win)[1])
        chat:scroll_to_bottom()
        ready()
        t.eq(#chat.lines_cache, vim.api.nvim_win_get_cursor(win)[1])
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)

    t.it("reports commit work through the shared scheduler", function()
      local chat, win = view()
      local ok, err = pcall(function()
        local before = work.shared.stats.jobs
        chat:set_session(session(100))
        t.truthy(work.shared.stats.jobs > before)
        t.truthy(vim.wait(5000, function()
          return not chat.commit_job
        end, 2))
        t.truthy(work.shared.stats.slices > 0)
      end)
      close(chat, win)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end
