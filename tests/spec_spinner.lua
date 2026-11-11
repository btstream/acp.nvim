return function(t)
  local Chrome = require("acp.ui.chrome")
  local Config = require("acp.config")
  local State = require("acp.session.state")

  local function fixture(fn, clock)
    local cfg = vim.deepcopy(Config.defaults)
    cfg.ui.toolbar.animation_interval = 10
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, { relative = "editor", row = 0, col = 0, width = 40, height = 4 })
    local input = {
      win = win,
      buf = buf,
      attachments = {},
      apply_winbar = function() end,
      is_visible = function()
        return vim.api.nvim_win_is_valid(win)
      end,
    }
    local s = State.new("spinner", "/tmp")
    s.status = "running"
    local c = Chrome.new({
      config = function()
        return cfg
      end,
      current = function()
        return s
      end,
      waiting = function()
        return false
      end,
      session_label = function()
        return "spinner"
      end,
      chat = function()
        return nil
      end,
      input = function()
        return input
      end,
      clock = clock,
    })
    local log = require("acp.log")
    local original_warn, warnings = log.warn, {}
    log.warn = function(fmt, ...)
      warnings[#warnings + 1] = string.format(fmt, ...)
    end
    local ok, err = xpcall(function()
      fn(c, cfg, input, warnings)
    end, debug.traceback)
    log.warn = original_warn
    c:destroy()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if not ok then
      error(err, 0)
    end
  end

  local function refreshed(c)
    t.truthy(vim.wait(500, function()
      return not c.pending
    end, 2))
  end

  t.describe("spinner reliability", function()
    t.it("replaces stopped and closed handles instead of trusting a stored timer", function()
      fixture(function(c)
        c:sync_animation(true)
        local old = c.timer
        old:stop()
        c:sync_animation(true)
        t.truthy(c.timer ~= old)
        t.truthy(old:is_closing())
        old = c.timer
        old:close()
        c:sync_animation(true)
        t.truthy(c.timer ~= old)
        t.truthy(c.timer:is_active())
        t.eq(2, c.stats.restarts)
        t.eq(3, c.stats.starts)
      end)
    end)

    t.it("uses elapsed time and records gaps instead of replaying missed frames", function()
      local now = 0
      fixture(function(c)
        c:sync_animation(true)
        now = 35 * 1e6
        c:tick(0)
        t.eq(4, c.index)
        t.eq(35, c.stats.max_tick_gap_ms)
        t.eq(35, c.stats.max_schedule_delay_ms)
        now = 88 * 1e6
        c:tick(now)
        t.eq(9, c.index)
        t.eq(53, c.stats.max_tick_gap_ms)
        refreshed(c)
        t.truthy(c.stats.max_refresh_delay_ms >= 88)
      end, function()
        return now
      end)
    end)

    t.it("survives repeated tick errors and reports each error streak once", function()
      fixture(function(c, _, input, warnings)
        local checks = 0
        input.is_visible = function()
          checks = checks + 1
          if checks <= 3 then
            error("temporary visibility failure")
          end
          return true
        end
        c:sync_animation(true)
        t.truthy(vim.wait(1000, function()
          return c.stats.ticks > 4
        end, 2))
        t.eq(3, c.stats.tick_errors)
        t.eq(1, #warnings)
        t.truthy(c.timer:is_active())
        t.eq(nil, c.failed.tick)
      end)
    end)

    t.it("targets inactive ACP winbars without changing focus", function()
      fixture(function(c, _, input)
        local original, calls = vim.api.nvim__redraw, {}
        vim.api.nvim__redraw = function(opts)
          calls[#calls + 1] = opts
        end
        local ok, err = pcall(function()
          local focused = vim.api.nvim_get_current_win()
          t.truthy(focused ~= input.win)
          c:refresh()
          refreshed(c)
          t.eq(input.win, calls[1].win)
          t.eq(true, calls[1].winbar)
          t.eq(true, calls[#calls].flush)
          t.eq(focused, vim.api.nvim_get_current_win())
          t.eq("targeted_winbar", c:diagnostics().redraw_backend)
        end)
        vim.api.nvim__redraw = original
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("falls back to redrawstatus! and does not retry an unsupported API each frame", function()
      fixture(function(c)
        local original_redraw, original_cmd = vim.api.nvim__redraw, vim.cmd
        local probes, redraws = 0, 0
        vim.api.nvim__redraw = function()
          probes = probes + 1
          error("unsupported winbar option")
        end
        vim.cmd = function(cmd)
          if cmd == "redrawstatus!" then
            redraws = redraws + 1
          else
            return original_cmd(cmd)
          end
        end
        local ok, err = pcall(function()
          c:refresh()
          refreshed(c)
          c:refresh()
          refreshed(c)
          t.eq(1, probes)
          t.eq(2, redraws)
          local stats = c:diagnostics()
          t.eq("redrawstatus!", stats.redraw_backend)
          t.eq(1, stats.targeted_fallbacks)
          t.match("unsupported winbar", stats.last_targeted_error)
        end)
        vim.api.nvim__redraw, vim.cmd = original_redraw, original_cmd
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("records apply and redraw failures without wedging the refresh gate", function()
      fixture(function(c, _, _, warnings)
        local apply, redraw = c.apply, c.redraw
        c.apply = function()
          error("apply failure")
        end
        c.redraw = function()
          error("redraw failure")
        end
        c:refresh()
        refreshed(c)
        t.eq(1, c.stats.apply_errors)
        t.eq(1, c.stats.redraw_errors)
        t.eq(2, #warnings)
        c.apply, c.redraw = apply, redraw
        c:refresh()
        refreshed(c)
        t.eq(nil, c.failed.apply)
        t.eq(nil, c.failed.redraw)
        t.truthy(c.stats.redraws > 0)
      end)
    end)

    t.it("stops an active handle when animation is disabled at runtime", function()
      fixture(function(c, cfg)
        c:sync_animation(true)
        local old = c.timer
        cfg.ui.toolbar.animate = false
        c:sync_animation(true)
        t.eq(nil, c.timer)
        t.truthy(old:is_closing())
        t.truthy(c.frame)
        t.truthy(c:diagnostics().requested_running)
        cfg.ui.toolbar.animate = true
        c:sync_animation(true)
        t.truthy(c.timer:is_active())
      end)
    end)

    t.it("recovers after allocation and start failures on the next state reconciliation", function()
      fixture(function(c)
        local original = vim.uv.new_timer
        vim.uv.new_timer = function()
          error("allocation failure")
        end
        local ok, err = pcall(function()
          c:sync_animation(true)
        end)
        vim.uv.new_timer = original
        if not ok then
          error(err, 0)
        end
        t.eq(nil, c.timer)
        t.eq(1, c.stats.start_errors)
        local closed = false
        vim.uv.new_timer = function()
          return {
            start = function()
              return nil, "EINVAL"
            end,
            is_active = function()
              return false
            end,
            is_closing = function()
              return closed
            end,
            stop = function() end,
            close = function()
              closed = true
            end,
          }
        end
        ok, err = pcall(function()
          c:sync_animation(true)
        end)
        vim.uv.new_timer = original
        if not ok then
          error(err, 0)
        end
        t.eq(nil, c.timer)
        t.truthy(closed)
        t.eq(2, c.stats.start_errors)
        c:sync_animation(true)
        t.truthy(c.timer:is_active())
      end)
    end)

    t.it("coalesces raw ticks and rejects queued work from a replaced handle", function()
      fixture(function(c)
        local original_schedule, original_new = vim.schedule, vim.uv.new_timer
        local tasks, handles = {}, {}
        vim.schedule = function(fn)
          tasks[#tasks + 1] = fn
        end
        vim.uv.new_timer = function()
          local h = {}
          function h:start(_, _, callback)
            self.active, self.callback = true, callback
          end
          function h:stop()
            self.active = false
          end
          function h:close()
            self.closing, self.active = true, false
          end
          function h:is_active()
            return self.active
          end
          function h:is_closing()
            return self.closing == true
          end
          handles[#handles + 1] = h
          return h
        end
        local ok, err = pcall(function()
          c:sync_animation(true)
          handles[1].callback()
          handles[1].callback()
          t.eq(2, #tasks, "one refresh and one tick should be queued")
          t.eq(1, c.stats.coalesced_ticks)
          tasks[1]()
          local old_tick = tasks[2]
          c:stop_animation()
          c:sync_animation(true)
          handles[2].callback()
          old_tick()
          t.eq(0, c.stats.ticks)
          t.truthy(c.tick_pending, "old tick cleared the new tick gate")
          tasks[3]()
          tasks[4]()
          t.eq(1, c.stats.ticks)
          t.falsy(c.tick_pending)
          c:destroy()
          local refreshed_before = c.stats.refreshes
          for i = 5, #tasks do
            tasks[i]()
          end
          t.eq(refreshed_before, c.stats.refreshes)
        end)
        vim.schedule, vim.uv.new_timer = original_schedule, original_new
        if not ok then
          error(err, 0)
        end
      end)
    end)

    t.it("restarts cleanly when interval or glyph settings change", function()
      fixture(function(c, cfg)
        c:sync_animation(true)
        local old = c.timer
        cfg.ui.toolbar.animation_interval, cfg.ui.icons = 25, false
        c:sync_animation(true)
        t.truthy(old:is_closing())
        t.truthy(c.timer:is_active())
        t.eq("|", c.frame)
        t.eq(25, c.interval)
        local now = c.started_at + 37.5 * 1e6
        c.clock = function()
          return now
        end
        c:tick(now)
        t.eq("/", c.frame)
      end)
    end)

    t.it("distinguishes a waiting glyph from an animated running indicator", function()
      fixture(function(c, _, input)
        c:sync_animation(true)
        c.waiting = function()
          return true
        end
        c:composer_bar(input.win)
        local stats = c:diagnostics()
        t.eq("waiting", stats.last_bar_status)
        t.eq(nil, stats.last_evaluated_frame)
        t.truthy(stats.timer_active)
        t.eq(1, stats.bar_evaluations)
      end)
    end)

    t.it("does not redraw after apply reenters teardown", function()
      fixture(function(c)
        local redraws = 0
        c.apply = function()
          c:destroy()
        end
        c.redraw = function()
          redraws = redraws + 1
        end
        c:refresh()
        refreshed(c)
        t.truthy(c.destroyed)
        t.eq(0, redraws)
      end)
    end)

    t.it("observes composer winbar setter errors instead of silently swallowing them", function()
      fixture(function(c, cfg, input)
        local original = vim.api.nvim_set_option_value
        input.config = cfg
        local temp = require("acp.ui.input").new({ config = cfg })
        input.apply_winbar = temp.apply_winbar
        temp:destroy()
        vim.api.nvim_set_option_value = function(name, value, ...)
          local opts = ...
          if name == "winbar" and opts and opts.win == input.win then
            error("test winbar setter failure")
          end
          return original(name, value, ...)
        end
        local ok, err = pcall(function()
          c:refresh()
          refreshed(c)
          t.eq(1, c.stats.apply_errors)
          t.match("test winbar setter", c:diagnostics().last_error)
        end)
        vim.api.nvim_set_option_value = original
        if not ok then
          error(err, 0)
        end
      end)
    end)
  end)
end
