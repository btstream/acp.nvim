-- Runtime helpers shared by the controller and the services it wires up.
--
-- These are the small, policy-free operations that used to sit in the
-- controller's helper block: draining the outbox, pruning cached sessions,
-- resolving the session directory and naming a session for the winbar.
local M = {}

---@param deps {state: fun(): table, send: fun(text: string, attachments: table[]|nil, session: table): boolean,
---  generation: fun(): integer}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps }, { __index = M })
end

function M:state()
  return self.deps.state()
end

---Send queued messages while the runtime says there is work and the turn is idle.
---
---The outbox is a stable object across history replacement, so a replacement
---session that shares it must be drained too.
function M:dispatch_queued(session)
  local S = self:state()
  if S.conn.phase ~= "ready" or not S.sess.runtime:owns(session) then
    return
  end
  local runtime = S.sess.runtime
  local item = runtime:next_message(session)
  if not item then
    return
  end
  if self.deps.send(item.text, item.attachments, session) then
    runtime:ack_message(session, item)
    if session.status == "idle" then
      self:dispatch_queued(session)
    end
    return
  end
  runtime:restore_message(session, item)
  local replacement = runtime.sessions[session.id]
  if replacement and replacement ~= session and replacement.outbox == session.outbox then
    self:dispatch_queued(replacement)
  end
end

---Prune cached sessions, protecting the current one and pending interactions.
function M:prune_sessions()
  local S = self:state()
  local map = {}
  for _, interaction in ipairs(S.view.interactions:pending()) do
    map[interaction.id] = { session_id = interaction.session_id }
  end
  S.sess.runtime:prune(S.sess.current, map)
end

---Resolve the session working directory.
---
---This is Neovim's current working directory, so the panel, the agent and the
---user always agree on which directory they are working in. It can be pinned
---explicitly with `cwd` in the configuration.
---@return string
function M:resolve_cwd()
  local S = self:state()
  local path
  if S.config and S.config.cwd and S.config.cwd ~= "" then
    path = vim.fn.fnamemodify(S.config.cwd, ":p")
  else
    path = vim.fn.getcwd()
  end
  -- ACP requires an absolute path, and agents compare it byte for byte when
  -- they look a session up, so a trailing separator would make one directory
  -- look like two. The filesystem root keeps its single "/".
  if #path > 1 then
    path = (path:gsub("/+$", ""))
  end
  return path
end

---Whether a client/generation/session triple still describes the live UI.
---
---Every asynchronous callback checks this before touching state: a stale client,
---a stale operation generation or a session that is no longer selected must not
---mutate what the user sees now.
---@param client table|nil
---@param generation integer
---@param session table|nil
---@return boolean
function M:ui_current(client, generation, session)
  local S = self:state()
  return S.conn.client == client
    and self.deps.generation() == generation
    and (not session or (S.sess.current == session and S.sess.runtime:owns(session)))
end

---Drop every operation belonging to the configuration that is going away.
function M:invalidate_operations()
  local S = self:state()
  local inline = package.loaded["acp.inline"]
  if inline then
    inline.invalidate()
  end
  self.deps.reset_operations()
  if S.sess.catalog then
    S.sess.catalog:reset()
  end
  S.conn.replaying, S.conn.creating_session = false, false
  if S.sess.service then
    S.sess.service.replaying = false
    S.sess.service.creating = false
  end
  -- A queued retry belongs to the connection that failed; dropping the timer
  -- without its payload is worse than dropping both. Tell the user about any
  -- message that now needs a manual resend, so the queue does not look stuck.
  local dropped = S.conn.pending_auth_retries
  S.conn.pending_auth_retries, S.conn.auth_after_ready = nil, nil
  if dropped and S.conn.flow then
    for _, pending in ipairs(dropped) do
      S.conn.flow:abandon_parked(pending.session_id, false)
    end
  end
end

---Whether a decoded JSON value is a real, non-empty string.
---@param value any
---@return boolean
local function has_text(value)
  return type(value) == "string" and value ~= ""
end

---Display name for a session: its title, the cached title, or a short id.
---@param session table|nil
---@return string|nil
function M:session_label(session)
  if not session then
    return nil
  end
  if has_text(session.title) then
    return session.title
  end
  -- Titles are cached per session id; prefer that over the raw identifier.
  local catalog = self:state().sess.catalog
  local cached = catalog and catalog:title(session.id)
  if has_text(cached) then
    return cached
  end
  -- Fall back to a short, stable identifier instead of pretending there is no session.
  return "#" .. tostring(session.id):sub(-6)
end

---A compact snapshot for `:Acp debug` and bug reports.
---@return table
function M:debug_state()
  local S = self:state()
  local session = S.sess.current
  return {
    connection = S.conn.phase,
    session = session and session.id or nil,
    blocks = session and #session.blocks or 0,
    status = session and session.status or nil,
    queue = session and #session.queue or 0,
    pending_permissions = S.view.interactions and #S.view.interactions:pending() or 0,
    transport = S.conn.client and S.conn.client.transport_stats and S.conn.client:transport_stats() or nil,
    render = S.view.chat and S.view.chat:render_stats() or nil,
    spinner = S.view.chrome and S.view.chrome:diagnostics() or nil,
    panel = {
      chat = S.view.chat and S.view.chat.win or nil,
      input = S.view.input and S.view.input.win or nil,
    },
  }
end

return M
