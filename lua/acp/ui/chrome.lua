-- Winbar rendering, animation and redraw coalescing.
--
-- The winbar expressions call into this module on every redraw, so the render
-- path stays cheap and side-effect free. Animation and refresh scheduling are
-- owned here, which is why `destroy()` must be called on teardown.
local toolbar = require("acp.ui.toolbar")
local presenter = require("acp.ui.presenter")

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_ASCII = { "|", "/", "-", "\\" }

local Chrome = {}
Chrome.__index = Chrome

---@param opts {config: fun(): table, current: fun(): tables|nil,
---  session_label: fun(session: table|nil): string|nil,
---  waiting: fun(session: table|nil): boolean,
---  chat: fun(): table|nil, input: fun(): table|nil}
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
  }, Chrome)
end

---Build the composer winbar for the window currently being drawn.
---Runs on every redraw, so it must stay cheap and side-effect free.
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
  local model, mode
  if session then
    model, mode = presenter.toolbar_labels(session)
  end

  local input = self.get_input()
  local chips = ""
  local chip_width = 0
  if input and #input.attachments > 0 then
    local labels = {}
    for _, att in ipairs(input.attachments) do
      labels[#labels + 1] = "[" .. (att.label or "") .. "]"
    end
    local plain = table.concat(labels, " ")
    -- `%$...$` inherits the bar's background; a `%#...%#` here would restart
    -- from `WinBar`, which a layout manager may have remapped.
    chips = "%#AcpToolbar#%$AcpUserChip$" .. toolbar.escape(plain) .. "%$AcpToolbar$ "
    chip_width = vim.api.nvim_strwidth(plain) + 1
  end

  local base = toolbar.render({
    icons = cfg.ui.icons,
    mode = mode,
    model = model,
    status = session and session.status or "idle",
    waiting = self.waiting(session),
    queued = session and #session.queue or 0,
    usage = session and session.usage or nil,
    show_usage = cfg.ui.toolbar.show_usage,
    spinner = self.frame,
  }, math.max(12, width - chip_width))

  return chips .. base
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
        pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
      elseif vim.api.nvim_get_option_value("winbar", { win = win }) ~= "%{%v:lua.AcpTranscriptBar()%}" then
        -- Set once; the expression re-renders with the real width on every redraw.
        pcall(vim.api.nvim_set_option_value, "winbar", "%{%v:lua.AcpTranscriptBar()%}", { win = win })
      end
    end
  end

  local input = self.get_input()
  if input then
    local win = input.win
    if win and vim.api.nvim_win_is_valid(win) then
      input:apply_winbar()
    end
  end
end

---Coalesce chrome updates; several state changes in one tick repaint once.
function Chrome:refresh()
  if self.destroyed or self.pending then
    return
  end
  self.pending = true
  vim.schedule(function()
    if self.destroyed then
      return
    end
    self.pending = false
    self:apply()
    pcall(vim.cmd, "redrawstatus")
  end)
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
  if not cfg.ui.toolbar.animate then
    self.frame = cfg.ui.icons and SPINNER[1] or SPINNER_ASCII[1]
    return
  end
  if self.timer then
    return
  end
  local frames = cfg.ui.icons and SPINNER or SPINNER_ASCII
  self.index = 1
  self.frame = frames[1]
  self.timer = vim.fn.timer_start(cfg.ui.toolbar.animation_interval or 120, function()
    if self.destroyed then
      return
    end
    -- Do not animate while the panel is not visible.
    local input = self.get_input()
    if not input or not input:is_visible() then
      return
    end
    self.index = (self.index % #frames) + 1
    self.frame = frames[self.index]
    self:refresh()
  end, { ["repeat"] = -1 })
end

function Chrome:stop_animation()
  if self.timer then
    pcall(vim.fn.timer_stop, self.timer)
    self.timer = nil
  end
  self.frame = nil
end

function Chrome:destroy()
  self.destroyed = true
  self:stop_animation()
  self.pending = false
end

return Chrome
