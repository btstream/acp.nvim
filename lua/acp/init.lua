-- Public API.
local controller = require("acp.controller")

local M = {}

local configured = false

---Configure acp.nvim. Safe to call multiple times.
---@param opts table|nil
function M.setup(opts)
  controller.setup(opts)
  configured = true
end

local function ensure()
  if not configured then
    M.setup({})
  end
  return controller
end

function M.open()
  ensure().open()
end

function M.hide()
  ensure().hide()
end

function M.toggle()
  ensure().toggle()
end

---@param which "input"|"chat"
function M.focus(which)
  ensure().focus(which or "input")
end

function M.new_session()
  ensure().new_session()
end

function M.cancel()
  ensure().cancel()
end

---@param path string|nil
function M.add_file(path)
  ensure().add_file(path)
end

function M.add_selection()
  ensure().add_selection()
end

function M.add_diagnostics()
  ensure().add_diagnostics()
end

function M.pick_model()
  ensure().pick_model()
end

function M.pick_mode()
  ensure().pick_mode()
end

function M.pick_session()
  ensure().pick_session()
end

---Delete a stored session (asks for confirmation first).
function M.delete_session()
  ensure().delete_session_flow()
end

---Reconnect to the agent after a crash or an explicit disconnect.
function M.reconnect()
  ensure().reconnect()
end

---Stop the agent process without closing the panel.
function M.disconnect()
  ensure().disconnect()
end

---Open the oldest pending permission request.
function M.show_permission()
  ensure().show_pending_permission()
end

function M.status()
  return ensure().status()
end

---Short statusline component. Returns text only; it never sets an option.
---@return string
function M.statusline()
  return ensure().statusline()
end

function M.health()
  return require("acp.health").check()
end

return M
