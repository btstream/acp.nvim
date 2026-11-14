-- Application controller: wires protocol, session state, layout and UI.
local config_mod = require("acp.config")
local log = require("acp.log")
local Chat = require("acp.ui.chat")
local Input = require("acp.ui.input")
local highlights = require("acp.ui.highlights")
local keymaps = require("acp.ui.keymaps")
local layout = require("acp.layout")
local drafts = require("acp.storage.drafts")
local Runtime = require("acp.session.runtime")
local Tasks = require("acp.tasks")
local Permissions = require("acp.app.permissions")
local Elicitation = require("acp.app.elicitation")
local Auth = require("acp.app.auth")
local Interactions = require("acp.app.interactions")
local Options = require("acp.app.options")
local Chrome = require("acp.ui.chrome")
local Panel = require("acp.ui.panel")
local Catalog = require("acp.app.catalog")
local Sessions = require("acp.app.sessions")
local Prompts = require("acp.app.prompts")
local Connection = require("acp.app.connection")
local Events = require("acp.app.events")
local Attachments = require("acp.app.attachments")
local Status = require("acp.app.status")
local Stores = require("acp.app.stores")
local Window = require("acp.app.window")
local ConnectionFlow = require("acp.app.connection_flow")
local Bootstrap = require("acp.app.bootstrap")
local RuntimeOps = require("acp.app.runtime_ops")
local Turn = require("acp.app.turn")
local windows = require("acp.ui.windows")
local work = require("acp.ui.work_scheduler")

local M = {}

-- State is partitioned into connection/session/view stores; flat reads such as
-- `S.sess.current` and `S.view.chat` address the stores directly; the legacy
-- flat names (`S.session`, `S.chat`) still resolve through `app/stores`.
local S = Stores.new()
local operations = Tasks.new(function()
  return S
end)

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------

-- Runtime helpers live in `app/runtime_ops`; these are one-line shorthands so
-- the wiring below reads the same as it did when the bodies were here.
local runtime_ops
local turn

local function cfg()
  return S.config
end

local function new_local_session(id, cwd, result)
  return S.sess.runtime:create(id, cwd, result)
end

local function prune_sessions()
  runtime_ops:prune_sessions()
end

local function dispatch_queued(session)
  runtime_ops:dispatch_queued(session)
end

local function ui_current(client, generation, session)
  return runtime_ops:ui_current(client, generation, session)
end

local function invalidate_operations()
  runtime_ops:invalidate_operations()
end

local function resolve_cwd()
  return runtime_ops:resolve_cwd()
end

---Current session or nil.
local function current()
  return S.sess.current
end

local function session_label(session)
  return runtime_ops:session_label(session)
end

local function notify(message, level)
  vim.notify("acp.nvim: " .. message, level or vim.log.levels.INFO)
end

runtime_ops = RuntimeOps.new({
  state = function()
    return S
  end,
  send = function(text, attachments, session)
    return M.send_now(text, attachments, session)
  end,
  generation = function()
    return operations.generation
  end,
  reset_operations = function()
    operations:reset()
  end,
})

---------------------------------------------------------------------------
-- status and chrome
---------------------------------------------------------------------------

-- The bodies live in `app/status`; these keep the public shape used by
-- statusline components, integrations and the winbar globals.

---@param session AcpSessionState|nil
local function waiting_permission(session)
  return S.view.status:waiting_permission(session)
end

---Public structured status for statusline components.
---@return table
function M.status()
  return S.view.status:status()
end

---Short text suitable for a statusline component. Never sets the statusline itself.
---@return string
function M.statusline()
  return S.view.status:statusline()
end

---Build the composer winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M.composer_bar(win)
  return S.view.status:composer_bar_for(win)
end

---Build the transcript winbar for the window currently being drawn.
---@param win integer|nil defaults to the current window
---@return string
function M.chat_bar(win)
  return S.view.status:chat_bar_for(win)
end

-- Both bars are rebuilt by the same apply pass; the two names are kept because
-- they document *why* the caller wants a refresh.
local function update_chat_title()
  S.view.status:apply()
end

local update_input_toolbar = update_chat_title

local function sync_spinner()
  S.view.status:sync_spinner()
end

local function refresh_chrome()
  S.view.status:refresh()
end

local function refresh_session_title(session, cb)
  if S.sess.catalog then
    S.sess.catalog:refresh_title(session, cb)
  elseif cb then
    cb()
  end
end

local function stop_spinner()
  S.view.status:stop_spinner()
end

turn = Turn.new({
  state = function()
    return S
  end,
  refresh_chrome = function()
    refresh_chrome()
  end,
  notify = function(message, level)
    notify(message, level)
  end,
  cancel_session = function(session)
    operations:cancel_session(session)
  end,
})

---------------------------------------------------------------------------
-- session switching
---------------------------------------------------------------------------

local window

---@param session AcpSessionState|nil
local function activate_session(session)
  window:select_session(session)
end

---------------------------------------------------------------------------
-- window lifecycle
---------------------------------------------------------------------------

-- Keymaps and window events live in `app/window`; the controller only supplies
-- the entry points they call and the state they read.

-- The window module calls back into the controller, so the table is built from
-- `M` lazily: a direct reference would capture whatever each field held at setup
-- time and silently ignore later replacements.
local window_actions
window_actions = setmetatable({}, {
  __index = function(_, key)
    return M[key]
  end,
})

local function install_window(deps)
  window = Window.new(vim.tbl_extend("force", deps, { actions = window_actions }))
  window:install_window_events()
  window:install_input_keymaps()
  window:install_chat_keymaps()
  window:install_inline_keymaps()
  return window
end

---Show the panel, starting the agent when needed.
function M.open()
  window:open()
end

---Hide the panel without stopping the session.
function M.hide()
  window:hide()
end

function M.toggle()
  window:toggle()
end

---@param which "input"|"chat"
function M.focus(which)
  window:focus(which)
end

---------------------------------------------------------------------------
-- connection & sessions
---------------------------------------------------------------------------

function M.connect()
  S.conn.service:connect()
end

function M.disconnect()
  pcall(function()
    require("acp.inline").stop()
  end)
  if S.view.auth then
    S.view.auth:cancel()
  end
  S.conn.service:disconnect()
end

---Reconnect after a crash or an explicit disconnect.
function M.reconnect()
  S.conn.service:reconnect()
end

---Reload the current session after a reconnect, replaying agent-side history.
---@param session_id string
function M.reload_session(session_id)
  if S.conn.phase ~= "ready" or not S.conn.client or not S.sess.service then
    return
  end
  S.sess.service:restore(session_id)
end
---Send a message parked while a login was in progress.
---
---`schedule_auth_retry` is internal: the flow schedules itself, so a caller only
---ever needs to flush.
---@return boolean sent
function M.flush_auth_retry()
  return S.conn.flow:flush_auth_retry()
end

---Log in with the agent's offered method.
function M.login()
  if not S.view.auth then
    return
  end
  if not S.conn.client then
    notify("Connect to the agent before logging in", vim.log.levels.WARN)
    return
  end
  S.view.auth:reset()
  S.view.auth:login(nil, function()
    M.connect()
  end)
end

---Log out, when the agent declares `auth.logout`.
function M.logout()
  if S.view.auth then
    S.view.auth:logout()
  end
end

---Switch the agent, reusing the current configuration for everything else.
---@param name string|nil
function M.pick_agent(name)
  S.conn.flow:pick_agent(name)
end

-- Managed installs. Every decision (confirmation, locking, npm) belongs to the
-- service; these only forward, and return false when setup has not run.

---Install one managed agent. Does not switch to it or start it.
---@param id string
---@param opts {version?: string}|nil
---@return boolean started
function M.install_agent(id, opts)
  local service = S.view.agent_manager_service
  return service ~= nil and service:install(id, opts) or false
end

---Update one managed agent to the latest (or a given) version.
---@param id string
---@param opts {version?: string}|nil
---@return boolean started
function M.update_agent(id, opts)
  local service = S.view.agent_manager_service
  if service == nil then
    return false
  end
  if id == nil then
    return service:update_all() > 0
  end
  return service:update(id, opts) or false
end

---Remove the manager-owned copy of one agent.
---@param id string
---@return boolean started
function M.uninstall_agent(id)
  local service = S.view.agent_manager_service
  return service ~= nil and service:uninstall(id) or false
end

---Open the agent manager window. Never connects or downloads.
function M.manage_agents()
  if S.view.agent_manager then
    S.view.agent_manager:open()
  end
end

---Open the picker for every session control the agent offers.
function M.pick_config()
  if S.view.options then
    S.view.options:pick_config()
  end
end

---Create a new session with the current agent.
function M.new_session()
  if S.sess.service then
    S.sess.service:create(function()
      M.connect()
    end)
  end
end

---Load a previous session, replaying its history.
---@param session_id string
function M.load_session(session_id)
  if S.sess.service then
    S.sess.service:load(session_id)
  end
end

---Browse stored sessions. <CR> opens, <C-d> deletes, typing filters.
function M.pick_session()
  if S.sess.service then
    S.sess.service:pick()
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
  turn:add_system_block(text, kind, target)
end

---Send the composer contents.
function M.send_now(text, attachments, target)
  return turn:send(text, attachments, target)
end

---Inline is a normal turn in the selected session, not a new ACP session.
---
---Injected into `acp.inline` at setup, so the inline module never imports the
---controller. The session must still be the selected one: inline edits act on
---what the user is looking at.
function M.send_inline(session, text, hooks)
  return turn:send_inline(session, text, hooks)
end

---Submit from the composer.
---@param text string
---@param attachments table[]
function M.submit(text, attachments)
  turn:submit(text, attachments)
end

---Cancel the active turn.
function M.cancel()
  turn:cancel()
end

---------------------------------------------------------------------------
-- client events
---------------------------------------------------------------------------

---@param name string
---@param payload any
function M.on_client_event(name, payload)
  if S.conn.events then
    S.conn.events:dispatch(name, payload)
  end
end

---Open the permission picker for a pending request.
---@param payload table|nil accepts the legacy `{ key = ... }` shape
function M.show_permission(payload)
  if payload and payload.key then
    S.view.interactions:show(payload.key)
    return
  end
  S.view.interactions:show_next()
end

---Resolve a pending permission request.
---@param key string
---@param option_id string|nil
---@param dismissed boolean|nil when true, prefer an explicit reject option
function M.resolve_permission(key, option_id, dismissed)
  local interaction = S.view.interactions:get(key)
  if not interaction then
    return
  end
  if dismissed and not option_id then
    for _, option in ipairs((interaction.request or {}).options or {}) do
      if option.kind and option.kind:match("^reject") then
        option_id = option.optionId
        break
      end
    end
  end
  if option_id then
    S.view.interactions:answer(key, { outcome = { outcome = "selected", optionId = option_id } })
  else
    S.view.interactions:cancel(key, "dismissed")
  end
end

---Reopen the oldest pending permission request.
function M.show_pending_permission()
  if not S.view.interactions:waiting() then
    notify("no pending permission requests", vim.log.levels.INFO)
    return
  end
  S.view.interactions:show_next()
end

---------------------------------------------------------------------------
-- context actions
---------------------------------------------------------------------------

-- The bodies live in `app/attachments`; these stay here because `:Acp` commands,
-- keymaps and the public Lua API are controller entry points.
local attachment_calls = {
  "pick_file",
  "add_image",
  "add_image_attachment",
  "paste_image",
  "add_file",
  "add_selection",
  "add_diagnostics",
  "open_location",
}
for _, name in ipairs(attachment_calls) do
  M[name] = function(...)
    return S.view.attachments[name](S.view.attachments, ...)
  end
end

---------------------------------------------------------------------------
-- config option pickers
---------------------------------------------------------------------------

-- Thin forwards: the options service owns the pickers and the choice logic.

function M.pick_model()
  S.view.options:pick_model()
end

function M.pick_mode()
  S.view.options:pick_mode()
end

---Every session control in one picker, including boolean switches.
function M.pick_config()
  S.view.options:pick_config()
end

---@param category string
---@param title string
function M.pick_option(category, title)
  S.view.options:pick(category, title)
end

---------------------------------------------------------------------------
-- misc commands
---------------------------------------------------------------------------

function M.copy_transcript()
  if not S.view.chat then
    return
  end
  local text = S.view.chat:transcript()
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
  print(vim.inspect(runtime_ops:debug_state()))
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

function M.setup(opts, action)
  -- The wiring context: internal helpers plus the public entry points the
  -- services call back into. Public entry points are looked up through `M` at
  -- call time, so a replaced one (a test double, an integration) is honoured.
  local ctx = {
    state = S,
    cfg = cfg,
    current = current,
    notify = notify,
    config_mod = config_mod,
    log = log,
    work = work,
    highlights = highlights,
    layout = layout,
    Operations = operations,
    drafts = drafts,
    invalidate_operations = invalidate_operations,
    prune_sessions = prune_sessions,
    dispatch_queued = dispatch_queued,
    ui_current = ui_current,
    resolve_cwd = resolve_cwd,
    activate_session = activate_session,
    new_local_session = new_local_session,
    add_system_block = add_system_block,
    refresh_chrome = refresh_chrome,
    stop_spinner = stop_spinner,
    sync_spinner = sync_spinner,
    update_chat_title = update_chat_title,
    update_input_toolbar = update_input_toolbar,
    session_label = session_label,
    waiting_permission = waiting_permission,
    refresh_session_title = refresh_session_title,
    install_window = install_window,
    is_question = Permissions.question,
    -- Explicit nil: the metatable below answers every unknown key with a
    -- function, so an optional hook must be present here to stay absent.
    resolve_store = nil,
    locks = nil,
  }
  -- Public entry points, resolved on use.
  setmetatable(ctx, {
    __index = function(_, key)
      return function(...)
        return M[key](...)
      end
    end,
  })
  Bootstrap.build(ctx, opts, action)
end

---Access the shared controller state (read-only, for integrations).
---@return table
function M.state()
  return S
end

---The partitioned state stores, for code that should not rely on the flat view.
---
---`state()` keeps flat reads working (`state.session`, `state.chat`), but new
---code and tests should say which phase they mean:
---
---  stores.connection  client, connection phase, in-flight auth retries
---  stores.session     runtime, sessions, catalog caches
---  stores.view        panel, chat, input, chrome, services
---@return table<string, table>
function M.stores()
  return Stores.stores(S)
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
