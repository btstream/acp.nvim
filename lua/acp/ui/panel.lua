-- Panel windows: creating, hiding, focusing and forgetting the two ACP views.
--
-- Layout still decides where windows go and how they are locked. This module
-- owns which views are visible, repairs a missing half of the panel, and keeps
-- the "never leave Neovim without a window" rule in one place.
local layout = require("acp.layout")

local Panel = {}
Panel.__index = Panel

---@param opts {config: fun(): table, notify: fun(message: string, level: integer|nil),
---  on_windows_ready: fun(chat: table, input: table)|nil}
function Panel.new(opts)
  return setmetatable({
    config = opts.config,
    notify = opts.notify,
    on_windows_ready = opts.on_windows_ready,
    chat = nil,
    input = nil,
    requested = false,
    augroup = nil,
  }, Panel)
end

function Panel:set_views(chat, input)
  self.chat, self.input = chat, input
end

---@return table|nil chat
---@return table|nil input
function Panel:views()
  return self.chat, self.input
end

---Whether either panel view is on screen.
---@return boolean
function Panel:is_visible()
  return (self.chat and self.chat:is_visible()) or (self.input and self.input:is_visible()) or false
end

---Build whichever windows are missing, keeping the existing half in place.
---@return boolean ok
function Panel:ensure()
  if self.chat:is_visible() and self.input:is_visible() then
    return true
  end

  layout.remember_focus()

  local chat_visible = self.chat:is_visible()
  local input_visible = self.input and self.input:is_visible()

  if not chat_visible and not input_visible then
    -- Neither view exists: build them together so the panel keeps its width.
    local chat, input = layout.create_panel(self.chat.buf, self.input.buf)
    if not chat or not input then
      self.notify("unable to create the panel windows", vim.log.levels.ERROR)
      return false
    end
    self.chat.win = chat
    self.input.win = input
  elseif not chat_visible then
    local win = layout.create_chat_win(self.chat.buf, self.input.win)
    if not win then
      self.notify("unable to create the chat window", vim.log.levels.ERROR)
      return false
    end
    self.chat.win = win
  elseif not input_visible then
    local win = layout.create_input_win(self.input.buf, self.chat.win)
    if not win then
      self.notify("unable to create the composer window", vim.log.levels.ERROR)
      return false
    end
    self.input.win = win
  end

  if self.on_windows_ready then
    self.on_windows_ready(self.chat, self.input)
  end
  if self.chat then
    self.chat:render(true)
  end

  -- In external mode a layout manager owns the windows; warn when it has no
  -- view registered for them, which would leave the panel out of place.
  if self.config().layout.backend == "external" then
    require("acp.integrations.edgy").check_registered()
  end
  return true
end

---Show the panel and focus the composer when configured.
---@return boolean ok
function Panel:show()
  self.requested = true
  local ok = self:ensure()
  local cfg = self.config()
  if ok and cfg.layout.focus_input_on_open and self.input and self.input:is_visible() then
    vim.api.nvim_set_current_win(self.input.win)
    vim.cmd("startinsert")
  end
  return ok
end

---Hide the panel without stopping the session.
function Panel:hide()
  self.requested = false
  if self.input and self.input:is_visible() then
    pcall(self.input.save_draft, self.input)
  end
  local windows = {}
  for _, view in ipairs({ self.input, self.chat }) do
    if view and view.win and vim.api.nvim_win_is_valid(view.win) then
      windows[#windows + 1] = view.win
    end
    if view then
      view.win = nil
    end
  end
  local remaining = #vim.api.nvim_list_wins() - #windows
  if remaining <= 0 and #windows > 0 then
    -- Never leave Neovim without a window; keep one and show a scratch buffer.
    -- The window is locked, so unlock it before replacing the panel buffer.
    local keep = windows[1]
    table.remove(windows, 1)
    layout.set_window_buffer(keep, vim.api.nvim_create_buf(true, false))
  end
  for _, win in ipairs(windows) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  local target = self.config().layout.restore_focus and layout.saved_focus() or nil
  if target and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_set_current_win, target)
  end
  layout.clear_saved_focus()
end

---@param which "input"|"chat"
---@return boolean focused
function Panel:focus(which)
  if which == "input" then
    if self.input and self.input:is_visible() then
      vim.api.nvim_set_current_win(self.input.win)
      vim.cmd("startinsert")
      return true
    end
  elseif self.chat and self.chat:is_visible() then
    vim.api.nvim_set_current_win(self.chat.win)
    vim.cmd("stopinsert")
    return true
  end
  return false
end

---Install window events for the panel.
---
---The callbacks keep policy in the controller: this module only reports what
---happened to the windows it owns.
---@param hooks {on_all_closed: fun(), on_resize: fun(), on_leave: fun()}
function Panel:install_events(hooks)
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  self.augroup = vim.api.nvim_create_augroup("AcpPanel", { clear = true })

  local refresh_pending = false
  local function resize()
    if refresh_pending then
      return
    end
    refresh_pending = true
    vim.schedule(function()
      refresh_pending = false
      if not self.destroyed then
        hooks.on_resize()
      end
    end)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if self:forget_window(win) then
        hooks.on_all_closed()
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = resize,
  })

  -- Window-local resizes (splits, layout managers, mouse dragging) do not fire
  -- VimResized, so refresh the winbars explicitly.
  vim.api.nvim_create_autocmd({ "WinResized", "WinNew", "WinClosed" }, {
    group = self.augroup,
    callback = resize,
  })
  -- Reconcile animation when focus returns, including a timer stopped by other
  -- code, and stop work for ACP windows in an inactive tabpage.
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter", "TabEnter", "FocusGained", "VimResume" }, {
    group = self.augroup,
    callback = resize,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = self.augroup,
    callback = hooks.on_leave,
  })
end

---Remove the panel's autocmd group.
function Panel:remove_events()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

---Forget a closed window so visibility checks do not use a stale id.
---@param win integer
---@return boolean all_closed
function Panel:forget_window(win)
  layout.forget_window(win)
  if self.chat and self.chat.win == win then
    self.chat.win = nil
  end
  if self.input and self.input.win == win then
    self.input.win = nil
  end
  return (not self.chat or self.chat.win == nil) and (not self.input or self.input.win == nil)
end

---Close both views and release their buffers.
function Panel:destroy()
  self.destroyed = true
  self:remove_events()
  local windows = {}
  for _, view in ipairs({ self.input, self.chat }) do
    if view and view.win and vim.api.nvim_win_is_valid(view.win) then
      windows[#windows + 1] = view.win
    end
  end
  if #windows >= #vim.api.nvim_list_wins() then
    local keep = table.remove(windows, 1)
    if keep then
      layout.set_window_buffer(keep, vim.api.nvim_create_buf(true, false))
    end
  end
  for _, win in ipairs(windows) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  layout.clear_saved_focus()
  for _, view in ipairs({ self.input, self.chat }) do
    if view and view.destroy then
      pcall(view.destroy, view)
    end
  end
  self.chat, self.input = nil, nil
  self.requested = false
end

return Panel
