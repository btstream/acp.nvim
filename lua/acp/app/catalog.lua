-- Session metadata: titles, working directories and `session/list`.
--
-- Session objects are recreated on load/reconnect, so titles and cwds are
-- cached by session id here instead of on the object. The query helpers never
-- activate a session; they only report what the agent knows.
local log = require("acp.log")
local capabilities = require("acp.protocol.capabilities")

local Catalog = {}
Catalog.__index = Catalog

---@param opts {titles: fun(): table, cwds: fun(): table,
---  client: fun(): table|nil, connection: fun(): string,
---  run: fun(key: string, client: table|nil, session: table|nil,
---  fn: fun(task: table), on_error: fun(any)|nil,
---  on_finally: fun(task: table, owned: boolean)|nil): table,
---  on_changed: fun(), notify: fun(message: string, level: integer|nil)}
function Catalog.new(opts)
  return setmetatable({
    get_titles = opts.titles,
    get_cwds = opts.cwds,
    get_client = opts.client,
    connection = opts.connection,
    run = opts.run,
    on_changed = opts.on_changed,
    notify = opts.notify,
    refreshing = false,
    pending = false,
    pending_session = nil,
  }, Catalog)
end

---@return table<string, string>
function Catalog:titles()
  return self.get_titles()
end

---@return table<string, string>
function Catalog:cwds()
  return self.get_cwds()
end

function Catalog:reset()
  self.refreshing, self.pending, self.pending_session = false, false, nil
end

---@param session_id string
---@return string|nil
function Catalog:title(session_id)
  return self:titles()[session_id]
end

---@param session_id string
---@return string|nil
function Catalog:cwd(session_id)
  return self:cwds()[session_id]
end

---Remember an agent-provided title, ignoring missing values and empty strings.
---@param session_id string
---@param title any
---@return boolean changed
function Catalog:cache_title(session_id, title)
  if not session_id then
    return false
  end
  -- JSON null decodes to nil; that means "no title yet", not "clear it".
  if type(title) ~= "string" or title == "" then
    return false
  end
  local titles = self:titles()
  if titles[session_id] == title then
    return false
  end
  titles[session_id] = title
  return true
end

---Apply the cached title to a session object, if it differs.
---@param session table|nil
---@return boolean applied
function Catalog:apply_title(session)
  if not session then
    return false
  end
  local title = self:titles()[session.id]
  if not title or title == session.title then
    return false
  end
  session.title = title
  return true
end

---Forget everything about a deleted session.
---@param session_id string
function Catalog:forget(session_id)
  self:titles()[session_id] = nil
  self:cwds()[session_id] = nil
end

---The directory a stored session belongs to.
---
---ACP requires `session/load` to use the session's own directory: agents
---reject the request when the cwd does not match. The cwd recorded in
---`session/list` is authoritative, so it is preferred over the editor cwd.
---@param session_id string
---@param fallback string
---@return string
function Catalog:session_cwd(session_id, fallback)
  local cwd = self:cwds()[session_id]
  if cwd and cwd ~= "" then
    return cwd
  end
  return fallback
end

---Fetch the session list, calling `cb(ok, sessions)`.
---
---The query uses the resolved editor cwd, not a historical session's cwd.
---Agents such as OpenCode filter strictly by `cwd`, so an empty filtered result
---is retried without the filter rather than reporting that no sessions exist.
---@param scoped_cwd string
---@param cb fun(ok: boolean, sessions: table[])
function Catalog:list(scoped_cwd, cb)
  local client = self.get_client()
  if not client or self.connection() ~= "ready" then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return
  end
  local settled = false
  local function finish(ok, sessions)
    if settled then
      return
    end
    settled = true
    cb(ok, sessions)
  end

  self.run("list", client, nil, function(task)
    local function to_error(result)
      task.status = "failed"
      if type(result) == "table" and (result.code == -32601 or result.code == -32602) then
        self.notify("This agent does not support listing sessions", vim.log.levels.WARN)
      else
        local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
        self.notify(string.format("Unable to list sessions: %s", message), vim.log.levels.ERROR)
      end
      finish(false, {})
    end

    ---Follow `nextCursor` until the agent stops returning one.
    ---
    ---A bounded loop guards against an agent that echoes the same cursor
    ---forever; the cap is far above any realistic session count.
    ---@param scoped string|nil
    ---@return boolean ok, table|string sessions_or_error
    local function collect(scoped)
      local sessions, cursor, seen = {}, nil, {}
      for _ = 1, 100 do
        local ok, result = task:call("list_sessions", scoped, cursor)
        if not ok then
          return false, result
        end
        if type(result) ~= "table" then
          return false, "invalid session/list response"
        end
        for _, info in ipairs(result.sessions or {}) do
          sessions[#sessions + 1] = info
        end
        local next_cursor = result.nextCursor
        if type(next_cursor) ~= "string" or next_cursor == "" or seen[next_cursor] then
          return true, sessions
        end
        seen[next_cursor] = true
        cursor = next_cursor
      end
      return true, sessions
    end

    local ok, sessions = collect(scoped_cwd)
    if not ok then
      to_error(sessions)
      return
    end
    if #sessions == 0 then
      -- Nothing in this directory: show every session the agent knows about.
      local all_ok, all = collect(nil)
      if all_ok then
        sessions = all
      end
    end

    -- Keep the title cache warm so switching sessions updates the winbar at once,
    -- and remember each session's directory: loading it needs that exact cwd.
    for _, info in ipairs(sessions) do
      self:cache_title(info.sessionId, info.title)
      if type(info.cwd) == "string" and info.cwd ~= "" then
        self:cwds()[info.sessionId] = info.cwd
      end
    end
    finish(true, sessions)
  end, function(err)
    self.notify("Unable to list sessions: " .. tostring(err), vim.log.levels.ERROR)
    finish(false, {})
  end, function()
    finish(false, {})
  end)
end

---Fetch the authoritative title for a session.
---
---OpenCode does not push `session_info_update`, so a title only appears in
---`session/list`. Query it when a session is created, when one is switched to,
---and at the end of each turn (that is when agents auto-generate a title from
---the first prompt).
---@param session table|nil
---@param cb fun()|nil invoked after the lookup settles
function Catalog:refresh_title(session, cb)
  local client = self.get_client()
  if not session or not client or self.connection() ~= "ready" then
    if cb then
      cb()
    end
    return
  end
  if not capabilities.supports(capabilities.agent(client), "sessionCapabilities.list") then
    if cb then
      cb()
    end
    return
  end
  if self.refreshing then
    self.pending = true
    -- Remember which session asked for a refresh; the coalesced retry must
    -- query that session, not whichever one is current when it lands.
    self.pending_session = session
    if cb then
      cb()
    end
    return
  end
  self.refreshing = true
  self.run(
    "title",
    client,
    session,
    function(task)
      local ok, result = task:call("list_sessions", session.cwd)
      if ok and type(result) == "table" then
        for _, info in ipairs(result.sessions or {}) do
          self:cache_title(info.sessionId, info.title)
        end
        if self:apply_title(session) then
          self.on_changed()
        end
      end
      if not ok then
        task.status = "failed"
      end
    end,
    nil,
    function(_, owned)
      if not owned then
        return
      end
      self.refreshing = false
      if cb then
        cb()
      end
      if self.pending then
        local pending_session = self.pending_session or session
        self.pending = false
        self.pending_session = nil
        self:refresh_title(pending_session)
      end
    end
  )
  log.debug("refreshing title for session %s", session.id)
end

return Catalog
