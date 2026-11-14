-- The three state stores behind the controller.
--
-- The controller used to keep everything in one flat table, so "which phase does
-- this field belong to?" was answered only by convention. The data now lives in
-- three ordinary tables, one per owner:
--
--   conn  the agent process: client, phase, in-flight auth retries
--   sess  what the agent told us: runtime, current session, caches
--   view  what the user sees: panel, chat, input, chrome, services
--
-- Fields are named for what they are, not for the flat alias they used to have:
-- the current session is `sess.current`, the connection phase is `conn.phase`.
-- Reading `state.session` still works — it resolves through `FLAT` below — but
-- that is a compatibility view, not storage.
--
-- The store names themselves (`conn`, `sess`, `view`) are deliberately distinct
-- from every flat field, so a store can never shadow the data it holds.
local M = {}

---@class AcpStores
---@field connection table the `conn` store
---@field session table the `sess` store
---@field view table the `view` store

---Flat name -> {store, field}. Anything not listed lives at the top level and is
---not part of the split (`config` is the main one).
local FLAT = {
  -- connection store
  client = { "conn", "client" },
  connection = { "conn", "phase" },
  connection_service = { "conn", "service" },
  events = { "conn", "events" },
  replaying = { "conn", "replaying" },
  creating_session = { "conn", "creating_session" },
  pending_auth_retries = { "conn", "pending_auth_retries" },
  auth_after_ready = { "conn", "auth_after_ready" },
  auth_retry_timer = { "conn", "auth_retry_timer" },
  -- session store
  session = { "sess", "current" },
  sessions = { "sess", "all" },
  runtime = { "sess", "runtime" },
  catalog = { "sess", "catalog" },
  titles = { "sess", "titles" },
  session_cwds = { "sess", "cwds" },
  agent_store = { "sess", "agent_store" },
  sessions_service = { "sess", "service" },
  prompts = { "sess", "prompts" },
  -- view store
  chat = { "view", "chat" },
  input = { "view", "input" },
  panel = { "view", "panel" },
  chrome = { "view", "chrome" },
  status = { "view", "status" },
  attachments = { "view", "attachments" },
  interactions = { "view", "interactions" },
  permissions = { "view", "permissions" },
  elicitation = { "view", "elicitation" },
  options = { "view", "options" },
  auth = { "view", "auth" },
  click_hint_shown = { "view", "click_hint_shown" },
}

---Which store owns a flat name, for diagnostics and tests.
---@param field string
---@return string|nil
function M.owner_of(field)
  local entry = FLAT[field]
  return entry and entry[1] or nil
end

---Every flat name, grouped by store. Enumerated so a rename cannot silently
---leave a field behind.
---@return table<string, string[]>
function M.fields()
  local out = { conn = {}, sess = {}, view = {} }
  for name, entry in pairs(FLAT) do
    local list = out[entry[1]]
    list[#list + 1] = name
  end
  for _, list in pairs(out) do
    table.sort(list)
  end
  return out
end

local STORE_NAMES = { conn = true, sess = true, view = true }

local meta = {}

function meta.__index(state, key)
  if STORE_NAMES[key] then
    return rawget(state, key)
  end
  local entry = FLAT[key]
  if entry then
    return rawget(state, entry[1])[entry[2]]
  end
  return rawget(state, key)
end

function meta.__newindex(state, key, value)
  if STORE_NAMES[key] then
    rawset(state, key, value)
    return
  end
  local entry = FLAT[key]
  if entry then
    rawget(state, entry[1])[entry[2]] = value
    return
  end
  rawset(state, key, value)
end

---Create the partitioned state.
---
---The stores are plain fields and hold the data; the metatable only provides the
---legacy flat names.
---@return table
function M.new()
  local state = setmetatable({
    config = nil,
    conn = {},
    sess = {},
    view = {},
  }, meta)

  -- Defaults, written straight into their store.
  local conn, sess = state.conn, state.sess
  conn.phase = "stopped" -- stopped | starting | ready | disconnected
  conn.replaying = false
  conn.creating_session = false
  conn.pending_auth_retries = nil
  conn.auth_after_ready = nil
  conn.auth_retry_timer = nil
  sess.all = {}
  sess.titles = {}
  sess.cwds = {}
  sess.agent_store = {}
  return state
end

---The stores themselves, keyed by the phase they describe.
---
---This is the API new code should use: `stores.session.current` says what it
---means, while `state.session` is a compatibility alias.
---@param state table
---@return AcpStores
function M.stores(state)
  return {
    connection = rawget(state, "conn"),
    session = rawget(state, "sess"),
    view = rawget(state, "view"),
  }
end

return M
