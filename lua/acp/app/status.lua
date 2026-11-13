-- Status reporting and chrome refresh.
--
-- The winbar and the animation timer follow the *visible* session, not the
-- event that last started or stopped a turn: opening a hidden running session
-- must resume the animation, while a hidden composer must not leave a timer
-- ticking. That rule lives here so every caller shares it.
local icons = require("acp.ui.icons")
local presenter = require("acp.ui.presenter")

local M = {}

---@param deps {state: fun(): table, config: fun(): table, chrome: fun(): table|nil}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps }, { __index = M })
end

---The chrome object, or nil before setup and after teardown.
function M:chrome()
  return self.deps.chrome()
end

---Whether a permission request is waiting for the user.
function M:waiting_permission(session)
  local interactions = self.deps.state().view.interactions
  return interactions ~= nil and interactions:waiting(session and session.id or nil)
end

---Public structured status for statusline components.
---@return table
function M:status()
  local S = self.deps.state()
  local session = S.sess.current
  local model_label, mode_label
  if session then
    model_label, mode_label = presenter.toolbar_labels(session)
  end
  return {
    connected = S.conn.phase == "ready",
    connection = S.conn.phase,
    running = session and (session.status == "running" or session.status == "cancelling") or false,
    waiting_permission = self:waiting_permission(session),
    queued = session and #session.queue or 0,
    agent = S.config and S.config.agent or nil,
    model = model_label,
    mode = mode_label,
    session_id = session and session.id or nil,
    usage = session and session.usage or nil,
  }
end

---Short text suitable for a statusline component. Never sets the statusline itself.
---@return string
function M:statusline()
  local st = self:status()
  local S = self.deps.state()
  local use_icons = S.config and S.config.ui.icons
  local glyph = use_icons ~= nil and icons.get(use_icons).assistant or "*"
  if not st.connected then
    return glyph .. " off"
  end
  if st.waiting_permission then
    return glyph .. " !"
  end
  if st.running then
    return glyph .. " " .. icons.get(use_icons).tool_run
  end
  if st.queued > 0 then
    return glyph .. " +" .. st.queued
  end
  return glyph
end

---Build the composer winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M:composer_bar_for(win)
  local chrome = self:chrome()
  if not chrome then
    return ""
  end
  return chrome:composer_bar(win)
end

---Build the transcript winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M:chat_bar_for(win)
  local chrome = self:chrome()
  if not chrome then
    return ""
  end
  return chrome:chat_bar(win)
end

-- Animation follows the visible session, not the event that last started or
-- stopped a turn.
function M:sync_spinner()
  local chrome = self:chrome()
  if not chrome then
    return
  end
  local S = self.deps.state()
  local session = S.sess.current
  local input = S.view.input
  local running = S.conn.phase == "ready"
    and session ~= nil
    and session.status == "running"
    and input ~= nil
    and input:is_visible()
    and vim.api.nvim_win_get_tabpage(input.win) == vim.api.nvim_get_current_tabpage()
    and self.deps.config().ui.toolbar.placement ~= "off"
  chrome:sync_animation(running)
end

function M:refresh()
  self:sync_spinner()
  local chrome = self:chrome()
  if chrome then
    chrome:refresh()
  end
end

function M:stop_spinner()
  local chrome = self:chrome()
  if chrome then
    chrome:sync_animation(false)
  end
end

function M:apply()
  local chrome = self:chrome()
  if chrome then
    chrome:apply()
  end
end

return M
