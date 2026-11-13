-- Panel wiring: window events and buffer-local keymaps.
--
-- These run once per `setup`. They only need the state, the config and the
-- controller's public entry points, so they live here instead of in the
-- controller's already-largest function.
local keymaps = require("acp.ui.keymaps")
local drafts = require("acp.storage.drafts")
local inline = require("acp.inline")

local M = {}

---@param deps {state: fun(): table, config: fun(): table, actions: table,
---  refresh_chrome: fun(), stop_spinner: fun(), sync_spinner: fun(),
---  update_title: fun(), prune_sessions: fun()}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps }, { __index = M })
end

function M:state()
  return self.deps.state()
end

---Make `session` the one on screen.
---
---Switching away leaves the previous session active on the agent side. Ask it to
---release the resources, but never while a turn is still in flight: closing a
---running session would kill work the user only meant to leave in the
---background. Agents without `session/close` simply ignore the request.
---@param session table|nil
function M:select_session(session)
  local S = self:state()
  local previous = S.sess.current
  S.sess.current = session
  S.sess.runtime:select(session)
  if
    previous
    and previous ~= session
    and previous.status == "idle"
    and #(previous.queue or {}) == 0
    and S.sess.service
  then
    pcall(S.sess.service.close, S.sess.service, previous.id)
  end
  if S.view.chat then
    S.view.chat:set_session(session)
    S.view.chat.pending_new = false
  end
  if S.view.input then
    local drafts = require("acp.storage.drafts")
    local restored = session and drafts.get(session.cwd, session.id) or nil
    S.view.input:switch_session(session and session.id or nil, restored, session)
  end
  self.deps.refresh_chrome()
  self.deps.prune_sessions()
end

---Show the panel, starting the agent when needed.
function M:open()
  local S = self:state()
  if S.view.panel then
    S.view.panel:set_views(S.view.chat, S.view.input)
    S.view.panel:show()
  end
  self.deps.sync_spinner()
  if S.conn.phase == "ready" then
    if not S.sess.current then
      self.deps.actions.new_session()
    end
    return
  end
  if S.conn.phase == "starting" then
    return
  end
  self.deps.actions.connect()
end

---Hide the panel without stopping the session.
function M:hide()
  local S = self:state()
  if S.view.panel then
    S.view.panel:set_views(S.view.chat, S.view.input)
    S.view.panel:hide()
  end
  self.deps.stop_spinner()
end

function M:toggle()
  local S = self:state()
  if S.view.panel and S.view.panel:is_visible() then
    self:hide()
  else
    self:open()
  end
end

---@param which "input"|"chat"
function M:focus(which)
  local S = self:state()
  if S.view.panel and S.view.panel:focus(which) then
    return
  end
  self:open()
end

function M:install_window_events()
  local S = self:state()
  if not S.view.panel then
    return
  end
  local deps = self.deps
  S.view.panel:install_events({
    on_all_closed = deps.stop_spinner,
    on_resize = deps.refresh_chrome,
    on_leave = function()
      deps.stop_spinner()
      if S.view.input then
        pcall(S.view.input.save_draft, S.view.input)
      end
      pcall(drafts.flush)
      -- Release active sessions before the process goes away.
      if S.sess.service and S.conn.client then
        pcall(function()
          S.sess.service:close_all_on_exit()
        end)
      end
      if S.conn.service then
        -- Do not let a stray agent process outlive the editor.
        S.conn.service:terminate()
      end
    end,
  })
end

function M:install_input_keymaps()
  local S = self:state()
  local actions = self.deps.actions
  keymaps.attach_input(S.view.input.buf, {
    keymaps = self.deps.config().keymaps.input,
    config = self.deps.config(),
    get_session = function()
      return self:state().session
    end,
    on_send = function()
      local sessions = self:state()
      -- Ctrl-S submits; when a turn is running and the composer is empty it stops instead.
      local running = sessions.sess.current and sessions.sess.current.status == "running"
      if running and S.view.input:text():match("^%s*$") and #S.view.input.attachments == 0 then
        actions.cancel()
        return
      end
      S.view.input:submit()
    end,
    on_cancel = actions.cancel,
    on_hide = actions.hide,
    on_add_selection = actions.add_selection,
    on_pick_model = actions.pick_model,
    on_pick_mode = actions.pick_mode,
    on_pick_file = actions.pick_file,
    on_paste_image = actions.paste_image,
    on_paste_image_path = actions.add_image,
    on_pick_session = actions.pick_session,
  })
end

---Find the global mapping for `lhs`, so a replaced map can be restored later.
---@param mode string
---@param lhs string
---@return table|nil
function M.global_map(mode, lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if vim.keycode(map.lhs) == vim.keycode(lhs) then
      return map
    end
  end
end

function M:install_inline_keymaps()
  -- Removing the maps this module installed last time keeps `setup()` idempotent
  -- and restores whatever the user had before.
  local installed_maps = self.inline_maps or {}
  for _, installed in ipairs(installed_maps) do
    local map = M.global_map(installed.mode, installed.lhs)
    if map and map.callback == installed.callback then
      vim.keymap.del(installed.mode, map.lhs)
      if installed.previous then
        vim.fn.mapset(installed.mode, false, installed.previous)
      end
    end
  end
  self.inline_maps = {}
  local spec = self.deps.config().keymaps.inline or {}
  local function install(value, modes)
    for _, entry in ipairs(keymaps.expand(value, modes)) do
      local previous = M.global_map(entry.mode, entry.lhs)
      local callback = function()
        inline.open()
      end
      vim.keymap.set(entry.mode, entry.lhs, callback, { desc = "acp.nvim: inline prompt" })
      self.inline_maps[#self.inline_maps + 1] = {
        mode = entry.mode,
        lhs = entry.lhs,
        callback = callback,
        previous = previous,
      }
    end
  end
  install(spec.normal, { "n" })
  install(spec.visual, { "x" })
end

function M:install_chat_keymaps()
  local S = self:state()
  local actions = self.deps.actions
  local update_title = self.deps.update_title
  keymaps.attach_chat(S.view.chat.buf, {
    keymaps = self.deps.config().keymaps.chat,
    on_hide = actions.hide,
    on_focus_input = function()
      actions.focus("input")
    end,
    on_toggle_block = function()
      if not S.view.chat:toggle_current() then
        actions.focus("input")
      end
    end,
    on_prev_block = function()
      S.view.chat:jump_block(-1)
      update_title()
    end,
    on_next_block = function()
      S.view.chat:jump_block(1)
      update_title()
    end,
    on_open_location = function()
      if S.view.chat:activate_page() then
        return
      end
      actions.open_location()
    end,
    on_help = actions.show_help,
    on_add_selection = actions.add_selection,
    on_add_file = actions.add_file,
    on_add_diagnostics = actions.add_diagnostics,
    on_pick_model = actions.pick_model,
    on_pick_mode = actions.pick_mode,
    on_new_session = actions.new_session,
    on_pick_session = actions.pick_session,
    on_scroll_bottom = function()
      S.view.chat:scroll_to_bottom()
      update_title()
    end,
    on_scroll_top = function()
      S.view.chat:scroll_to_top()
      update_title()
    end,
  })
end

return M
