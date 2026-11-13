-- Winbar rendering, animation and redraw coalescing.
--
-- The winbar expressions call into this module on every redraw, so the render
-- path stays cheap and never changes editor state. Animation and refresh scheduling are
-- owned here, which is why `destroy()` must be called on teardown.
local toolbar = require("acp.ui.toolbar")
local presenter = require("acp.ui.presenter")
local Log = require("acp.log")

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_ASCII = { "|", "/", "-", "\\" }

local Chrome = {}
Chrome.__index = Chrome

local function timer_active(timer)
  if not timer then
    return false
  end
  local ok, active = pcall(function()
    return not timer:is_closing() and timer:is_active()
  end)
  return ok and active
end

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end)
end

local function visible(input)
  if not input or not input:is_visible() then
    return false
  end
  if input.win then
    if vim.api.nvim_win_get_tabpage(input.win) ~= vim.api.nvim_get_current_tabpage() then
      return false
    end
    if input.buf and vim.api.nvim_win_get_buf(input.win) ~= input.buf then
      return false
    end
  end
  return true
end

---@param opts {config: fun(): table, current: fun(): table|nil,
---  session_label: fun(session: table|nil): string|nil,
---  waiting: fun(session: table|nil): boolean,
---  chat: fun(): table|nil, input: fun(): table|nil, clock?: fun(): number}
function Chrome.new(opts)
  return setmetatable({
    config = opts.config,
    current = opts.current,
    session_label = opts.session_label,
    waiting = opts.waiting,
    get_chat = opts.chat,
    get_input = opts.input,
    pending = false,
    frame = nil,
    timer = nil,
    index = 1,
    epoch = 0,
    clock = opts.clock or vim.uv.hrtime,
    stats = {
      starts = 0,
      restarts = 0,
      stops = 0,
      timer_fires = 0,
      ticks = 0,
      frame_changes = 0,
      coalesced_ticks = 0,
      hidden_ticks = 0,
      refreshes = 0,
      redraws = 0,
      bar_evaluations = 0,
      targeted_fallbacks = 0,
      tick_errors = 0,
      apply_errors = 0,
      redraw_errors = 0,
      start_errors = 0,
      last_tick_gap_ms = 0,
      max_tick_gap_ms = 0,
      last_schedule_delay_ms = 0,
      max_schedule_delay_ms = 0,
      last_refresh_delay_ms = 0,
      max_refresh_delay_ms = 0,
    },
    failed = {},
  }, Chrome)
end

function Chrome:record_error(stage, err)
  local key = stage .. "_errors"
  self.stats[key] = self.stats[key] + 1
  self.stats.last_error = stage .. ": " .. tostring(err):sub(1, 500)
  if not self.failed[stage] then
    Log.warn("spinner %s failed: %s", stage, tostring(err))
  end
  self.failed[stage] = true
end

---Build the composer winbar for the window currently being drawn.
---Runs on every redraw; only cheap diagnostic counters are updated.
---@param win integer|nil defaults to the current window
---@return string
function Chrome:composer_bar(win)
  win = win or vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(win)
  local cfg = self.config()

  if cfg.ui.toolbar.placement == "off" then
    return ""
  end

  local session = self.current()
  local waiting = self.waiting(session)
  self.stats.bar_evaluations = self.stats.bar_evaluations + 1
  self.last_eval_at = self.clock()
  self.stats.last_bar_status = waiting and "waiting" or (session and session.status or "idle")
  self.stats.last_evaluated_frame = self.stats.last_bar_status == "running" and self.frame or nil
  local model, mode, thinking, mode_key, mode_plan
  if session then
    model, mode, thinking = presenter.toolbar_labels(session)
    -- The badge needs the value id and the agent's own plan flag; the label
    -- alone cannot tell "Plan mode" from an ordinary mode.
    mode, mode_key, mode_plan = presenter.mode_badge(session)
  end

  local input = self.get_input()
  local chip_labels = {}
  if input then
    for _, att in ipairs(input.attachments) do
      if att.kind ~= "image" then
        chip_labels[#chip_labels + 1] = att.label or ""
      end
    end
  end

  return toolbar.render({
    icons = cfg.ui.icons,
    mode = mode,
    mode_key = mode_key,
    mode_plan = mode_plan,
    model = model,
    thinking = thinking,
    status = session and session.status or "idle",
    waiting = waiting,
    queued = session and #session.queue or 0,
    usage = session and session.usage or nil,
    show_usage = cfg.ui.toolbar.show_usage,
    spinner = self.frame,
    chips = chip_labels,
  }, width)
end

---Target both ACP winbars without moving focus. Older API variants fall back
---to redrawstatus!; plain redrawstatus need not invalidate a non-current window.
function Chrome:redraw()
  local targets, seen = {}, {}
  for _, get_view in ipairs({ self.get_input, self.get_chat }) do
    local view = get_view()
    local win = view and view.win
    if
      win
      and vim.api.nvim_win_is_valid(win)
      and not seen[win]
      and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
    then
      targets[#targets + 1], seen[win] = win, true
    end
  end
  if #targets == 0 then
    return
  end
  local targeted = self.targeted_redraw ~= false and type(vim.api.nvim__redraw) == "function"
  if targeted then
    for _, win in ipairs(targets) do
      local ok, err = pcall(vim.api.nvim__redraw, { win = win, winbar = true })
      if not ok then
        self.stats.last_targeted_error = tostring(err):sub(1, 500)
        targeted = false
        break
      end
    end
    if targeted then
      local ok, err = pcall(vim.api.nvim__redraw, { flush = true })
      targeted = ok
      if not ok then
        self.stats.last_targeted_error = tostring(err):sub(1, 500)
      end
    end
    if not targeted then
      self.targeted_redraw = false
      self.stats.targeted_fallbacks = self.stats.targeted_fallbacks + 1
    end
  end
  if not targeted then
    vim.cmd("redrawstatus!")
  end
  self.stats.redraw_backend = targeted and "targeted_winbar" or "redrawstatus!"
  self.stats.redraws = self.stats.redraws + 1
end

---Build the transcript winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function Chrome:chat_bar(win)
  local cfg = self.config()
  if cfg.ui.title.placement == "off" then
    return ""
  end
  win = win or vim.api.nvim_get_current_win()
  local session = self.current()
  local chat = self.get_chat()
  return toolbar.chat_title({
    icons = cfg.ui.icons,
    agent = cfg.agent,
    title = self.session_label(session),
    pending_new = chat and chat.pending_new or false,
    running = session and session.status == "running" or false,
  }, vim.api.nvim_win_get_width(win))
end

---Install the winbar expressions on the panel windows.
function Chrome:apply()
  if self.destroyed then
    return
  end
  local cfg = self.config()
  local chat = self.get_chat()
  if chat then
    local win = chat.win
    if win and vim.api.nvim_win_is_valid(win) then
      if cfg.ui.title.placement == "off" then
        vim.api.nvim_set_option_value("winbar", "", { win = win })
      elseif vim.api.nvim_get_option_value("winbar", { win = win }) ~= "%{%v:lua.AcpTranscriptBar()%}" then
        -- Set once; the expression re-renders with the real width on every redraw.
        vim.api.nvim_set_option_value("winbar", "%{%v:lua.AcpTranscriptBar()%}", { win = win })
      end
    end
  end

  local input = self.get_input()
  if input then
    local win = input.win
    if win and vim.api.nvim_win_is_valid(win) then
      local ok, err = input:apply_winbar()
      if ok == false then
        error(err, 0)
      end
    end
  end
end

---Coalesce chrome updates; several state changes in one tick repaint once.
function Chrome:refresh()
  if self.destroyed or self.pending then
    return
  end
  self.pending = true
  local requested = self.clock()
  vim.schedule(function()
    if self.destroyed then
      return
    end
    self.pending = false
    local now = self.clock()
    local delay = (now - requested) / 1e6
    self.stats.refreshes = self.stats.refreshes + 1
    self.stats.last_refresh_delay_ms = delay
    self.stats.max_refresh_delay_ms = math.max(self.stats.max_refresh_delay_ms, delay)
    local ok, err = pcall(self.apply, self)
    if not ok then
      self:record_error("apply", err)
    else
      self.failed.apply = nil
    end
    if self.destroyed then
      return
    end
    ok, err = pcall(self.redraw, self)
    if not ok then
      self:record_error("redraw", err)
    else
      self.failed.redraw = nil
    end
    self.last_refresh_at = self.clock()
  end)
end

---Only called in scheduled editor context; fast UV callbacks never use window APIs.
function Chrome:tick(requested)
  local now = self.clock()
  local delay = (now - requested) / 1e6
  local gap = (now - (self.last_tick_at or now)) / 1e6
  self.last_tick_at = now
  self.stats.ticks = self.stats.ticks + 1
  self.stats.last_tick_gap_ms = gap
  self.stats.max_tick_gap_ms = math.max(self.stats.max_tick_gap_ms, gap)
  self.stats.last_schedule_delay_ms = delay
  self.stats.max_schedule_delay_ms = math.max(self.stats.max_schedule_delay_ms, delay)
  if not visible(self.get_input()) then
    self.stats.hidden_ticks = self.stats.hidden_ticks + 1
    return
  end
  if self.destroyed or not self.requested_running then
    return
  end
  -- Skip missed frames rather than replaying a backlog after a busy main loop.
  local frames = self.icons and SPINNER or SPINNER_ASCII
  self.index = math.floor((now - self.started_at) / (self.interval * 1e6)) % #frames + 1
  if self.frame ~= frames[self.index] then
    self.stats.frame_changes = self.stats.frame_changes + 1
  end
  self.frame = frames[self.index]
  self:refresh()
end

---Start or stop the activity animation to match the session state.
---@param running boolean
function Chrome:sync_animation(running)
  if self.destroyed then
    return
  end
  if not running then
    self:stop_animation()
    return
  end
  local cfg = self.config()
  self.animation_enabled = cfg.ui.toolbar.animate
  if not cfg.ui.toolbar.animate then
    self:stop_animation()
    self.requested_running = true
    self.index = 1
    self.frame = cfg.ui.icons and SPINNER[1] or SPINNER_ASCII[1]
    return
  end
  local interval = cfg.ui.toolbar.animation_interval or 120
  self.requested_running = true
  if timer_active(self.timer) and self.interval == interval and self.icons == cfg.ui.icons then
    return
  end
  if self.timer then
    self.stats.restarts = self.stats.restarts + 1
  end
  self:stop_animation()
  self.requested_running = true
  local frames = cfg.ui.icons and SPINNER or SPINNER_ASCII
  self.interval, self.icons = interval, cfg.ui.icons
  self.started_at = self.clock()
  self.last_tick_at = self.started_at
  self.index = 1
  self.frame = frames[1]
  local allocated, timer = pcall(vim.uv.new_timer)
  local epoch = self.epoch
  if not allocated or not timer then
    self:record_error("start", allocated and "unable to allocate timer" or timer)
    return
  end
  self.timer = timer
  local ok, result, start_err = pcall(function()
    return timer:start(interval, interval, function()
      if self.destroyed or self.timer ~= timer or self.epoch ~= epoch then
        return
      end
      self.stats.timer_fires = self.stats.timer_fires + 1
      if self.tick_pending then
        self.stats.coalesced_ticks = self.stats.coalesced_ticks + 1
        return
      end
      self.tick_pending = true
      local requested = self.clock()
      vim.schedule(function()
        if self.destroyed or self.timer ~= timer or self.epoch ~= epoch then
          return
        end
        self.tick_pending = false
        local tick_ok, tick_err = pcall(self.tick, self, requested)
        if not tick_ok then
          self:record_error("tick", tick_err)
        else
          self.failed.tick = nil
        end
      end)
    end)
  end)
  if not ok or not timer_active(timer) then
    close_timer(timer)
    self.timer = nil
    self:record_error("start", not ok and result or start_err or "timer did not become active")
    return
  end
  self.failed.start = nil
  self.stats.starts = self.stats.starts + 1
  self:refresh()
end

function Chrome:stop_animation()
  if self.timer then
    close_timer(self.timer)
    self.timer = nil
    self.stats.stops = self.stats.stops + 1
  end
  self.epoch = self.epoch + 1
  self.tick_pending = false
  self.requested_running = false
  self.frame = nil
end

---A cheap snapshot: evaluation/redraw requests are not proof of physical paint.
function Chrome:diagnostics()
  local out = vim.deepcopy(self.stats)
  local now = self.clock()
  out.frame, out.index = self.frame, self.index
  out.timer_active = timer_active(self.timer)
  out.requested_running = self.requested_running == true
  out.animation_enabled = self.animation_enabled
  out.active_errors = vim.deepcopy(self.failed)
  out.refresh_pending, out.tick_pending = self.pending, self.tick_pending == true
  out.interval_ms = self.interval
  out.last_tick_age_ms = self.last_tick_at and (now - self.last_tick_at) / 1e6 or nil
  out.last_refresh_age_ms = self.last_refresh_at and (now - self.last_refresh_at) / 1e6 or nil
  out.last_bar_eval_age_ms = self.last_eval_at and (now - self.last_eval_at) / 1e6 or nil
  local ok, input = pcall(self.get_input)
  if ok then
    out.input_win = input and input.win
    local visible_ok, is_visible = pcall(visible, input)
    out.input_visible = visible_ok and is_visible or false
  end
  if self.destroyed then
    out.state = "destroyed"
  elseif not out.requested_running then
    out.state = "stopped"
  elseif not out.animation_enabled then
    out.state = "static"
  elseif not out.input_visible then
    out.state = "hidden"
  elseif not out.timer_active then
    out.state = "missing_timer"
  elseif self.failed.tick then
    out.state = "tick_error"
  else
    out.state = "animating"
  end
  return out
end

function Chrome:destroy()
  self.destroyed = true
  self:stop_animation()
  self.pending = false
end

return Chrome
