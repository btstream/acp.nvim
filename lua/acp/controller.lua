-- Application controller: wires protocol, session state, layout and UI.
local config_mod = require("acp.config")
local log = require("acp.log")
local presenter = require("acp.ui.presenter")
local Chat = require("acp.ui.chat")
local Input = require("acp.ui.input")
local Icons = require("acp.ui.icons")
local highlights = require("acp.ui.highlights")
local keymaps = require("acp.ui.keymaps")
local drafts = require("acp.storage.drafts")
local layout = require("acp.layout")
local Runtime = require("acp.session.runtime")
local Tasks = require("acp.tasks")
local context = require("acp.context")
local Permissions = require("acp.app.permissions")
local Options = require("acp.app.options")
local Chrome = require("acp.ui.chrome")
local Panel = require("acp.ui.panel")
local Catalog = require("acp.app.catalog")
local Sessions = require("acp.app.sessions")
local Prompts = require("acp.app.prompts")
local Connection = require("acp.app.connection")
local windows = require("acp.ui.windows")
local work = require("acp.ui.work_scheduler")

local M = {}

local S = {
  config = nil,
  client = nil,
  session = nil,
  sessions = {},
  -- session_id -> title and session_id -> cwd, learned from session/list and
  -- owned by the catalog.
  titles = {},
  session_cwds = {},
  chat = nil,
  input = nil,
  connection = "stopped", -- stopped | starting | ready | disconnected
  pending_permissions = {},
  pending_selections = nil,
  replaying = false,
}
local operations = Tasks.new(function()
  return S
end)

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function cfg()
  return S.config
end

local function new_local_session(id, cwd, result)
  return S.runtime:create(id, cwd, result)
end

local function prune_sessions()
  S.runtime:prune(S.session, S.pending_permissions)
end

local function dispatch_queued(session)
  if S.connection ~= "ready" or not S.runtime:owns(session) then
    return
  end
  local runtime = S.runtime
  local item = runtime:next_message(session)
  if item then
    if M.send_now(item.text, item.attachments, session) then
      runtime:ack_message(session, item)
      if session.status == "idle" then
        dispatch_queued(session)
      end
    else
      runtime:restore_message(session, item)
      local replacement = runtime.sessions[session.id]
      if replacement and replacement ~= session and replacement.outbox == session.outbox then
        dispatch_queued(replacement)
      end
    end
  end
end

local function ui_current(client, generation, session)
  return S.client == client
    and operations.generation == generation
    and (not session or (S.session == session and S.runtime:owns(session)))
end

local function invalidate_operations()
  local inline = package.loaded["acp.inline"]
  if inline then
    inline.invalidate()
  end
  operations:reset()
  if S.catalog then
    S.catalog:reset()
  end
  S.replaying, S.creating_session = false, false
  if S.sessions_service then
    S.sessions_service.replaying = false
    S.sessions_service.creating = false
  end
end

---Resolve the session working directory.
---@return string
---The working directory used for sessions.
---
---This is Neovim's current working directory, so the panel, the agent and the
---user always agree on which directory they are working in. It can be pinned
---explicitly with `cwd` in the configuration.
---@return string
local function resolve_cwd()
  if S.config and S.config.cwd and S.config.cwd ~= "" then
    return vim.fn.fnamemodify(S.config.cwd, ":p")
  end
  return vim.fn.getcwd()
end

---Current session or nil.
local function current()
  return S.session
end

---Whether a decoded JSON value is a real, non-empty string.
---@param value any
---@return boolean
local function has_text(value)
  return type(value) == "string" and value ~= ""
end

local function session_label(session)
  if not session then
    return nil
  end
  if has_text(session.title) then
    return session.title
  end
  -- Titles are cached per session id; prefer that over the raw identifier.
  local cached = S.catalog and S.catalog:title(session.id)
  if has_text(cached) then
    return cached
  end
  -- Fall back to a short, stable identifier instead of pretending there is no session.
  return "#" .. tostring(session.id):sub(-6)
end

local function notify(message, level)
  vim.notify("acp.nvim: " .. message, level or vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- status
---------------------------------------------------------------------------

---@param session AcpSessionState|nil
local function waiting_permission(session)
  return S.permissions:waiting(session)
end

---Public structured status for statusline components.
---@return table
function M.status()
  local session = current()
  local model_label, mode_label
  if session then
    model_label, mode_label = presenter.toolbar_labels(session)
  end
  return {
    connected = S.connection == "ready",
    connection = S.connection,
    running = session and (session.status == "running" or session.status == "cancelling") or false,
    waiting_permission = waiting_permission(session),
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
function M.statusline()
  local st = M.status()
  local use_icons = S.config and S.config.ui.icons
  local glyph = use_icons ~= nil and Icons.get(use_icons).assistant or "*"
  if not st.connected then
    return glyph .. " off"
  end
  if st.waiting_permission then
    return glyph .. " !"
  end
  if st.running then
    return glyph .. " " .. Icons.get(use_icons).tool_run
  end
  if st.queued > 0 then
    return glyph .. " +" .. st.queued
  end
  return glyph
end

---------------------------------------------------------------------------
-- chrome updates
---------------------------------------------------------------------------

---Build the composer winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M.composer_bar(win)
  if not S.chrome then
    return ""
  end
  return S.chrome:composer_bar(win)
end

---Build the transcript winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M.chat_bar(win)
  if not S.chrome then
    return ""
  end
  return S.chrome:chat_bar(win)
end

local function update_chat_title()
  if S.chrome then
    S.chrome:apply()
  end
end

local function update_input_toolbar()
  if S.chrome then
    S.chrome:apply()
  end
end

-- Animation follows the visible session, not the event that last started or
-- stopped a turn. In particular, opening a hidden running session must resume
-- it, while a hidden composer must not leave a timer ticking in the background.
local function sync_spinner()
  if S.chrome then
    local session = S.session
    local input = S.input
    local running = S.connection == "ready"
      and session ~= nil
      and session.status == "running"
      and input ~= nil
      and input:is_visible()
      and vim.api.nvim_win_get_tabpage(input.win) == vim.api.nvim_get_current_tabpage()
      and cfg().ui.toolbar.placement ~= "off"
    S.chrome:sync_animation(running)
  end
end

local function refresh_chrome()
  sync_spinner()
  if S.chrome then
    S.chrome:refresh()
  end
end

local function refresh_session_title(session, cb)
  if S.catalog then
    S.catalog:refresh_title(session, cb)
  elseif cb then
    cb()
  end
end

local function stop_spinner()
  if S.chrome then
    S.chrome:sync_animation(false)
  end
end

---------------------------------------------------------------------------
-- session switching
---------------------------------------------------------------------------

---@param session AcpSessionState
local function activate_session(session)
  S.session = session
  S.runtime:select(session)
  if S.chat then
    S.chat:set_session(session)
    S.chat.pending_new = false
  end
  if S.input then
    local restored = session and drafts.get(session.cwd, session.id) or nil
    S.input:switch_session(session and session.id or nil, restored, session)
  end
  refresh_chrome()
  prune_sessions()
end

---------------------------------------------------------------------------
-- window lifecycle
---------------------------------------------------------------------------

local function setup_window_events()
  if not S.panel then
    return
  end
  S.panel:install_events({
    on_all_closed = stop_spinner,
    on_resize = refresh_chrome,
    on_leave = function()
      stop_spinner()
      if S.input then
        pcall(S.input.save_draft, S.input)
      end
      pcall(drafts.flush)
      if S.connection_service then
        -- Do not let a stray agent process outlive the editor.
        S.connection_service:terminate()
      end
    end,
  })
end

local function set_input_keymaps()
  keymaps.attach_input(S.input.buf, {
    keymaps = cfg().keymaps.input,
    config = cfg(),
    get_session = function()
      return S.session
    end,
    on_send = function()
      -- Ctrl-S submits; when a turn is running and the composer is empty it stops instead.
      local running = S.session and S.session.status == "running"
      if running and S.input:text():match("^%s*$") and #S.input.attachments == 0 then
        M.cancel()
        return
      end
      S.input:submit()
    end,
    on_cancel = function()
      M.cancel()
    end,
    on_hide = function()
      M.hide()
    end,
    on_add_selection = function()
      M.add_selection()
    end,
    on_pick_model = function()
      M.pick_model()
    end,
    on_pick_mode = function()
      M.pick_mode()
    end,
    on_pick_file = function()
      M.pick_file()
    end,
    on_paste_image = function()
      M.paste_image()
    end,
    on_paste_image_path = function(path)
      return M.add_image(path)
    end,
    on_pick_session = function()
      M.pick_session()
    end,
  })
end

local inline_maps = {}
local function global_map(mode, lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if vim.keycode(map.lhs) == vim.keycode(lhs) then
      return map
    end
  end
end
local function set_inline_keymaps()
  for _, installed in ipairs(inline_maps) do
    local map = global_map(installed.mode, installed.lhs)
    if map and map.callback == installed.callback then
      vim.keymap.del(installed.mode, map.lhs)
      if installed.previous then
        vim.fn.mapset(installed.mode, false, installed.previous)
      end
    end
  end
  inline_maps = {}
  local spec = cfg().keymaps.inline or {}
  local function install(value, modes)
    for _, entry in ipairs(keymaps.expand(value, modes)) do
      local previous = global_map(entry.mode, entry.lhs)
      local callback = function()
        require("acp.inline").open()
      end
      vim.keymap.set(entry.mode, entry.lhs, callback, { desc = "acp.nvim: inline prompt" })
      inline_maps[#inline_maps + 1] = {
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

local function set_chat_keymaps()
  keymaps.attach_chat(S.chat.buf, {
    keymaps = cfg().keymaps.chat,
    on_hide = function()
      M.hide()
    end,
    on_focus_input = function()
      M.focus("input")
    end,
    on_toggle_block = function()
      if not S.chat:toggle_current() then
        M.focus("input")
      end
    end,
    on_prev_block = function()
      S.chat:jump_block(-1)
      update_chat_title()
    end,
    on_next_block = function()
      S.chat:jump_block(1)
      update_chat_title()
    end,
    on_open_location = function()
      if S.chat:activate_page() then
        return
      end
      M.open_location()
    end,
    on_help = function()
      M.show_help()
    end,
    on_add_selection = function()
      M.add_selection()
    end,
    on_add_file = function()
      M.add_file()
    end,
    on_add_diagnostics = function()
      M.add_diagnostics()
    end,
    on_pick_model = function()
      M.pick_model()
    end,
    on_pick_mode = function()
      M.pick_mode()
    end,
    on_new_session = function()
      M.new_session()
    end,
    on_pick_session = function()
      M.pick_session()
    end,
    on_scroll_bottom = function()
      S.chat:scroll_to_bottom()
      update_chat_title()
    end,
    on_scroll_top = function()
      S.chat:scroll_to_top()
      update_chat_title()
    end,
  })
end

---Show the panel, starting the agent when needed.
function M.open()
  if S.panel then
    S.panel:set_views(S.chat, S.input)
    S.panel:show()
  end
  sync_spinner()

  if S.connection == "ready" then
    if not S.session then
      M.new_session()
    end
    return
  end
  if S.connection == "starting" then
    return
  end
  M.connect()
end

---Hide the panel without stopping the session.
function M.hide()
  if S.panel then
    S.panel:set_views(S.chat, S.input)
    S.panel:hide()
  end
  stop_spinner()
end

function M.toggle()
  if S.panel and S.panel:is_visible() then
    M.hide()
  else
    M.open()
  end
end

---@param which "input"|"chat"
function M.focus(which)
  if S.panel and S.panel:focus(which) then
    return
  end
  M.open()
end

---------------------------------------------------------------------------
-- connection & sessions
---------------------------------------------------------------------------

function M.connect()
  S.connection_service:connect()
end

function M.disconnect()
  pcall(function()
    require("acp.inline").stop()
  end)
  S.connection_service:disconnect()
end

---Reconnect after a crash or an explicit disconnect.
function M.reconnect()
  S.connection_service:reconnect()
end

---Reload the current session after a reconnect, replaying agent-side history.
---@param session_id string
function M.reload_session(session_id)
  if S.connection ~= "ready" or not S.client or not S.sessions_service then
    return
  end
  S.sessions_service:restore(session_id)
end

---Create a new session with the current agent.
function M.new_session()
  if S.sessions_service then
    S.sessions_service:create(function()
      M.connect()
    end)
  end
end

---Load a previous session, replaying its history.
---@param session_id string
function M.load_session(session_id)
  if S.sessions_service then
    S.sessions_service:load(session_id)
  end
end

---Browse stored sessions. <CR> opens, <C-d> deletes, typing filters.
function M.pick_session()
  if S.sessions_service then
    S.sessions_service:pick()
  end
end

---Open the session browser ready to delete (same dialog, <C-d> is the action).
function M.delete_session_flow()
  M.pick_session()
end

---------------------------------------------------------------------------
-- prompts
---------------------------------------------------------------------------

local function add_system_block(text, kind, target)
  local session = target or S.session
  if not session then
    return
  end
  session:append({ id = "sys:" .. tostring(#session.blocks), kind = kind or "error", text = text })
  if S.chat and S.session == session then
    S.chat:schedule_render()
  end
end

---Send the composer contents.
function M.send_now(text, attachments, target)
  return S.prompts:send(target or S.session, text, attachments)
end

---Inline is a normal turn in the selected session, not a new ACP session.
function M.send_inline(session, text, hooks)
  if session ~= S.session then
    return false
  end
  return S.prompts:send(session, text, nil, hooks)
end

---Submit from the composer.
---@param text string
---@param attachments table[]
function M.submit(text, attachments)
  if not S.session then
    notify("No active session", vim.log.levels.WARN)
    return
  end
  -- Only clear the composer when the message was actually accepted; clearing
  -- after a no-op send silently discarded what the user typed.
  local session, input = S.session, S.input
  local accepted = M.send_now(text, attachments)
  if accepted and input then
    if S.input == input and S.session == session then
      input:clear()
    else
      input:discard_draft(session)
    end
  end
  refresh_chrome()
end

---Cancel the active turn.
function M.cancel()
  local session = current()
  if not session then
    return
  end
  local inline = package.loaded["acp.inline"]
  if inline and inline.stop(session) then
    refresh_chrome()
    return
  end
  if not session:cancel_turn() then
    return
  end
  if S.client then
    S.client:cancel(session.id)
  end
  refresh_chrome()
  if S.chat then
    S.chat:schedule_render()
  end
end
---------------------------------------------------------------------------
-- client events
---------------------------------------------------------------------------

---@param name string
---@param payload any
function M.on_client_event(name, payload)
  -- The current inline turn answers permissions; updates still reach chat.
  if require("acp.inline").handle(name, payload) then
    return
  end
  if name == "starting" then
    S.connection = "starting"
    refresh_chrome()
    return
  end

  if name == "ready" then
    S.connection = "ready"
    refresh_chrome()
    return
  end

  if name == "session_update" then
    local update = payload.update or {}
    local session, changed = S.runtime:apply(payload.sessionId, update)
    if not session then
      log.debug("dropping update for unknown session %s", tostring(payload.sessionId))
      return
    end
    if changed then
      prune_sessions()
    end
    if changed and S.session == session and S.chat then
      S.chat:schedule_render()
      if not S.replaying then
        refresh_chrome()
      end
    end
    return
  end

  if name == "permission_request" then
    local entry, auto = S.permissions:request(payload)
    refresh_chrome()
    if auto ~= nil then
      S.permissions:resolve(payload.key, auto)
      return
    end
    if not S.permissions:should_prompt() then
      return
    end
    local client, generation = S.client, operations.generation
    vim.schedule(function()
      if ui_current(client, generation) and S.pending_permissions[payload.key] == entry then
        M.show_permission(payload)
      end
    end)
    return
  end

  if name == "permission_resolved" then
    S.permissions:resolved(payload.key)
    refresh_chrome()
    return
  end

  if name == "prompt_finished" then
    local session = S.sessions[payload.session_id]
    if session and session.prompt_task then
      return
    end -- its scoped task owns settlement
    -- `send_now` settles the turn itself and may already have started the next
    -- queued turn. This event is delivered asynchronously, so only act when it
    -- still refers to the turn that is currently running: otherwise it used to
    -- mark a freshly started turn as idle, and the following prompt hit the
    -- agent's "session already has an active prompt" error.
    if session and session.status ~= "idle" and (payload.turn == nil or session.turn == payload.turn) then
      session:finish_turn(payload.ok and (payload.result and payload.result.stopReason) or "error")
      refresh_chrome()
      if S.chat then
        S.chat:schedule_render()
      end
    end
    return
  end

  if name == "exit" then
    local interrupted = S.connection_service:lost(payload)
    if interrupted then
      add_system_block("Agent disconnected" .. "  :Acp reconnect", "error")
    end
    notify("Agent disconnected" .. "  :Acp reconnect", vim.log.levels.WARN)
    return
  end

  if name == "connection_error" then
    log.error("connection error: %s", vim.inspect(payload))
    return
  end
end

---Open the permission picker for a pending request.
---@param payload table
function M.show_permission(payload)
  S.permissions:show(payload)
end

---Resolve a pending permission request.
---@param key string
---@param option_id string|nil
---@param dismissed boolean|nil when true, prefer an explicit reject option
function M.resolve_permission(key, option_id, dismissed)
  S.permissions:resolve(key, option_id, dismissed)
end

---Reopen the oldest pending permission request.
function M.show_pending_permission()
  S.permissions:show_pending()
end

---------------------------------------------------------------------------
-- context actions
---------------------------------------------------------------------------

function M.pick_file(opts)
  if S.input and S.input:is_visible() then
    return require("acp.completion.picker").open(S.input.buf, S.input.win, opts)
  end
  notify("Open the ACP composer before choosing a file", vim.log.levels.WARN)
end

---Attach an image file to the composer.
---@param path string
---@return boolean
function M.add_image(path)
  local attachment, err = context.image(path, cfg())
  if not attachment then
    notify(err or "unable to attach image", vim.log.levels.WARN)
    return false
  end
  return M.add_image_attachment(attachment)
end

---Drop expired clipboard images. Runs when the composer gains an image, so the
---cache is cleaned at the moment it is being used rather than on a timer.
local function prune_image_cache()
  local images = cfg().context.images
  local protected = require("acp.storage.drafts").image_paths()
  local seen = {}
  local function collect(value)
    if type(value) ~= "table" or seen[value] then
      return
    end
    seen[value] = true
    if value.kind == "image" and value.path then
      protected[value.path] = true
    end
    for _, child in pairs(value) do
      if type(child) == "table" then
        collect(child)
      end
    end
  end
  if S.input then
    collect(S.input.attachments)
    collect(S.input.drafts)
    for att in pairs(S.input.image_marks) do
      collect(att)
    end -- undoable deletions
  end
  for _, session in pairs(S.sessions) do
    collect(session.queue)
    collect(session.blocks)
  end
  local ok, removed = pcall(require("acp.context.image").prune, images.ttl_hours, images.max_cache_bytes, protected)
  if ok and removed and removed > 0 then
    require("acp.log").debug("pruned %d cached image(s)", removed)
  end
end

---Add an already-built image attachment, enforcing the shared limits.
---@param attachment table
---@return boolean
function M.add_image_attachment(attachment, position)
  local images = cfg().context.images
  if images.enabled == false then
    notify("Image attachments are disabled (context.images.enabled)", vim.log.levels.WARN)
    return false
  end
  if not S.input then
    notify("Open the ACP composer before attaching an image", vim.log.levels.WARN)
    return false
  end
  if not S.session then
    notify("No active session", vim.log.levels.WARN)
    return false
  end
  local count = 0
  S.input:sync_images()
  local duplicate = false
  for _, att in ipairs(S.input.attachments) do
    if att.kind == "image" then
      count = count + 1
      if att.path == attachment.path and att.uri == attachment.uri then
        duplicate = true
      end
    end
  end
  if not duplicate and count >= images.max_per_message then
    notify(string.format("At most %d images per message", images.max_per_message), vim.log.levels.WARN)
    return false
  end
  S.input:add_attachment(attachment, position)
  refresh_chrome()
  prune_image_cache()
  notify(string.format("image: %s (%.1f KB)", attachment.label, attachment.bytes / 1024), vim.log.levels.INFO)
  return true
end

---Read an image from the system clipboard and attach it.
---
---The terminal only forwards image bytes to full-screen TUIs that own the
---clipboard, so this runs a platform helper in the background and never blocks
---the editor while the user waits.
---@param opts {command?: string[]|false}|nil
---@return boolean started
function M.paste_image(opts)
  local images = cfg().context.images
  if images.enabled == false then
    notify("Image attachments are disabled (context.images.enabled)", vim.log.levels.WARN)
    return false
  end
  if not S.session or not S.input then
    notify("Open the ACP composer before pasting an image", vim.log.levels.WARN)
    return false
  end
  local command = (opts and opts.command) or (images.clipboard ~= false and images.clipboard or nil)
  if type(command) == "string" then
    -- "auto" selects the platform chain; a user-supplied argv is passed on.
    command = nil
  end
  if not command and images.clipboard == false then
    notify("Clipboard image reading is disabled (context.images.clipboard)", vim.log.levels.WARN)
    return false
  end
  local session = S.session
  -- Record where the user was before the asynchronous read. Attaching must not
  -- move the cursor, edit the buffer or yank focus out of another window: the
  -- chip is extra state, not text.
  local input, config = S.input, cfg()
  local epoch = input.draft_epoch
  local anchor = input:image_anchor()
  notify("Reading image from clipboard…", vim.log.levels.INFO)
  require("acp.context.clipboard").read({
    command = command,
    max_bytes = images.max_bytes,
  }, function(bytes, mime, err)
    local position = input:take_image_anchor(anchor)
    -- The selection may have changed while the helper was running.
    if S.session ~= session or S.input ~= input or cfg() ~= config or input.draft_epoch ~= epoch or not position then
      return
    end
    if not bytes then
      if err then
        notify(err, vim.log.levels.WARN)
      else
        notify("Clipboard does not contain an image", vim.log.levels.INFO)
      end
      return
    end
    local attachment, store_err = context.image_bytes(bytes, mime, cfg())
    if not attachment then
      notify(store_err or "unable to attach image", vim.log.levels.WARN)
      return
    end
    -- The attachment is already built from bytes we just read; adding it by
    -- path would read the file a second time for nothing.
    if not M.add_image_attachment(attachment, position) then
      return
    end
  end)
  return true
end

function M.add_file(path)
  if not S.session then
    notify("No active session", vim.log.levels.WARN)
    return
  end
  local target = path
  if not target or target == "" then
    target = vim.api.nvim_buf_get_name(0)
    if target == "" then
      notify("current buffer has no file", vim.log.levels.WARN)
      return
    end
  end
  local attachment, err = context.file(target, cfg())
  if not attachment then
    notify(err or "unable to attach file", vim.log.levels.WARN)
    return
  end
  S.input:add_attachment(attachment)
  refresh_chrome()
  notify("file" .. ": " .. attachment.label, vim.log.levels.INFO)
end

function M.add_selection()
  -- The composer has focus, so the selection lives in the last real editor
  -- window. With no visual marks, take its current line instead.
  local source = layout.saved_focus()
  local bufnr = source and vim.api.nvim_win_is_valid(source) and vim.api.nvim_win_get_buf(source) or nil
  local line = source and vim.api.nvim_win_is_valid(source) and vim.api.nvim_win_get_cursor(source)[1] or nil
  local attachment, err = context.selection(cfg(), {
    bufnr = bufnr,
    line = line,
    include_current_line = true,
    embedded = S.client and S.client:supports_prompt("embeddedContext") or false,
  })
  if not attachment then
    notify(err or "unable to attach selection", vim.log.levels.WARN)
    return
  end
  if not S.input then
    S.pending_selections = S.pending_selections or {}
    S.pending_selections[#S.pending_selections + 1] = attachment
    return
  end
  S.input:add_attachment(attachment)
  refresh_chrome()
  notify("selection" .. ": " .. attachment.label, vim.log.levels.INFO)
  M.focus("input")
end

function M.add_diagnostics()
  local attachment, err = context.diagnostics(cfg())
  if not attachment then
    notify(err or "unable to attach diagnostics", vim.log.levels.WARN)
    return
  end
  S.input:add_attachment(attachment)
  refresh_chrome()
end

---Open the file location on the current transcript line.
function M.open_location()
  local loc = S.chat and S.chat:location_at_cursor()
  if not loc or not loc.path then
    -- Fall back to the block's first location.
    local block = S.chat and S.chat:block_at_cursor()
    if block and block.locations and #block.locations > 0 then
      loc = block.locations[1]
    end
  end
  if not loc or not loc.path then
    notify("No file location under cursor", vim.log.levels.INFO)
    return
  end
  local path = loc.path
  if vim.fn.filereadable(path) ~= 1 then
    notify("file does not exist: " .. path, vim.log.levels.WARN)
    return
  end
  -- Reuse the last non-ACP window so the panel keeps its layout.
  local target = layout.saved_focus()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd("wincmd p")
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  if loc.line then
    pcall(vim.api.nvim_win_set_cursor, 0, { loc.line, 0 })
    vim.cmd("normal! zz")
  end
end

---------------------------------------------------------------------------
-- config option pickers
---------------------------------------------------------------------------

---@param category string
---@param title string
function M.pick_option(category, title)
  S.options:pick(category, title)
end

function M.pick_model()
  S.options:pick_model()
end

function M.pick_mode()
  S.options:pick_mode()
end

function M.pick_config()
  S.options:pick_config()
end

---------------------------------------------------------------------------
-- misc commands
---------------------------------------------------------------------------

function M.copy_transcript()
  if not S.chat then
    return
  end
  local text = S.chat:transcript()
  vim.fn.setreg("+", text)
  notify("transcript copied to the clipboard", vim.log.levels.INFO)
end

function M.show_help()
  windows.show_help(S.config and S.config.keymaps or nil)
end

function M.show_log()
  windows.show_log(notify)
end

function M.debug_state()
  local session = current()
  print(vim.inspect({
    connection = S.connection,
    session = session and session.id or nil,
    blocks = session and #session.blocks or 0,
    status = session and session.status or nil,
    queue = session and #session.queue or 0,
    pending_permissions = vim.tbl_count(S.pending_permissions),
    transport = S.client and S.client.transport_stats and S.client:transport_stats() or nil,
    render = S.chat and S.chat:render_stats() or nil,
    spinner = S.chrome and S.chrome:diagnostics() or nil,
    panel = {
      chat = S.chat and S.chat.win or nil,
      input = S.input and S.input.win or nil,
    },
  }))
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

function M.setup(opts, action)
  local merged = config_mod.merge(config_mod.defaults, opts or {})
  local ok, err = pcall(config_mod.validate, merged)
  if not ok then
    error(err, 0)
  end
  if not (action and action.discard_queued == true) then
    for _, session in pairs(S.sessions) do
      if #session.queue > 0 or (session.outbox and session.outbox.reserved) then
        error(
          "acp.nvim: cannot reconfigure with queued messages; drain them first or explicitly pass { discard_queued = true } as the second setup argument",
          0
        )
      end
    end
  end
  if S.input then
    pcall(S.input.save_draft, S.input)
  end
  invalidate_operations()
  S.config = merged

  log.setup(merged.log)
  work.configure(merged.ui.render.budget_ms)
  highlights.setup(merged.ui.highlights)
  layout.setup(merged)

  -- Reconfiguring means a different agent, cwd or UI: drop the old runtime
  -- state instead of mixing sessions from two configurations.
  stop_spinner()
  if S.chrome then
    S.chrome:destroy()
  end

  -- Release the previous panel: windows belong to the previous Chat/Input
  -- objects, which are replaced below. Leaving them open would strand windows
  -- that nothing tracks.
  if S.panel then
    S.panel:set_views(S.chat, S.input)
    S.panel:destroy()
  end

  if S.client then
    pcall(S.client.shutdown, S.client, true)
    S.client = nil
  end
  S.session = nil
  S.sessions = {}
  S.runtime = Runtime.new(merged.memory, S.sessions, merged.ui.thoughts)
  S.titles, S.session_cwds = {}, {}
  S.catalog = Catalog.new({
    titles = function()
      return S.titles
    end,
    cwds = function()
      return S.session_cwds
    end,
    client = function()
      return S.client
    end,
    connection = function()
      return S.connection
    end,
    run = function(key, client, session, fn, on_error, on_finally)
      return operations:run(key, client, session, fn, on_error, on_finally)
    end,
    on_changed = refresh_chrome,
    notify = notify,
  })
  S.pending_permissions = {}
  S.permissions = Permissions.new({
    pending = function()
      return S.pending_permissions
    end,
    config = cfg,
    client = function()
      return S.client
    end,
    on_changed = refresh_chrome,
    valid = function(entry, key)
      return entry ~= nil and ui_current(S.client, operations.generation) and S.pending_permissions[key] == entry
    end,
    notify = notify,
  })

  S.options = Options.new({
    config = cfg,
    current = current,
    client = function()
      return S.client
    end,
    generation = function()
      return operations.generation
    end,
    ui_current = ui_current,
    run = function(key, client, session, fn, on_error)
      return operations:run(key, client, session, fn, on_error)
    end,
    on_changed = refresh_chrome,
    notify = notify,
  })
  S.chrome = Chrome.new({
    config = cfg,
    current = current,
    session_label = session_label,
    waiting = waiting_permission,
    chat = function()
      return S.chat
    end,
    input = function()
      return S.input
    end,
  })
  S.sessions_service = Sessions.new({
    config = cfg,
    runtime = function()
      return S.runtime
    end,
    catalog = S.catalog,
    client = function()
      return S.client
    end,
    connection = function()
      return S.connection
    end,
    generation = function()
      return operations.generation
    end,
    new_local = new_local_session,
    resolve_cwd = resolve_cwd,
    run = function(key, client, session, fn, on_error, on_finally)
      return operations:run(key, client, session, fn, on_error, on_finally)
    end,
    cancel_session = function(session, except)
      return operations:cancel_session(session, except)
    end,
    current = current,
    activate = activate_session,
    render = function()
      if S.chat then
        S.chat:render(true)
      end
    end,
    dispatch_queued = dispatch_queued,
    on_changed = refresh_chrome,
    on_replaying = function(value)
      S.replaying = value
      if S.client and S.client.mark_phase then
        S.client:mark_phase(value and "replay" or nil)
      end
    end,
    on_creating = function(value)
      S.creating_session = value
    end,
    prune = prune_sessions,
    notify = notify,
  })
  S.prompts = Prompts.new({
    config = cfg,
    runtime = function()
      return S.runtime
    end,
    client = function()
      return S.client
    end,
    connection = function()
      return S.connection
    end,
    run = function(key, client, session, fn, on_error, on_finally)
      return operations:run(key, client, session, fn, on_error, on_finally)
    end,
    selected = function(session)
      return S.session == session
    end,
    on_turn_start = function(session)
      if S.chat and S.session == session then
        S.chat.follow = true
        S.chat:schedule_render()
      end
    end,
    on_turn_end = function(session)
      if S.session == session then
        stop_spinner()
      end
    end,
    on_changed = refresh_chrome,
    on_render = function(session)
      if S.chat and S.session == session then
        S.chat:schedule_render()
      end
    end,
    add_block = add_system_block,
    prune = prune_sessions,
    dispatch_queued = dispatch_queued,
    refresh_title = refresh_session_title,
    notify = notify,
  })
  S.connection_service = Connection.new({
    config = cfg,
    resolve_cwd = resolve_cwd,
    state = function()
      return S
    end,
    generation = function()
      return operations.generation
    end,
    reset_operations = invalidate_operations,
    on_event = function(name, payload)
      return M.on_client_event(name, payload)
    end,
    notify = notify,
    on_changed = refresh_chrome,
    on_ready = function()
      local reload_id = S.connection_service:take_pending_reload()
      if reload_id then
        M.reload_session(reload_id)
      elseif S.session and S.session.needs_load then
        M.reload_session(S.session.id)
      elseif not S.session then
        M.new_session()
      end
    end,
    on_start_failed = function(err)
      local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
      if message:match("auth") then
        notify(
          "OpenCode requires authentication. Run `opencode auth login` in a terminal, then reconnect.",
          vim.log.levels.WARN
        )
      else
        notify("failed to start agent: " .. message, vim.log.levels.ERROR)
      end
    end,
    runtime_lost = function()
      S.runtime:connection_lost()
    end,
    reset_permissions = function()
      if S.permissions then
        S.permissions:reset()
      end
      S.pending_permissions = {}
    end,
    stop_animation = stop_spinner,
    on_render = function()
      if S.chat then
        S.chat:schedule_render()
      end
    end,
  })
  S.connection = "stopped"
  S.replaying = false
  S.creating_session = false

  S.panel = Panel.new({
    config = cfg,
    notify = notify,
    on_windows_ready = function()
      update_chat_title()
      refresh_chrome()
    end,
  })

  S.chat = Chat.new({ config = merged })
  S.chat.on_pending_new = function()
    update_chat_title()
  end
  S.input = Input.new({
    config = merged,
    on_submit = function(text, attachments)
      M.submit(text, attachments)
    end,
    on_cancel = function()
      M.cancel()
    end,
  })
  S.input.on_refresh = function()
    update_input_toolbar()
  end
  S.input.on_draft = function(key, text, attachments, owner)
    local session = owner or S.sessions[key]
    if not session then
      return
    end
    drafts.put(session.cwd, session.id, text, attachments)
  end
  if S.pending_selections then
    for _, selection in ipairs(S.pending_selections) do
      S.input:add_attachment(selection)
    end
    S.pending_selections = nil
  end

  -- Mappings and completion belong to buffers, not windows. Hiding, reopening
  -- or repairing a missing view reuses these buffers and needs no reattachment.
  set_input_keymaps()
  set_chat_keymaps()
  set_inline_keymaps()
  S.panel:set_views(S.chat, S.input)

  -- Re-attach the active session to the freshly created views.
  if S.session then
    S.chat:set_session(S.session)
    S.input:switch_session(S.session.id, nil, S.session)
  end

  setup_window_events()

  -- Click regions in the winbar only respond when the mouse is enabled. Say so
  -- once instead of leaving the user with a toolbar that looks clickable but
  -- is not.
  if merged.ui.toolbar.placement ~= "off" and not S.click_hint_shown then
    S.click_hint_shown = true
    vim.schedule(function()
      if not vim.o.mouse:find("[anvi]") then
        vim.notify(
          string.format(
            "acp.nvim: 'mouse' is %q, so the model/mode toolbar is not clickable. "
              .. "Enable mouse support (e.g. set mouse=nvi) or use <M-m> / <M-b>.",
            vim.o.mouse
          ),
          vim.log.levels.INFO
        )
      end
    end)
  end
end

---Access the shared controller state (read-only, for integrations).
---@return table
function M.state()
  return S
end

---Winbar render callback, evaluated by Vim on every redraw.
function _G.AcpComposerBar()
  return M.composer_bar()
end

---Transcript winbar render callback.
function _G.AcpTranscriptBar()
  return M.chat_bar()
end

---Winbar click handlers. These must be plain globals so `%@v:lua.Name@` works.
function _G.AcpPickModel()
  M.pick_model()
end

function _G.AcpPickMode()
  M.pick_mode()
end

return M
