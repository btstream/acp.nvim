-- Application controller: wires protocol, session state, layout and UI.
local config_mod = require("acp.config")
local log = require("acp.log")
local async = require("acp.async")
local client_mod = require("acp.protocol.client")
local session_mod = require("acp.session.state")
local reducer = require("acp.session.reducer")
local Chat = require("acp.ui.chat")
local Input = require("acp.ui.input")
local toolbar = require("acp.ui.toolbar")
local picker = require("acp.ui.picker")
local session_picker = require("acp.ui.session_picker")
local session_snacks = require("acp.ui.session_snacks")
local Icons = require("acp.ui.icons")
local highlights = require("acp.ui.highlights")
local complete = require("acp.ui.complete")
local drafts = require("acp.storage.drafts")
local layout = require("acp.layout")
local context = require("acp.context")

local M = {}

local S = {
  config = nil,
  client = nil,
  session = nil,
  sessions = {},
  -- session_id -> title, learned from session/list. Session objects are often
  -- recreated (load/reconnect), so titles live here rather than on the object.
  titles = {},
  chat = nil,
  input = nil,
  panel_requested = false,
  connection = "stopped", -- stopped | starting | ready | disconnected
  pending_permissions = {},
  replaying = false,
  spinner = nil,
  spinner_timer = nil,
  spinner_index = 1,
  augroup = nil,
}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_ASCII = { "|", "/", "-", "\\" }

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

local function cfg()
  return S.config
end

---Resolve the session working directory.
---@return string
local function resolve_cwd()
  if S.config.cwd then
    return vim.fn.fnamemodify(S.config.cwd, ":p")
  end
  -- Prefer the project root when available, otherwise the current file's directory.
  local ok, root = pcall(function()
    local util = require("lazy.core.util")
    return util.get_root()
  end)
  if ok and type(root) == "string" and root ~= "" then
    return root
  end
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname ~= "" and vim.bo.buftype == "" then
    return vim.fn.fnamemodify(bufname, ":p:h")
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
  local cached = S.titles and S.titles[session.id]
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
  if not session then
    return false
  end
  for _, entry in pairs(S.pending_permissions) do
    if entry.session_id == session.id then
      return true
    end
  end
  return false
end

---Public structured status for statusline components.
---@return table
function M.status()
  local session = current()
  local model_label, mode_label
  if session then
    model_label, mode_label = reducer.toolbar_labels(session)
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
  local glyph = use_icons and Icons.get(true).assistant or "*"
  if not st.connected then
    return glyph .. " off"
  end
  if st.waiting_permission then
    return glyph .. " !"
  end
  if st.running then
    return glyph .. " " .. Icons.get(icons).tool_run
  end
  if st.queued > 0 then
    return glyph .. " +" .. st.queued
  end
  return glyph
end

---------------------------------------------------------------------------
-- chrome updates
---------------------------------------------------------------------------

local function chat_width()
  local win = S.chat and S.chat.win
  if win and vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_win_get_width(win)
  end
  local total = vim.o.columns
  return config_mod.panel_width(cfg(), total)
end

local function update_chat_title()
  if not S.chat then
    return
  end
  local win = S.chat.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if cfg().ui.title.placement == "off" then
    pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
    return
  end
  -- Set once; the expression re-renders with the real width on every redraw.
  pcall(vim.api.nvim_set_option_value, "winbar", "%{%v:lua.AcpTranscriptBar()%}", { win = win })
end

---Build the composer winbar for the window currently being drawn.
---Runs on every redraw, so it must stay cheap and side-effect free.
---@param win integer|nil defaults to the current window
---@return string
function M.composer_bar(win)
  win = win or vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(win)

  if cfg().ui.toolbar.placement == "off" then
    return ""
  end

  local session = current()
  local model, mode
  if session then
    model, mode = reducer.toolbar_labels(session)
  end

  local chips = ""
  local chip_width = 0
  if S.input and #S.input.attachments > 0 then
    local labels = {}
    for _, att in ipairs(S.input.attachments) do
      labels[#labels + 1] = "[" .. att.label .. "]"
    end
    local plain = table.concat(labels, " ")
    chips = "%#AcpUserChip#" .. toolbar.escape(plain) .. "%#AcpToolbar# "
    chip_width = vim.fn.strdisplaywidth(plain) + 1
  end

  local base = toolbar.render({
    icons = cfg().ui.icons,
    mode = mode,
    model = model,
    status = session and session.status or "idle",
    waiting = waiting_permission(session),
    queued = session and #session.queue or 0,
    usage = session and session.usage or nil,
    show_usage = cfg().ui.toolbar.show_usage,
    spinner = S.spinner,
  }, math.max(12, width - chip_width))

  return chips .. base
end

---Build the transcript winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M.chat_bar(win)
  if cfg().ui.title.placement == "off" then
    return ""
  end
  win = win or vim.api.nvim_get_current_win()
  local session = current()
  return toolbar.chat_title({
    icons = cfg().ui.icons,
    agent = cfg().agent,
    title = session_label(session),
    pending_new = S.chat and S.chat.pending_new or false,
    running = session and session.status == "running" or false,
  }, vim.api.nvim_win_get_width(win))
end

local function update_input_toolbar()
  if not S.input then
    return
  end
  local win = S.input.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  S.input:apply_winbar()
end

local function refresh_chrome()
  update_chat_title()
  update_input_toolbar()
end

---Remember an agent-provided title, ignoring JSON null and empty strings.
---@param session_id string
---@param title any
---@return boolean changed
local function cache_title(session_id, title)
  if not session_id then
    return false
  end
  -- JSON null decodes to vim.NIL; that means "no title yet", not "clear it".
  if type(title) ~= "string" or title == "" then
    return false
  end
  if S.titles[session_id] == title then
    return false
  end
  S.titles[session_id] = title
  return true
end

---Apply the cached title to a session object and refresh the chrome.
---@param session AcpSessionState|nil
---@return boolean applied
local function apply_cached_title(session)
  if not session then
    return false
  end
  local title = S.titles[session.id]
  if not title or title == session.title then
    return false
  end
  session.title = title
  return true
end

---Fetch the authoritative title for a session.
---
---OpenCode does not push `session_info_update`, so a title only appears in
---`session/list`. Query it when a session is created, when one is switched to,
---and at the end of each turn (that is when agents auto-generate a title from
---the first prompt).
---@param session AcpSessionState|nil
---@param cb fun()|nil invoked after the lookup settles
local function refresh_session_title(session, cb)
  if not session or not S.client or S.connection ~= "ready" then
    if cb then
      cb()
    end
    return
  end
  if not S.client:has_session_capability("list") then
    if cb then
      cb()
    end
    return
  end
  if S.title_refreshing then
    S.title_pending = true
    if cb then
      cb()
    end
    return
  end
  S.title_refreshing = true
  async.run(function()
    local ok, result = S.client:list_sessions(session.cwd)
    S.title_refreshing = false
    if ok and type(result) == "table" then
      for _, info in ipairs(result.sessions or {}) do
        cache_title(info.sessionId, info.title)
      end
      if apply_cached_title(session) then
        refresh_chrome()
      end
    end
    if cb then
      cb()
    end
    if S.title_pending then
      S.title_pending = false
      refresh_session_title(S.session)
    end
  end)
end

---------------------------------------------------------------------------
-- spinner
---------------------------------------------------------------------------

local function stop_spinner()
  if S.spinner_timer then
    pcall(vim.fn.timer_stop, S.spinner_timer)
    S.spinner_timer = nil
  end
  S.spinner = nil
end

local function start_spinner()
  if not cfg().ui.toolbar.animate then
    S.spinner = cfg().ui.icons and SPINNER[1] or SPINNER_ASCII[1]
    return
  end
  if S.spinner_timer then
    return
  end
  local frames = cfg().ui.icons and SPINNER or SPINNER_ASCII
  S.spinner_index = 1
  S.spinner = frames[1]
  S.spinner_timer = vim.fn.timer_start(cfg().ui.toolbar.animation_interval or 120, function()
    -- Do not animate while the panel is not visible.
    if not S.input or not S.input:is_visible() then
      return
    end
    S.spinner_index = (S.spinner_index % #frames) + 1
    S.spinner = frames[S.spinner_index]
    update_input_toolbar()
  end, { ["repeat"] = -1 })
end

---------------------------------------------------------------------------
-- session switching
---------------------------------------------------------------------------

---@param session AcpSessionState
local function activate_session(session)
  S.session = session
  if S.chat then
    S.chat:set_session(session)
    S.chat.pending_new = false
  end
  if S.input then
    local restored = session and drafts.get(session.cwd, session.id) or nil
    S.input:switch_session(session and session.id or nil, restored)
  end
  refresh_chrome()
end

---------------------------------------------------------------------------
-- window lifecycle
---------------------------------------------------------------------------

local function setup_window_events()
  if S.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
  end
  S.augroup = vim.api.nvim_create_augroup("AcpPanel", { clear = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = S.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      layout.forget_window(win)
      if S.chat and S.chat.win == win then
        S.chat.win = nil
      end
      if S.input and S.input.win == win then
        S.input.win = nil
      end
      if (not S.chat or S.chat.win == nil) and (not S.input or S.input.win == nil) then
        stop_spinner()
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = S.augroup,
    callback = function()
      vim.schedule(function()
        refresh_chrome()
      end)
    end,
  })

  -- Window-local resizes (splits, layout managers, mouse dragging) do not fire
  -- VimResized, so refresh the winbars explicitly.
  vim.api.nvim_create_autocmd({ "WinResized", "WinNew", "WinClosed" }, {
    group = S.augroup,
    callback = function()
      vim.schedule(function()
        refresh_chrome()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = S.augroup,
    callback = function()
      stop_spinner()
      if S.input then
        pcall(S.input.save_draft, S.input)
      end
      if S.client then
        -- Do not let a stray agent process outlive the editor.
        S.client:shutdown(true)
        S.client = nil
      end
    end,
  })
end

local function set_input_keymaps()
  local buf = S.input.buf
  local km = cfg().keymaps
  local function map(mode, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "acp: " .. desc })
  end
  map({ "n", "i" }, km.send, function()
    -- Ctrl-S submits; when a turn is running and the composer is empty it stops instead.
    local running = S.session and S.session.status == "running"
    if running and S.input:text():match("^%s*$") and #S.input.attachments == 0 then
      M.cancel()
      return
    end
    S.input:submit()
  end, "send")
  map("n", km.cancel, function()
    M.cancel()
  end, "cancel")
  map("n", "q", function()
    M.hide()
  end, "hide panel")
  map("n", "<C-]>", function()
    M.add_selection()
  end, "add selection")
  -- Model/mode are reachable with the mouse (click the winbar), from normal
  -- mode, and with Alt combinations while typing. `<C-m>` must not be used: in
  -- a terminal it is the same key as <CR>.
  map("n", "M", function()
    M.pick_model()
  end, "pick model")
  map("n", "m", function()
    M.pick_mode()
  end, "pick mode")
  map("i", "<M-m>", function()
    M.pick_model()
  end, "pick model")
  map("i", "<M-b>", function()
    M.pick_mode()
  end, "pick mode")
  map("n", "L", function()
    M.pick_session()
  end, "sessions")

  complete.attach(buf, function()
    return S.session
  end)
end

local function set_chat_keymaps()
  local buf = S.chat.buf
  local km = cfg().keymaps
  local function map(mode, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = "acp: " .. desc })
  end
  map("n", km.close_panel, function()
    M.hide()
  end, "hide panel")
  map("n", km.focus_input, function()
    M.focus("input")
  end, "focus composer")
  map("n", km.toggle_block, function()
    if not S.chat:toggle_current() then
      M.focus("input")
    end
  end, "toggle block")
  map("n", km.prev_block, function()
    S.chat:jump_block(-1)
    update_chat_title()
  end, "previous block")
  map("n", km.next_block, function()
    S.chat:jump_block(1)
    update_chat_title()
  end, "next block")
  map("n", km.open_location, function()
    M.open_location()
  end, "open location")
  map("n", "g?", function()
    M.show_help()
  end, "help")
  map("n", "<C-s>", function()
    M.focus("input")
  end, "focus composer")
  map("n", "S", function()
    M.add_selection()
  end, "add selection")
  map("n", "F", function()
    M.add_file()
  end, "add file")
  map("n", "R", function()
    M.add_diagnostics()
  end, "add diagnostics")
  map("n", "M", function()
    M.pick_model()
  end, "pick model")
  map("n", "m", function()
    M.pick_mode()
  end, "pick mode")
  map("n", "<C-n>", function()
    M.new_session()
  end, "new session")
  map("n", "L", function()
    M.pick_session()
  end, "sessions")
  map("n", "G", function()
    S.chat:scroll_to_bottom()
    update_chat_title()
  end, "jump to latest")
  map("n", "gg", function()
    S.chat:scroll_to_top()
    update_chat_title()
  end, "jump to start")
end

local function ensure_windows()
  if S.chat:is_visible() and S.input:is_visible() then
    return
  end

  layout.remember_focus()

  if not S.chat:is_visible() then
    local win = layout.create_chat_win(S.chat.buf)
    if not win then
      notify("unable to create the chat window", vim.log.levels.ERROR)
      return
    end
    S.chat.win = win
  end

  if not S.input:is_visible() then
    local win = layout.create_input_win(S.input.buf, S.chat.win)
    if not win then
      notify("unable to create the composer window", vim.log.levels.ERROR)
      return
    end
    S.input.win = win
  end

  set_input_keymaps()
  set_chat_keymaps()
  refresh_chrome()
  S.chat:render(true)
end

---Show the panel, starting the agent when needed.
function M.open()
  S.panel_requested = true
  ensure_windows()

  local focus_input = cfg().layout.focus_input_on_open
  if focus_input and S.input and S.input:is_visible() then
    vim.api.nvim_set_current_win(S.input.win)
    vim.cmd("startinsert")
  end

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
  S.panel_requested = false
  if S.input and S.input:is_visible() then
    S.input:save_draft()
  end
  stop_spinner()
  local acp_windows = {}
  for _, view in ipairs({ S.input, S.chat }) do
    if view and view.win and vim.api.nvim_win_is_valid(view.win) then
      acp_windows[#acp_windows + 1] = view.win
    end
    if view then
      view.win = nil
    end
  end
  local remaining = #vim.api.nvim_list_wins() - #acp_windows
  if remaining <= 0 and #acp_windows > 0 then
    -- Never leave Neovim without a window; keep one and show a scratch buffer.
    -- The window is locked, so unlock it before replacing the panel buffer.
    local keep = acp_windows[1]
    table.remove(acp_windows, 1)
    layout.set_window_buffer(keep, vim.api.nvim_create_buf(true, false))
  end
  for _, win in ipairs(acp_windows) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  local target = cfg().layout.restore_focus and layout.saved_focus() or nil
  if target and vim.api.nvim_win_is_valid(target) then
    pcall(vim.api.nvim_set_current_win, target)
  end
  layout.clear_saved_focus()
end

function M.toggle()
  local visible = (S.chat and S.chat:is_visible()) or (S.input and S.input:is_visible())
  if visible then
    M.hide()
  else
    M.open()
  end
end

---@param which "input"|"chat"
function M.focus(which)
  if which == "input" then
    if S.input and S.input:is_visible() then
      vim.api.nvim_set_current_win(S.input.win)
      vim.cmd("startinsert")
      return
    end
  else
    if S.chat and S.chat:is_visible() then
      vim.api.nvim_set_current_win(S.chat.win)
      return
    end
  end
  M.open()
end

---------------------------------------------------------------------------
-- connection & sessions
---------------------------------------------------------------------------

local function build_client_capabilities()
  -- Only advertise what is actually implemented, and encode capability
  -- objects as JSON objects (vim.empty_dict) rather than empty arrays.
  local caps = vim.empty_dict()
  if cfg().notices then
    caps = { session = { notices = vim.empty_dict() } }
  end
  return caps
end

function M.connect()
  if S.connection == "starting" then
    return
  end
  S.connection = "starting"
  refresh_chrome()

  if not S.client then
    local client
    client = client_mod.new({
      agent = cfg().agents[cfg().agent],
      cwd = resolve_cwd(),
      client_capabilities = build_client_capabilities(),
      limits = cfg().transport,
      on_event = function(name, payload)
        vim.schedule(function()
          -- Ignore late events from a client we already replaced, otherwise a
          -- shutdown "exit" could clobber a fresh connection.
          if S.client ~= client then
            return
          end
          M.on_client_event(name, payload)
        end)
      end,
    })
    S.client = client
  end

  if not S.client:is_ready() then
    S.client:start(function(ok, err)
      vim.schedule(function()
        if ok then
          S.connection = "ready"
          refresh_chrome()
          local reload_id = S.pending_reload
          S.pending_reload = nil
          if reload_id then
            M.reload_session(reload_id)
          elseif not S.session then
            M.new_session()
          end
        else
          S.connection = "disconnected"
          refresh_chrome()
          local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
          if message:match("auth") then
            notify(
              "OpenCode requires authentication. Run `opencode auth login` in a terminal, then reconnect.",
              vim.log.levels.WARN
            )
          else
            notify("failed to start agent: " .. message, vim.log.levels.ERROR)
          end
        end
      end)
    end)
  else
    S.connection = "ready"
    refresh_chrome()
    if not S.session then
      M.new_session()
    end
  end
end

function M.disconnect()
  if S.client then
    S.client:shutdown()
    S.client = nil
  end
  S.connection = "stopped"
  stop_spinner()
  refresh_chrome()
end

---Reconnect after a crash or an explicit disconnect.
function M.reconnect()
  if S.connection == "starting" or S.connection == "ready" then
    return
  end
  local previous = current()
  S.pending_reload = previous and previous.id or nil
  if S.client then
    S.client:shutdown(true)
    S.client = nil
  end
  S.connection = "stopped"
  M.connect()
end

---Reload the current session after a reconnect, replaying agent-side history.
---@param session_id string
function M.reload_session(session_id)
  if S.connection ~= "ready" or not S.client then
    return
  end
  if not S.client:agent_capabilities().loadSession then
    M.new_session()
    return
  end
  local previous = S.sessions[session_id]
  local cwd = previous and previous.cwd or resolve_cwd()
  -- Start from a clean transcript: the agent replays its authoritative history.
  local fresh = session_mod.new(session_id, cwd)
  S.sessions[session_id] = fresh
  activate_session(fresh)
  S.replaying = true
  async.run(function()
    local ok, result = S.client:load_session(session_id, cwd)
    S.replaying = false
    if not ok then
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      if not tostring(message):lower():match("shutdown") then
        notify("unable to restore the session: " .. message, vim.log.levels.WARN)
      end
      M.new_session()
      return
    end
    if result.configOptions then
      fresh.config_options = result.configOptions
    end
    fresh:finish_turn("end_turn")
    if apply_cached_title(fresh) then
      refresh_chrome()
    end
    if S.chat then
      S.chat:set_session(fresh)
      S.chat:render(true)
    end
    refresh_chrome()
    refresh_session_title(fresh)
  end)
end

---Create a new session with the current agent.
function M.new_session()
  if S.connection ~= "ready" or not S.client then
    M.connect()
    return
  end
  local cwd = resolve_cwd()
  async.run(function()
    local ok, result = S.client:new_session(cwd)
    if not ok then
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      notify("unable to create a session: " .. message, vim.log.levels.ERROR)
      return
    end
    local session = session_mod.new(result.sessionId, cwd)
    if result.configOptions then
      session.config_options = result.configOptions
    end
    if result.modes then
      session.modes = result.modes
      session.current_mode = result.currentModeId
    end
    S.sessions[session.id] = session
    activate_session(session)
    S.chat:render(true)
    notify("Session started", vim.log.levels.INFO)
    refresh_session_title(session)
  end)
end

---Load a previous session, replaying its history.
---@param session_id string
function M.load_session(session_id)
  if S.connection ~= "ready" or not S.client then
    notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local cwd = resolve_cwd()
  async.run(function()
    local entry = S.sessions[session_id]
    if entry then
      activate_session(entry)
    else
      entry = session_mod.new(session_id, cwd)
      S.sessions[session_id] = entry
      activate_session(entry)
    end
    S.replaying = true
    local ok, result = S.client:load_session(session_id, cwd)
    S.replaying = false
    if not ok then
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      notify("unable to load session: " .. message, vim.log.levels.ERROR)
      return
    end
    if result.configOptions then
      entry.config_options = result.configOptions
    end
    entry:finish_turn("end_turn")
    -- A freshly built session object carries no title; take it from the cache
    -- so the winbar updates the moment the switch completes.
    if apply_cached_title(entry) then
      refresh_chrome()
    end
    S.chat:render(true)
    refresh_chrome()
    refresh_session_title(entry)
  end)
end

---Delete a session through the agent and drop it from local state.
---@param session_id string
---@param done fun(ok: boolean)
local function delete_session(session_id, done)
  if not S.client then
    done(false)
    return
  end
  async.run(function()
    local ok, result = S.client:delete_session(session_id)
    if not ok then
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      notify(string.format("Unable to delete the session: %s", message), vim.log.levels.ERROR)
      done(false)
      return
    end
    S.sessions[session_id] = nil
    S.titles[session_id] = nil
    if S.session and S.session.id == session_id then
      -- The active conversation is gone; start a fresh one.
      S.session = nil
      if S.chat then
        S.chat:set_session(nil)
        S.chat:render(true)
      end
      if S.input then
        S.input:switch_session(nil)
      end
      M.new_session()
    else
      refresh_chrome()
    end
    notify("Session deleted", vim.log.levels.INFO)
    done(true)
  end)
end

---Fetch the session list, calling `cb(ok, sessions)`.
---
---The directory used for the query is the active session's cwd when one exists,
---falling back to the resolved editor cwd. Those can differ (the session may
---have been created elsewhere), and agents such as OpenCode filter strictly by
---`cwd`, so an empty filtered result is retried without the filter rather than
---reporting that no sessions exist.
---@param cb fun(ok: boolean, sessions: table[])
local function fetch_sessions(cb)
  if not S.client or S.connection ~= "ready" then
    notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  async.run(function()
    local scoped_cwd = (S.session and S.session.cwd) or resolve_cwd()

    local function to_error(result)
      if type(result) == "table" and (result.code == -32601 or result.code == -32602) then
        notify("This agent does not support listing sessions", vim.log.levels.WARN)
      else
        local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
        notify(string.format("Unable to list sessions: %s", message), vim.log.levels.ERROR)
      end
      cb(false, {})
    end

    local ok, result = S.client:list_sessions(scoped_cwd)
    if not ok then
      to_error(result)
      return
    end

    local sessions = result.sessions or {}
    if #sessions == 0 then
      -- Nothing in this directory: show every session the agent knows about.
      local all_ok, all_result = S.client:list_sessions(nil)
      if all_ok and type(all_result) == "table" then
        sessions = all_result.sessions or {}
      end
    end

    -- Keep the title cache warm so switching sessions updates the winbar at once.
    for _, info in ipairs(sessions) do
      cache_title(info.sessionId, info.title)
    end
    cb(true, sessions)
  end)
end

---Browse stored sessions. <CR> opens, <C-d> deletes, typing filters.
function M.pick_session()
  if not S.client or S.connection ~= "ready" then
    notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  fetch_sessions(function(ok, sessions)
    if not ok then
      return
    end
    if #sessions == 0 then
      notify("No stored sessions found", vim.log.levels.INFO)
      return
    end
    local picker_opts = {
      sessions = sessions,
      current_id = S.session and S.session.id or nil,
      can_delete = S.client:has_session_capability("delete"),
      use_icons = cfg().ui.icons,
      on_open = function(session_id)
        M.load_session(session_id)
      end,
      on_delete = function(session_id, done)
        delete_session(session_id, done)
      end,
    }

    -- snacks is the default when it is installed; otherwise fall back to the
    -- built-in window instead of failing.
    if cfg().ui.session_picker == "snacks" and session_snacks.open(picker_opts) then
      return
    end
    session_picker.open(picker_opts)
  end)
end

---Open the session browser ready to delete (same dialog, <C-d> is the action).
function M.delete_session_flow()
  M.pick_session()
end

---Create a new session with the current agent.
function M.new_session()
  if S.connection ~= "ready" or not S.client then
    M.connect()
    return
  end
  local cwd = resolve_cwd()
  async.run(function()
    local ok, result = S.client:new_session(cwd)
    if not ok then
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      notify("unable to create a session: " .. message, vim.log.levels.ERROR)
      return
    end
    local session = session_mod.new(result.sessionId, cwd)
    if result.configOptions then
      session.config_options = result.configOptions
    end
    if result.modes then
      session.modes = result.modes
      session.current_mode = result.currentModeId
    end
    S.sessions[session.id] = session
    activate_session(session)
    S.chat:render(true)
    notify("Session started", vim.log.levels.INFO)
    refresh_session_title(session)
  end)
end

---Load a previous session, replaying its history.
---@param session_id string
function M.load_session(session_id)
  if S.connection ~= "ready" or not S.client then
    notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local cwd = resolve_cwd()
  async.run(function()
    local entry = S.sessions[session_id]
    if entry then
      activate_session(entry)
    else
      entry = session_mod.new(session_id, cwd)
      S.sessions[session_id] = entry
      activate_session(entry)
    end
    S.replaying = true
    local ok, result = S.client:load_session(session_id, cwd)
    S.replaying = false
    if not ok then
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      notify("unable to load session: " .. message, vim.log.levels.ERROR)
      return
    end
    if result.configOptions then
      entry.config_options = result.configOptions
    end
    entry:finish_turn("end_turn")
    -- A freshly built session object carries no title; take it from the cache
    -- so the winbar updates the moment the switch completes.
    if apply_cached_title(entry) then
      refresh_chrome()
    end
    S.chat:render(true)
    refresh_chrome()
    refresh_session_title(entry)
  end)
end

---------------------------------------------------------------------------
-- prompts
---------------------------------------------------------------------------

local function add_system_block(text, kind)
  if not S.session then
    return
  end
  S.session:append({ id = "sys:" .. tostring(#S.session.blocks), kind = kind or "error", text = text })
  S.chat:schedule_render()
end

---Send the composer contents.
function M.send_now(text, attachments)
  if not S.session then
    notify("No active session", vim.log.levels.WARN)
    return
  end
  if S.connection ~= "ready" or not S.client then
    notify("No agent process is running", vim.log.levels.WARN)
    return
  end

  -- Expand @file mentions into attachments before queueing.
  if text and text:find("@", 1, true) then
    local mentioned = context.mentions(text, cfg(), S.session.cwd)
    if #mentioned > 0 then
      local merged = vim.deepcopy(attachments or {})
      for _, att in ipairs(mentioned) do
        local duplicate = false
        for _, existing in ipairs(merged) do
          if existing.path == att.path and existing.kind == att.kind then
            duplicate = true
            break
          end
        end
        if not duplicate then
          merged[#merged + 1] = att
        end
      end
      attachments = merged
    end
  end

  if S.session.status == "running" then
    -- Session already has an active turn: queue locally.
    S.session.queue[#S.session.queue + 1] = { text = text, attachments = attachments }
    refresh_chrome()
    return
  end

  local blocks = context.to_prompt(text, attachments)
  if #blocks == 0 then
    return
  end

  local session = S.session
  session:begin_turn()
  session:add_local_user(text, attachments)
  if S.chat then
    S.chat.follow = true
    S.chat:schedule_render()
  end
  start_spinner()
  refresh_chrome()

  async.run(function()
    local ok, result = S.client:prompt(session.id, blocks)
    if not ok then
      local raw = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      local lowered = tostring(raw):lower()
      if lowered:match("auth") then
        add_system_block("OpenCode requires authentication. Run `opencode auth login` in a terminal, then reconnect.")
      elseif lowered:match("limit") or lowered:match("quota") or lowered:match("rate") then
        -- Provider-side quota problems are not plugin errors; give the user
        -- the one action that actually helps.
        add_system_block(
          raw
            .. "\n\n"
            .. "This is a provider-side limit, not an acp.nvim error. Click the model name in the toolbar, press <M-m> while typing, or run :Acp model."
        )
      else
        add_system_block("prompt failed: " .. raw)
      end
      session:finish_turn("error")
    else
      session:finish_turn(result and result.stopReason or "end_turn")
    end
    stop_spinner()
    refresh_chrome()
    if S.chat then
      S.chat:schedule_render()
    end
    -- The agent auto-generates a title from the first exchange, and it is only
    -- exposed through session/list, so refresh once the turn has settled.
    refresh_session_title(session)
    if S.session == session then
      local next_item = table.remove(session.queue, 1)
      if next_item then
        M.send_now(next_item.text, next_item.attachments)
      end
    end
  end)
end

---Submit from the composer.
---@param text string
---@param attachments table[]
function M.submit(text, attachments)
  if not S.session then
    notify("No active session", vim.log.levels.WARN)
    return
  end
  M.send_now(text, attachments)
  S.input:clear()
  refresh_chrome()
end

---Cancel the active turn.
function M.cancel()
  local session = current()
  if not session then
    return
  end
  if session.status ~= "running" then
    return
  end
  session.status = "cancelling"
  for _, block in ipairs(session.blocks) do
    if block.kind == "tool" and (block.status == "pending" or block.status == "in_progress") then
      block.status = "cancelled"
    end
  end
  if S.client then
    S.client:cancel(session.id)
  end
  refresh_chrome()
  S.chat:schedule_render()
end

---------------------------------------------------------------------------
-- client events
---------------------------------------------------------------------------

---@param name string
---@param payload any
function M.on_client_event(name, payload)
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
    -- Known sessions keep their state even when they are not visible.
    local session = S.sessions[payload.sessionId]
    if not session and S.session and S.session.id == payload.sessionId then
      session = S.session
    end
    if not session then
      log.debug("dropping update for unknown session %s", tostring(payload.sessionId))
      return
    end
    local changed = reducer.apply(session, update)
    if changed and S.session == session and S.chat then
      S.chat:schedule_render()
      if not S.replaying then
        refresh_chrome()
      end
    end
    return
  end

  if name == "permission_request" then
    S.pending_permissions[payload.key] = {
      session_id = payload.session_id,
      tool_call = payload.tool_call,
      options = payload.options,
    }
    refresh_chrome()

    -- Optional auto-approval, explicitly opted in by the user.
    local auto = cfg().permissions.auto_allow or {}
    if #auto > 0 then
      for _, option in ipairs(payload.options or {}) do
        for _, allowed in ipairs(auto) do
          if option.kind == allowed then
            log.info("auto-approving permission via %s", allowed)
            M.resolve_permission(payload.key, option.optionId)
            return
          end
        end
      end
    end

    if cfg().permissions.prompt == "select" then
      M.show_permission(payload)
    else
      notify(
        "Permission required" .. ": " .. (payload.tool_call and payload.tool_call.title or ""),
        vim.log.levels.WARN
      )
    end
    return
  end

  if name == "permission_resolved" then
    S.pending_permissions[payload.key] = nil
    refresh_chrome()
    return
  end

  if name == "prompt_finished" then
    local session = S.sessions[payload.session_id]
    if session and session.status ~= "idle" then
      session:finish_turn(payload.ok and (payload.result and payload.result.stopReason) or "error")
      refresh_chrome()
      S.chat:schedule_render()
    end
    return
  end

  if name == "exit" then
    S.connection = "disconnected"
    stop_spinner()
    local session = current()
    if session and session.status == "running" then
      session:finish_turn("error")
      add_system_block("Agent disconnected" .. "  :Acp reconnect", "error")
    end
    local detail = payload and payload.stderr or ""
    local message = "Agent disconnected"
    if detail and detail ~= "" then
      log.info("agent stderr:\n%s", detail)
    end
    notify(message .. "  :Acp reconnect", vim.log.levels.WARN)
    refresh_chrome()
    if S.chat then
      S.chat:schedule_render()
    end
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
  local tool = payload.tool_call or {}
  local title = tool.title or tool.kind or "tool"
  local items = {}
  for _, option in ipairs(payload.options or {}) do
    items[#items + 1] = {
      label = option.name or option.optionId,
      description = option.kind,
      value = { id = option.optionId, kind = option.kind },
    }
  end

  if #items == 0 then
    notify("the agent sent a permission request without options", vim.log.levels.WARN)
    return
  end

  if tool.locations and #tool.locations > 0 then
    local locs = {}
    for _, loc in ipairs(tool.locations) do
      locs[#locs + 1] = loc.path and vim.fn.fnamemodify(loc.path, ":t") or "?"
    end
    title = title .. "  " .. table.concat(locs, ", ")
  end

  picker.select({
    title = "Permission required" .. ": " .. title,
    items = items,
    width = math.min(90, math.max(50, vim.o.columns - 20)),
    on_choice = function(value)
      M.resolve_permission(payload.key, value and value.id or nil)
    end,
    -- Dismissing the dialog must never leave the turn blocked forever.
    on_cancel = function()
      M.resolve_permission(payload.key, nil, true)
    end,
  })
end

---Resolve a pending permission request.
---@param key string
---@param option_id string|nil
---@param dismissed boolean|nil when true, prefer an explicit reject option
function M.resolve_permission(key, option_id, dismissed)
  local entry = S.pending_permissions[key]
  if not entry then
    return
  end
  if dismissed and not option_id then
    -- Pick the first reject option so the agent gets an explicit denial.
    for _, option in ipairs(entry.options or {}) do
      if option.kind and option.kind:match("^reject") then
        option_id = option.optionId
        break
      end
    end
  end
  S.pending_permissions[key] = nil
  if S.client then
    S.client:resolve_permission(key, option_id)
  end
  refresh_chrome()
end

---Reopen the oldest pending permission request.
function M.show_pending_permission()
  local keys = vim.tbl_keys(S.pending_permissions)
  table.sort(keys)
  local key = keys[1]
  if not key then
    notify("no pending permission requests", vim.log.levels.INFO)
    return
  end
  local entry = S.pending_permissions[key]
  M.show_permission({
    key = key,
    tool_call = entry.tool_call,
    options = entry.options,
  })
end

---------------------------------------------------------------------------
-- context actions
---------------------------------------------------------------------------

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
  local attachment, err = context.selection(cfg())
  if not attachment then
    notify(err or "unable to attach selection", vim.log.levels.WARN)
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
  local session = current()
  if not session then
    return
  end
  local option = session:option_by_category(category)
  if not option then
    notify("this agent does not offer a " .. category .. " option", vim.log.levels.INFO)
    return
  end
  local items = {}
  for _, entry in ipairs(session_mod.select_values(option)) do
    local ic = Icons.get(cfg().ui.icons)
    local marked = entry.value == option.currentValue and (ic.check_circle .. " ") or (ic.tool_pending .. " ")
    items[#items + 1] = {
      label = marked .. (entry.name or tostring(entry.value)),
      description = entry.description,
      value = entry.value,
    }
  end
  picker.select({
    title = title .. " · " .. option.name,
    items = items,
    on_choice = function(value)
      async.run(function()
        local ok, result = S.client:set_config_option(session.id, option.id, value)
        if not ok then
          local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
          notify("unable to change option: " .. message, vim.log.levels.ERROR)
          return
        end
        if result and result.configOptions then
          session.config_options = result.configOptions
        else
          option.currentValue = value
        end
        refresh_chrome()
      end)
    end,
  })
end

function M.pick_model()
  M.pick_option("model", "Model")
end

function M.pick_mode()
  M.pick_option("mode", "Mode")
end

function M.pick_config()
  local session = current()
  if not session then
    return
  end
  local items = {}
  for _, option in ipairs(session.config_options or {}) do
    if option.category ~= "model" and option.category ~= "mode" then
      local label = session_mod.option_label(option, option.currentValue) or tostring(option.currentValue)
      items[#items + 1] = {
        label = string.format("%s: %s", option.name, label),
        description = option.description,
        value = option.id,
      }
    end
  end
  if #items == 0 then
    notify("no additional session options", vim.log.levels.INFO)
    return
  end
  picker.select({
    title = "Configure",
    items = items,
    on_choice = function(id)
      local option = nil
      for _, opt in ipairs(session.config_options) do
        if opt.id == id then
          option = opt
        end
      end
      if option then
        M.pick_option(option.category or "", option.name)
      end
    end,
  })
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
  local lines = {
    "# acp.nvim",
    "",
    "Composer",
    "  <C-s>     send",
    "  <C-c>     cancel the current turn",
    "",
    "Transcript",
    "  i / <C-s> focus the composer",
    "  <Tab>     expand or collapse a tool block",
    "  <CR>      open the file location under the cursor",
    "  [b / ]b   previous / next block",
    "  G / gg    newest / oldest message",
    "  S         attach the current selection",
    "  F         attach the current file",
    "  R         attach diagnostics",
    "  M / m     pick model / mode",
    "  <C-n>     new session",
    "  L         pick a stored session",
    "  q         hide the panel",
    "",
    "The panel hides without stopping the agent.",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  local width = math.min(70, vim.o.columns - 8)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " acp.nvim ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf, silent = true })
end

function M.show_log()
  local path = log.path()
  if vim.fn.filereadable(path) ~= 1 then
    notify("no log file yet at " .. path, vim.log.levels.INFO)
    return
  end
  local target = layout.saved_focus()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
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
    panel = {
      chat = S.chat and S.chat.win or nil,
      input = S.input and S.input.win or nil,
    },
  }))
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

function M.setup(opts)
  local merged = config_mod.merge(config_mod.defaults, opts or {})
  local ok, err = pcall(config_mod.validate, merged)
  if not ok then
    error(err, 0)
  end
  S.config = merged

  log.setup(merged.log)
  highlights.setup(merged.ui.zed_style)
  layout.setup(merged)

  -- Reconfiguring means a different agent, cwd or UI: drop the old runtime
  -- state instead of mixing sessions from two configurations.
  stop_spinner()
  if S.client then
    pcall(S.client.shutdown, S.client, true)
    S.client = nil
  end
  S.session = nil
  S.sessions = {}
  S.titles = {}
  S.pending_permissions = {}
  S.connection = "stopped"
  S.pending_reload = nil
  S.replaying = false

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
  S.input.on_draft = function(_, text, attachments)
    local session = S.session
    if not session then
      return
    end
    drafts.put(session.cwd, session.id, text, attachments)
  end

  -- Re-attach the active session to the freshly created views.
  if S.session then
    S.chat:set_session(S.session)
    S.input:switch_session(S.session.id)
  end

  setup_window_events()
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
