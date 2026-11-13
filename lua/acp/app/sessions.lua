-- Session lifecycle: create, load, restore, delete and browse.
--
-- The runtime still owns the registry, replay staging and the outbox. This
-- module orchestrates the user-visible flow and reports activation through
-- callbacks, so it never touches the panel or the composer directly.
local session_picker = require("acp.ui.session_picker")
local session_snacks = require("acp.ui.session_snacks")
local capabilities = require("acp.protocol.capabilities")

local Sessions = {}
Sessions.__index = Sessions

---@param opts {config: fun(): table, runtime: fun(): table, catalog: table,
---  client: fun(): table|nil, connection: fun(): string,
---  generation: fun(): integer, new_local: fun(id: string, cwd: string, result: table): table,
---  resolve_cwd: fun(): string, run: fun(key: string, client: table|nil,
---  session: table|nil, fn: fun(task: table), on_error: fun(any)|nil,
---  on_finally: fun(task: table, owned: boolean)|nil): table,
---  cancel_session: fun(session: table, except: table|nil),
---  current: fun(): table|nil, activate: fun(session: table|nil), render: fun(),
---  dispatch_queued: fun(session: table), on_changed: fun(),
---  on_replaying: fun(value: boolean), on_creating: fun(value: boolean),
---  prune: fun(), auth: fun(): table|nil,
---  notify: fun(message: string, level: integer|nil)}
function Sessions.new(opts)
  return setmetatable({
    config = opts.config,
    get_runtime = opts.runtime,
    catalog = opts.catalog,
    get_client = opts.client,
    connection = opts.connection,
    generation = opts.generation,
    new_local = opts.new_local,
    resolve_cwd = opts.resolve_cwd,
    run = opts.run,
    cancel_session = opts.cancel_session,
    current = opts.current,
    activate = opts.activate,
    render = opts.render,
    dispatch_queued = opts.dispatch_queued,
    get_auth = opts.auth,
    on_changed = opts.on_changed,
    on_replaying = opts.on_replaying,
    on_creating = opts.on_creating,
    prune = opts.prune,
    notify = opts.notify,
    creating = false,
    replaying = false,
  }, Sessions)
end

function Sessions:ready()
  return self.connection() == "ready" and self.get_client() ~= nil
end

---Request a new session from the agent.
---@param on_missing fun() invoked when there is no live connection
function Sessions:create(on_missing)
  if not self:ready() then
    if on_missing then
      on_missing()
    end
    return
  end
  local cwd = self.resolve_cwd()
  -- Guard against overlapping creations (e.g. a double `new_session` from a
  -- fast toggle): the last response would otherwise win and orphan a session.
  if self.creating then
    return
  end
  self.creating = true
  self.creation_seq = (self.creation_seq or 0) + 1
  local creation = self.creation_seq
  self.on_creating(true)
  local runtime, client = self.get_runtime(), self.get_client()
  local intent = runtime:intend()
  local token = runtime:expect_create()
  self.run("create", client, nil, function(task)
    local ok, result = task:call("new_session", cwd)
    if not ok then
      task.status = "failed"
      runtime:drop_create(token)
      local auth = self.get_auth and self.get_auth()
      if auth and auth:require(result, {
        retry = function()
          self:create()
        end,
      }) then
        return
      end
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      self.notify("unable to create a session: " .. message, vim.log.levels.ERROR)
      return
    end
    if type(result) ~= "table" or type(result.sessionId) ~= "string" or result.sessionId == "" then
      runtime:drop_create(token)
      error("invalid session/new response")
    end
    local session, replayed = runtime:commit_create(token, result.sessionId, cwd, result)
    if not session then
      runtime:drop_create(token)
      session = self.new_local(result.sessionId, cwd, result)
      replayed = 0
    end
    self.catalog:cwds()[session.id] = cwd
    if replayed > 0 then
      self.on_changed()
    end
    if runtime.selection == intent then
      self.activate(session)
      self.render()
    end
    self.notify("Session started", vim.log.levels.INFO)
    self.catalog:refresh_title(session)
  end, function(err)
    runtime:drop_create(token)
    self.notify("unable to create a session: " .. tostring(err), vim.log.levels.ERROR)
  end, function(_, owned)
    -- Even an abandoned creation must release the guard: a reconnect cancels
    -- the scoped task, and leaving `creating` set wedged every later
    -- `session/new` (for example after logging in).
    if self.creation_seq == creation then
      self.creating = false
      self.on_creating(false)
    end
    if not owned then
      runtime:drop_create(token)
    end
  end)
end

---Resume `session_id` without replaying its history.
---
---The fallback when the agent supports `session/resume` but not `session/load`:
---the agent-side context comes back, the transcript does not. The user is told,
---because an empty transcript after "open session" otherwise looks like a bug.
---@param session_id string
---@param opts {kind: string|nil}|nil
function Sessions:resume(session_id, opts)
  opts = opts or {}
  local client = self.get_client()
  if not self:ready() or not client then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local runtime = self.get_runtime()
  local cwd = self.catalog:session_cwd(session_id, self.resolve_cwd())
  local entry = runtime:stage(session_id, cwd)
  local intent = runtime:intend()
  -- Hold the same replay lock as `replay`: a second load while this request is
  -- in flight would stage a second projection for the same session id.
  self.replaying = true
  self.on_replaying(true)
  self.run("resume", client, entry, function(task)
    local ok, result = task:call("resume_session", session_id, cwd)
    if not ok then
      task.status = "failed"
      runtime:rollback(entry)
      local auth = self.get_auth and self.get_auth()
      if
        auth
        and auth:require(result, {
          retry = function()
            self:resume(session_id, opts)
          end,
        })
      then
        return
      end
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      if opts.kind == "restore" and tostring(message):lower():match("shutdown") then
        -- Expected during teardown; do not alarm the user.
        self:create()
        return
      end
      self.notify(
        "unable to resume the session: " .. message,
        opts.kind == "restore" and vim.log.levels.WARN or vim.log.levels.ERROR
      )
      -- Restoring has no session to fall back on: the old one is already gone.
      if opts.kind == "restore" then
        self:create()
      end
      return
    end
    if type(result) ~= "table" then
      error("invalid session/resume response")
    end
    entry:configure(result)
    entry.needs_load = false
    if not runtime:commit(entry) then
      return
    end
    if self.catalog:apply_title(entry) then
      self.on_changed()
    end
    if runtime.selection == intent then
      self.activate(entry)
      self.render()
    end
    self.prune()
    self.on_changed()
    self.notify("Session resumed (history is not replayed)")
    self.catalog:refresh_title(entry)
  end, function(err)
    runtime:rollback(entry)
    self.notify("unable to resume the session: " .. tostring(err), vim.log.levels.ERROR)
  end, function(_, owned)
    if not owned then
      return
    end
    runtime:rollback(entry)
    self.replaying = false
    self.on_replaying(false)
    if runtime.sessions[entry.id] == entry then
      self.dispatch_queued(entry)
    end
  end)
end

---Load `session_id`, replaying the agent's history into the transcript.
---
---Used both when switching sessions and when restoring the current one after a
---reconnect.
---@param session_id string
---@param opts {kind: string|nil, intent: integer|nil}
function Sessions:replay(session_id, opts)
  local runtime = self.get_runtime()
  local cwd = self.catalog:session_cwd(session_id, self.resolve_cwd())
  local entry = runtime:stage(session_id, cwd)
  local intent = opts.intent or runtime:intend()
  local client = self.get_client()
  self.replaying = true
  self.on_replaying(true)
  self.run("replay", client, entry, function(task)
    local ok, result = task:call("load_session", session_id, cwd)
    if not ok then
      task.status = "failed"
      runtime:rollback(entry)
      local auth = self.get_auth and self.get_auth()
      if
        auth
        and auth:require(result, {
          retry = function()
            self:replay(session_id, opts)
          end,
        })
      then
        return
      end
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      if opts.kind == "restore" and tostring(message):lower():match("shutdown") then
        -- Expected during teardown; do not alarm the user.
        self:create()
        return
      end
      self.notify(
        "unable to " .. (opts.kind or "load") .. " the session: " .. message,
        opts.kind == "restore" and vim.log.levels.WARN or vim.log.levels.ERROR
      )
      if opts.kind == "restore" then
        self:create()
      end
      return
    end

    if type(result) ~= "table" then
      error("invalid session/load response")
    end
    entry:configure(result)
    entry:finish_turn("end_turn")
    if not runtime:commit(entry) then
      return
    end
    if self.catalog:apply_title(entry) then
      self.on_changed()
    end
    if runtime.selection == intent then
      self.activate(entry)
      self.render()
    end
    self.prune()
    self.on_changed()
    self.catalog:refresh_title(entry)
  end, function(err)
    runtime:rollback(entry)
    self.notify("unable to load the session: " .. tostring(err), vim.log.levels.ERROR)
  end, function(_, owned)
    if not owned then
      return
    end
    runtime:rollback(entry)
    self.replaying = false
    self.on_replaying(false)
    if runtime.sessions[entry.id] == entry then
      self.dispatch_queued(entry)
    end
  end)
end

---Restore the current session after a reconnect.
---@param session_id string
function Sessions:restore(session_id)
  local client = self.get_client()
  if not self:ready() then
    return
  end
  if self.replaying then
    return
  end
  if not capabilities.supports(capabilities.agent(client), "loadSession") then
    if capabilities.supports(capabilities.agent(client), "sessionCapabilities.resume") then
      self:resume(session_id, { kind = "restore" })
      return
    end
    self:create()
    return
  end
  -- Start from a clean transcript: the agent replays its authoritative history.
  self:replay(session_id, { kind = "restore" })
end

---Load a previous session, replaying its history.
---@param session_id string
function Sessions:load(session_id)
  if not self:ready() then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local runtime = self.get_runtime()
  local cached = runtime.sessions[session_id]
  if cached and not cached.needs_load and (cached.status ~= "idle" or #cached.queue > 0) then
    runtime:intend()
    self.activate(cached)
    self.dispatch_queued(cached)
    return
  end
  if self.replaying then
    self.notify("Wait for the session to finish before loading its history", vim.log.levels.WARN)
    return
  end
  local client = self.get_client()
  if not capabilities.supports(capabilities.agent(client), "loadSession") then
    -- Resuming restores the agent-side context without replaying history; it is
    -- the closest this agent can get to "open that session".
    if capabilities.supports(capabilities.agent(client), "sessionCapabilities.resume") then
      self:resume(session_id)
      return
    end
    self.notify("This agent cannot load sessions; starting a new one", vim.log.levels.WARN)
    self:create()
    return
  end
  -- Agents reject session/load when the cwd does not match the session.
  -- Loading replays authoritative history, even for a cached session; appending
  -- to the cached object would duplicate every message on subsequent visits.
  self:replay(session_id, { kind = "load" })
end

---Whether the client can be asked to close a session.
---
---Both the advertised capability and the local method are required: a test
---double may advertise through the predicate without implementing the call.
---@param client table|nil
---@return boolean
local function can_close(client)
  return client ~= nil
    and type(client.close_session) == "function"
    and capabilities.supports(capabilities.agent(client), "sessionCapabilities.close")
end

---Ask the agent to release a session it no longer needs to keep active.
---
---Best effort: `session/close` only exists on agents that advertise it, and a
---failure must not block switching, deleting or quitting.
---@param session_id string|nil
function Sessions:close(session_id)
  if not session_id then
    return
  end
  local client = self.get_client()
  if not can_close(client) then
    return
  end
  local runtime = self.get_runtime()
  local session = runtime.sessions[session_id]
  self.run("close:" .. session_id, client, session, function(task)
    task:call("close_session", session_id)
  end)
end

---Close every active session synchronously, for editor exit.
---
---The process is killed right after this runs, so the request has to complete
---on this turn of the event loop; a fire-and-forget coroutine would leave the
---notification unsent.
function Sessions:close_all_on_exit()
  local client = self.get_client()
  if not can_close(client) then
    return
  end
  local runtime = self.get_runtime()
  local async = require("acp.async")
  for id in pairs(runtime.sessions) do
    local done = false
    local co = async.run(function()
      client:close_session(id)
      done = true
    end)
    vim.wait(200, function()
      return done
    end, 10)
    if not done then
      pcall(async.cancel, co)
    end
  end
end

---Delete a session through the agent and drop it from local state.
---@param session_id string
---@param done fun(ok: boolean)
function Sessions:delete(session_id, done)
  local client = self.get_client()
  if not client then
    done(false)
    return
  end
  local runtime = self.get_runtime()
  local settled = false
  local function finish(ok)
    if settled then
      return
    end
    settled = true
    done(ok)
  end
  local session = runtime.sessions[session_id]
  self.run("delete:" .. session_id, client, session, function(task)
    -- Release agent-side resources first. Not every agent has `session/close`,
    -- and a failed close must not prevent the delete.
    if can_close(client) then
      task:call("close_session", session_id)
    end
    local ok, result = task:call("delete_session", session_id)
    if not ok then
      task.status = "failed"
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      self.notify(string.format("Unable to delete the session: %s", message), vim.log.levels.ERROR)
      finish(false)
      return
    end
    runtime:remove(session_id)
    self.cancel_session(session or { id = session_id }, task)
    self.catalog:forget(session_id)
    local current = self.current()
    if current and current.id == session_id then
      -- The active conversation is gone; start a fresh one.
      self.activate(nil)
      self.render()
      self:create()
    else
      self.on_changed()
    end
    self.notify("Session deleted", vim.log.levels.INFO)
    finish(true)
  end, function(err)
    self.notify("Unable to delete the session: " .. tostring(err), vim.log.levels.ERROR)
    finish(false)
  end, function()
    finish(false) -- cancelled picker operations also have a terminal outcome
  end)
end

---Browse stored sessions. <CR> opens, <C-d> deletes, typing filters.
function Sessions:pick()
  if not self:ready() then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local client, generation = self.get_client(), self.generation()
  local function ui_current()
    return self.get_client() == client and self.generation() == generation
  end
  self.catalog:list(self.resolve_cwd(), function(ok, sessions)
    if not ok then
      return
    end
    if #sessions == 0 then
      self.notify("No stored sessions found", vim.log.levels.INFO)
      return
    end
    local active = self.current()
    local picker_opts = {
      sessions = sessions,
      current_id = active and active.id or nil,
      can_delete = capabilities.supports(capabilities.agent(client), "sessionCapabilities.delete"),
      use_icons = self.config().ui.icons,
      on_open = function(session_id)
        if ui_current() then
          self:load(session_id)
        end
      end,
      on_delete = function(session_id, done)
        if ui_current() then
          self:delete(session_id, done)
        else
          done(false)
        end
      end,
    }

    -- snacks is the default when it is installed; otherwise fall back to the
    -- built-in window instead of failing.
    if self.config().ui.session_picker == "snacks" and session_snacks.open(picker_opts) then
      return
    end
    session_picker.open(picker_opts)
  end)
end

---Remember a replay failure/teardown in one place for diagnostics.
---@return boolean
function Sessions:is_replaying()
  return self.replaying
end

return Sessions
