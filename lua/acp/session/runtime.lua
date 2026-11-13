-- Session lifecycle, history transactions and outboxes. UI selection is not
-- ownership: a background session can keep processing its accepted messages.
local State = require("acp.session.state")
local memory = require("acp.session.memory")
local reducer = require("acp.session.reducer")
local M, Runtime = {}, {}
Runtime.__index = Runtime

-- Updates for a session id that is still being created. Real agents may stream
-- before the session/new response arrives; drop the batch only if creation
-- fails. Bounded so a wedged creation cannot grow without limit.
local MAX_CREATE_UPDATES = 256
local MAX_CREATE_BYTES = 1024 * 1024

function Runtime:outbox(session)
  if not session.outbox or session.outbox.messages ~= session.queue then
    session.outbox = { messages = session.queue, bytes = session.queue_bytes or 0 }
  end
  return session.outbox
end

function Runtime:sync_outbox(session)
  local outbox = self:outbox(session)
  session.queue_bytes = outbox.bytes
  local current = self.sessions[session.id]
  if current and current.outbox == outbox then
    current.queue_bytes = outbox.bytes
  end
end

function M.new(limits, sessions, thoughts, profile)
  return setmetatable({
    limits = limits,
    sessions = sessions or {},
    thoughts = thoughts,
    profile = profile,
    replays = {},
    clock = 0,
    selection = 0,
  }, Runtime)
end

function Runtime:create(id, cwd, result)
  local existing = self.sessions[id]
  if
    existing and (#existing.queue > 0 or existing.status ~= "idle" or (existing.outbox and existing.outbox.reserved))
  then
    error("new session id conflicts with an active runtime")
  end
  local session = State.new(id, cwd, self.limits)
  session.thoughts = self.thoughts or session.thoughts
  session.profile = self.profile
  session:track_changes()
  session:configure(result or {})
  self.sessions[id] = session
  return session
end

function Runtime:owns(session)
  local replay = self.replays[session.id]
  return self.sessions[session.id] == session or (replay and replay.session == session) or false
end

---Register a session id placeholder while `session/new` is in flight.
---@return integer token
function Runtime:expect_create()
  self.creation_seq = (self.creation_seq or 0) + 1
  self.creating = { token = self.creation_seq, updates = {}, bytes = 0, dropped = 0 }
  return self.creation_seq
end

---Finish a creation and replay any updates buffered for it.
---@param token integer
---@param id string
---@param cwd string
---@param result table
---@return table|nil session, integer applied
function Runtime:commit_create(token, id, cwd, result)
  local pending = self.creating
  if not pending or pending.token ~= token then
    return nil, 0
  end
  self.creating = nil
  local session = self:create(id, cwd, result)
  local applied = 0
  for _, update in ipairs(pending.updates) do
    if reducer.apply(session, update) then
      applied = applied + 1
    end
  end
  return session, applied
end

---Abandon a creation and its buffered updates.
---@param token integer
function Runtime:drop_create(token)
  if self.creating and self.creating.token == token then
    self.creating = nil
  end
end

local function buffer_create(runtime, update)
  local pending = runtime.creating
  local size = memory.size(update)
  pending.bytes = pending.bytes + size
  pending.updates[#pending.updates + 1] = update
  while #pending.updates > MAX_CREATE_UPDATES or pending.bytes > MAX_CREATE_BYTES do
    local dropped = table.remove(pending.updates, 1)
    pending.bytes = pending.bytes - memory.size(dropped)
    pending.dropped = pending.dropped + 1
  end
end

function Runtime:intend()
  self.selection = self.selection + 1
  return self.selection
end

function Runtime:select(session)
  self.clock = self.clock + 1
  if session then
    session.last_used = self.clock
  end
end

function Runtime:stage(id, cwd)
  local previous = self.sessions[id]
  local session = State.new(id, cwd, self.limits)
  session.thoughts = self.thoughts or session.thoughts
  session.profile = self.profile
  session:track_changes()
  -- A replayed session is history: its tool cards stay collapsed so reading an
  -- old conversation does not unfold every diff at once.
  session.historical = true
  if previous then
    session.outbox = self:outbox(previous)
    session.queue, session.queue_bytes, session.turn = session.outbox.messages, session.outbox.bytes, previous.turn
  end
  self.replays[id] = { session = session, previous = previous }
  return session
end

function Runtime:commit(session)
  local replay = self.replays[session.id]
  if not replay or replay.session ~= session then
    return false
  end
  self.replays[session.id] = nil
  self.sessions[session.id] = session
  session.needs_load = false
  -- Blocks replayed so far stay collapsed (they carry explicit `expanded`),
  -- while new work after this point is live and follows the live defaults.
  session.historical = false
  return true
end

function Runtime:rollback(session)
  local replay = self.replays[session.id]
  if replay and replay.session == session then
    self.replays[session.id] = nil
  end
end

function Runtime:remove(id)
  self.replays[id], self.sessions[id] = nil, nil
end

function Runtime:apply(id, update)
  local replay = self.replays[id]
  local session = replay and replay.session or self.sessions[id]
  if not session then
    if self.creating then
      buffer_create(self, update)
      return nil, false, true
    end
    return nil, false, false
  end
  return session, reducer.apply(session, update), false
end

function Runtime:enqueue(session, text, attachments)
  local outbox = self:outbox(session)
  local item = { text = text, attachments = attachments }
  item.bytes = memory.size(item)
  if #session.queue >= self.limits.max_queued_messages or outbox.bytes + item.bytes > self.limits.max_queue_bytes then
    return false
  end
  outbox.bytes = outbox.bytes + item.bytes
  session.queue[#session.queue + 1] = item
  self:sync_outbox(session)
  return true
end

---Begin a turn without adding a new optimistic user block.
---
---Used when a prompt is retried after a login: the original message is still
---in the transcript, so adding it again would show it twice.
---@param session table
---@return integer turn
function Runtime:rebegin_turn(session)
  return session:begin_turn()
end

function Runtime:begin_turn(session, text, attachments)
  local turn = session:begin_turn()
  session:add_local_user(text, attachments)
  return turn
end

function Runtime:finish_turn(session, turn, reason)
  if not self:owns(session) or session.turn ~= turn then
    return false
  end
  session:finish_turn(reason)
  return true
end

function Runtime:next_message(session)
  local outbox = self:outbox(session)
  if
    not self:owns(session)
    or session.status ~= "idle"
    or session.needs_load
    or self.replays[session.id]
    or outbox.reserved
  then
    return nil
  end
  local item = table.remove(session.queue, 1)
  if item then
    outbox.bytes = math.max(0, outbox.bytes - (item.bytes or 0))
    outbox.reserved = item
    self:sync_outbox(session)
  end
  return item
end

function Runtime:restore_message(session, item)
  local outbox = self:outbox(session)
  if outbox.reserved == item then
    outbox.reserved = nil
  end
  table.insert(session.queue, 1, item)
  outbox.bytes = outbox.bytes + (item.bytes or 0)
  self:sync_outbox(session)
end

function Runtime:ack_message(session, item)
  local outbox = self:outbox(session)
  if outbox.reserved == item then
    outbox.reserved = nil
  end
end

function Runtime:connection_lost()
  self.replays = {}
  self.creating = nil
  for _, session in pairs(self.sessions) do
    session.needs_load = true
    if session.status ~= "idle" then
      session:finish_turn("error")
    end
    session.prompt_task = nil
  end
end

function Runtime:prune(active, permissions)
  local protected = vim.tbl_extend("force", {}, permissions or {})
  for id in pairs(self.replays) do
    protected["replay:" .. id] = { session_id = id }
  end
  memory.prune(self.sessions, active, protected, self.limits)
end

return M
