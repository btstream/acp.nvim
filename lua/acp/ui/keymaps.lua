-- Buffer-local keymaps for the two ACP views.
--
-- The views own their buffers; this module only installs mappings. Actions are
-- passed in explicitly so the mapping layer does not reach back into the
-- application controller.
--
-- Every binding is declared in `M.actions` rather than written out by hand:
-- one entry per (view, action) pair, listing the modes it applies to and the
-- English label used both for `desc` and for the help sheet. `config.validate`
-- reads the same table, so a new action cannot forget to be configurable and a
-- configured key for an unknown action is rejected instead of silently ignored.
local complete = require("acp.ui.complete")

local M = {}

---Keys are stored as configured (`<C-s>`), but comparisons and duplicate
---detection need the form Neovim actually maps, so that `<CR>`/`<C-m>` and
---`<Tab>`/`<C-i>` are recognised as the same key.
---@param lhs string
---@return string
local function normalize(lhs)
  local ok, code = pcall(vim.keycode, lhs)
  if not ok or type(code) ~= "string" then
    return lhs
  end
  local ok_trans, translated = pcall(vim.fn.keytrans, code)
  if ok_trans and type(translated) == "string" then
    return translated
  end
  return code
end

---Actions per view, in binding order.
---
---`modes` is the set of modes the action is bound in, so a per-mode config
---value is filtered by what the view actually supports: `pick_model` accepts a
---`{ n = .., i = .. }` table in the composer and only `n` in the transcript.
---@type table<string, {action: string, desc: string, modes: string[], handler: string}[]>
M.actions = {
  input = {
    { action = "send", desc = "send", modes = { "n", "i" }, handler = "on_send" },
    { action = "cancel", desc = "cancel", modes = { "n" }, handler = "on_cancel" },
    { action = "close_panel", desc = "hide panel", modes = { "n" }, handler = "on_hide" },
    { action = "add_selection", desc = "add selection", modes = { "n" }, handler = "on_add_selection" },
    { action = "pick_model", desc = "pick model", modes = { "n", "i" }, handler = "on_pick_model" },
    { action = "pick_mode", desc = "pick mode", modes = { "n", "i" }, handler = "on_pick_mode" },
    { action = "pick_file", desc = "insert file mention", modes = { "n", "i" }, handler = "on_pick_file" },
    { action = "paste_image", desc = "paste image from clipboard", modes = { "n", "i" }, handler = "on_paste_image" },
    { action = "pick_session", desc = "sessions", modes = { "n" }, handler = "on_pick_session" },
  },
  -- Not a composer/transcript view: these are global maps installed once, but
  -- they use the same validation table so unknown actions cannot be configured.
  inline = {
    { action = "normal", desc = "inline prompt at cursor", modes = { "n" }, handler = "on_inline" },
    { action = "visual", desc = "inline prompt for selection", modes = { "x" }, handler = "on_inline" },
  },
  chat = {
    { action = "close_panel", desc = "hide panel", modes = { "n" }, handler = "on_hide" },
    { action = "focus_input", desc = "focus composer", modes = { "n" }, handler = "on_focus_input" },
    { action = "toggle_block", desc = "toggle block", modes = { "n" }, handler = "on_toggle_block" },
    { action = "prev_block", desc = "previous block", modes = { "n" }, handler = "on_prev_block" },
    { action = "next_block", desc = "next block", modes = { "n" }, handler = "on_next_block" },
    { action = "open_location", desc = "open location", modes = { "n" }, handler = "on_open_location" },
    { action = "help", desc = "help", modes = { "n" }, handler = "on_help" },
    { action = "add_selection", desc = "add selection", modes = { "n" }, handler = "on_add_selection" },
    { action = "add_file", desc = "add file", modes = { "n" }, handler = "on_add_file" },
    { action = "add_diagnostics", desc = "add diagnostics", modes = { "n" }, handler = "on_add_diagnostics" },
    { action = "pick_model", desc = "pick model", modes = { "n" }, handler = "on_pick_model" },
    { action = "pick_mode", desc = "pick mode", modes = { "n" }, handler = "on_pick_mode" },
    { action = "new_session", desc = "new session", modes = { "n" }, handler = "on_new_session" },
    { action = "pick_session", desc = "sessions", modes = { "n" }, handler = "on_pick_session" },
    { action = "scroll_bottom", desc = "jump to latest", modes = { "n" }, handler = "on_scroll_bottom" },
    { action = "scroll_top", desc = "jump to start", modes = { "n" }, handler = "on_scroll_top" },
  },
}

---The action table for a view, or nil when the view is unknown.
---@param view string
---@return table[]|nil
function M.view_actions(view)
  return M.actions[view]
end

---Expand a configured value into `{ mode, lhs }` pairs.
---
---Accepts a single key, a list of keys, or a per-mode map, and silently drops
---modes the action does not declare. Returns an empty list for a disabled
---binding so callers can treat "unset" and "disabled" the same way.
---@param value string|string[]|table<string, string|string[]>|false|nil
---@param modes string[] modes the action is bound in
---@return {mode: string, lhs: string}[]
function M.expand(value, modes)
  local out = {}
  if value == nil or value == false then
    return out
  end

  ---@param mode string
  ---@param keys string|string[]|nil
  local function add(mode, keys)
    if keys == nil or keys == false then
      return
    end
    if type(keys) == "string" then
      keys = { keys }
    end
    for _, lhs in ipairs(keys) do
      if type(lhs) == "string" and lhs ~= "" and vim.tbl_contains(modes, mode) then
        out[#out + 1] = { mode = mode, lhs = lhs }
      end
    end
  end

  if type(value) == "string" then
    for _, mode in ipairs(modes) do
      add(mode, value)
    end
    return out
  end

  if type(value) == "table" then
    -- A list applies to every declared mode; a map is per mode.
    if vim.islist(value) then
      for _, mode in ipairs(modes) do
        add(mode, value)
      end
    else
      for mode, keys in pairs(value) do
        add(mode, keys)
      end
    end
  end

  return out
end

---Install `view`'s mappings for `buf`.
---@param view string
---@param buf integer
---@param keymaps table resolved `keymaps[view]`
---@param handlers table<string, fun()>
---@return table<string, {mode: string, lhs: string}[]> bound action -> pairs
function M.attach(view, buf, keymaps, handlers)
  local bound = {}

  for _, spec in ipairs(M.actions[view] or {}) do
    local pairs_ = M.expand((keymaps or {})[spec.action], spec.modes)
    bound[spec.action] = pairs_
    local handler = handlers[spec.handler]
    if handler then
      for _, pair in ipairs(pairs_) do
        vim.keymap.set(pair.mode, pair.lhs, handler, {
          buffer = buf,
          silent = true,
          desc = "acp: " .. spec.desc,
        })
      end
    end
  end

  return bound
end

---Human-readable bindings for one view.
---
---Used by the help sheet so it lists what is actually mapped. Insert-mode
---bindings carry an explicit note because `send` works both while typing and in
---normal mode, and a raw `<M-m>` would otherwise look like the only key.
---@param view string
---@param keymaps table resolved `keymaps[view]`
---@return {keys: string, desc: string}[]
function M.help_entries(view, keymaps)
  local entries = {}
  for _, spec in ipairs(M.actions[view] or {}) do
    local pairs_ = M.expand((keymaps or {})[spec.action], spec.modes)
    if #pairs_ > 0 then
      -- One note per distinct key: `send` is bound to `<C-s>` in both modes
      -- and must not be listed twice, while an insert-only key needs saying so.
      local normal = {}
      for _, pair in ipairs(pairs_) do
        if pair.mode == "n" then
          normal[pair.lhs] = true
        end
      end
      local keys, seen = {}, {}
      for _, pair in ipairs(pairs_) do
        if not seen[pair.lhs] then
          seen[pair.lhs] = true
          keys[#keys + 1] = (pair.mode == "i" and not normal[pair.lhs]) and (pair.lhs .. " (insert)") or pair.lhs
        end
      end
      entries[#entries + 1] = { keys = table.concat(keys, " / "), desc = spec.desc }
    end
  end
  return entries
end

---@param opts {keymaps: table, on_send: fun(), on_cancel: fun(), on_hide: fun(),
---  on_add_selection: fun(), on_pick_model: fun(), on_pick_mode: fun(),
---  on_pick_session: fun(), on_pick_file: fun(), on_paste_image: fun(), get_session: fun()}
function M.attach_input(buf, opts)
  M.attach("input", buf, opts.keymaps, opts)
  complete.attach(buf, opts.get_session, opts.config)
  require("acp.ui.paste_image").attach(buf, {
    config = function()
      return opts.config
    end,
    is_active = function()
      return vim.api.nvim_get_current_buf() == buf
    end,
    on_image = function(path)
      return opts.on_paste_image_path and opts.on_paste_image_path(path) or false
    end,
  })
end

---@param buf integer
---@param opts {keymaps: table, on_hide: fun(), on_focus_input: fun(),
---  on_toggle_block: fun(), on_prev_block: fun(), on_next_block: fun(),
---  on_open_location: fun(), on_help: fun(), on_add_selection: fun(),
---  on_add_file: fun(), on_add_diagnostics: fun(), on_pick_model: fun(),
---  on_pick_mode: fun(), on_new_session: fun(), on_pick_session: fun(),
---  on_scroll_bottom: fun(), on_scroll_top: fun()}
function M.attach_chat(buf, opts)
  M.attach("chat", buf, opts.keymaps, opts)
end

---Normalized form of every key configured for `view`, for duplicate detection.
---
---Returns a map of `mode .. "\0" .. normalized-lhs` to the action that claimed
---it, with `conflict` set to the second action when two actions ask for the same
---key. `config.validate` uses this to point at the clash instead of letting the
---later mapping silently win.
---@param view string
---@param keymaps table
---@return table<string, {action: string, lhs: string, conflict?: string, conflict_lhs?: string}>
function M.claims(view, keymaps)
  local seen = {}
  for _, spec in ipairs(M.actions[view] or {}) do
    for _, pair in ipairs(M.expand((keymaps or {})[spec.action], spec.modes)) do
      local key = pair.mode .. "\0" .. normalize(pair.lhs)
      if seen[key] == nil then
        seen[key] = { action = spec.action, lhs = pair.lhs }
      else
        seen[key].conflict = spec.action
        seen[key].conflict_lhs = pair.lhs
      end
    end
  end
  return seen
end

return M
