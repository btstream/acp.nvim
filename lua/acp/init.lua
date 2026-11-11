-- Public API.
local controller = require("acp.controller")

local M = {}

local configured = false

---Configure acp.nvim. Safe to call multiple times.
---@param opts table|nil
---@param action {discard_queued?: boolean}|nil explicit consent to drop unsent messages
function M.setup(opts, action)
  controller.setup(opts, action)
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

function M.pick_file(opts)
  return ensure().pick_file(opts)
end

---Attach an image file to the composer.
---@param path string
function M.add_image(path)
  return ensure().add_image(path)
end

---Read an image from the clipboard and attach it.
---@param opts {command?: string[]|false}|nil
function M.paste_image(opts)
  return ensure().paste_image(opts)
end

---Start an inline edit at the cursor or visual selection.
---@param opts {review?: "diff"|"write"}|nil
function M.inline(opts)
  ensure()
  return require("acp.inline").open(opts)
end

---Stop the active inline edit.
function M.inline_stop()
  return require("acp.inline").stop()
end

---Forget the current buffer's "always accept" inline state.
function M.inline_reset()
  require("acp.inline").reset()
end

function M.refresh_completion()
  require("acp.completion").refresh()
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

---Open the log file.
function M.show_log()
  ensure().show_log()
end

---Print controller diagnostics.
function M.debug_state()
  ensure().debug_state()
end

return M
