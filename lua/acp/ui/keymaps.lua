-- Buffer-local keymaps for the two ACP views.
--
-- The views own their buffers; this module only installs mappings. Actions are
-- passed in explicitly so the mapping layer does not reach back into the
-- application controller.
local complete = require("acp.ui.complete")

local M = {}

---@param opts {keymaps: table, on_send: fun(), on_cancel: fun(), on_hide: fun(),
---  on_add_selection: fun(), on_pick_model: fun(), on_pick_mode: fun(),
---  on_pick_session: fun()}
function M.attach_input(buf, opts)
  local km = opts.keymaps

  local function map(mode, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "acp: " .. desc })
  end

  map({ "n", "i" }, km.send, opts.on_send, "send")
  map("n", km.cancel, opts.on_cancel, "cancel")
  map("n", km.close_panel, opts.on_hide, "hide panel")
  map("n", "<C-]>", opts.on_add_selection, "add selection")
  -- Model/mode are reachable with the mouse (click the winbar), from normal
  -- mode, and with Alt combinations while typing. `<C-m>` must not be used: in
  -- a terminal it is the same key as <CR>.
  map("n", "M", opts.on_pick_model, "pick model")
  map("n", "m", opts.on_pick_mode, "pick mode")
  map("i", "<M-m>", opts.on_pick_model, "pick model")
  map("i", "<M-b>", opts.on_pick_mode, "pick mode")
  map("n", "L", opts.on_pick_session, "sessions")

  complete.attach(buf, opts.get_session)
end

---@param buf integer
---@param opts {keymaps: table, on_hide: fun(), on_focus_input: fun(),
---  on_toggle_block: fun(), on_prev_block: fun(), on_next_block: fun(),
---  on_open_location: fun(), on_help: fun(), on_add_selection: fun(),
---  on_add_file: fun(), on_add_diagnostics: fun(), on_pick_model: fun(),
---  on_pick_mode: fun(), on_new_session: fun(), on_pick_session: fun(),
---  on_scroll_bottom: fun(), on_scroll_top: fun()}
function M.attach_chat(buf, opts)
  local km = opts.keymaps

  local function map(mode, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "acp: " .. desc })
  end

  map("n", km.close_panel, opts.on_hide, "hide panel")
  map("n", km.focus_input, opts.on_focus_input, "focus composer")
  map("n", km.toggle_block, opts.on_toggle_block, "toggle block")
  map("n", km.prev_block, opts.on_prev_block, "previous block")
  map("n", km.next_block, opts.on_next_block, "next block")
  map("n", km.open_location, opts.on_open_location, "open location")
  map("n", "g?", opts.on_help, "help")
  map("n", "<C-s>", opts.on_focus_input, "focus composer")
  map("n", "S", opts.on_add_selection, "add selection")
  map("n", "F", opts.on_add_file, "add file")
  map("n", "R", opts.on_add_diagnostics, "add diagnostics")
  map("n", "M", opts.on_pick_model, "pick model")
  map("n", "m", opts.on_pick_mode, "pick mode")
  map("n", "<C-n>", opts.on_new_session, "new session")
  map("n", "L", opts.on_pick_session, "sessions")
  map("n", "G", opts.on_scroll_bottom, "jump to latest")
  map("n", "gg", opts.on_scroll_top, "jump to start")
end

return M
