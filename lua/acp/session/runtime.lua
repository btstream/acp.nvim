-- Session lifecycle, history transactions and outboxes. UI selection is not
-- ownership: a background session can keep processing its accepted messages.
local State = require("acp.session.state")
local memory = require("acp.session.memory")
local reducer = require("acp.session.reducer")
local M, Runtime = {}, {}
Runtime.__index = Runtime

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

function M.new(limits, sessions, thoughts)
  return setmetatable({
    limits = limits,
    sessions = sessions or {},
    thoughts = thoughts,
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
  session:track_changes()
  session:configure(result or {})
  self.sessions[id] = session
  return session
end

function Runtime:owns(session)
  local replay = self.replays[session.id]
  return self.sessions[session.id] == session or (replay and replay.session == session) or false
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
    return nil, false
  end
  return session, reducer.apply(session, update)
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
