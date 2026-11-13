-- Scoped asynchronous operations. A task owns its client/session identities;
-- changing configuration or connection cancels it before replacing that state.
local async = require("acp.async")
local M = {}
local Scope, Task = {}, {}
Scope.__index, Task.__index = Scope, Task

function M.new(state)
  return setmetatable({ state = state, generation = 0, sequence = 0, active = {} }, Scope)
end

---Read the connection/session facts a task fences on.
---
---The controller's state is partitioned (`app/stores`), but tests and small
---doubles pass a plain `{client = ..., sessions = {}}`. Resolving through the
---store view when it exists, and falling back to the flat fields otherwise,
---keeps both working without leaking the store layout into `tasks`.
---@param state table
---@return table|null client, table sessions, table|null runtime
local function facts(state)
  local stores = require("acp.app.stores")
  if state.conn or state.sess then
    local split = stores.stores(state)
    return split.connection.client, split.session.all, split.session.runtime
  end
  return state.client, state.sessions or {}, state.runtime
end

function Task:context_current()
  local client = facts(self.scope.state())
  return self.generation == self.scope.generation
    and self.scope.active[self.key] == self
    and client == self.client
    and (not self.client or self.client.generation == self.client_generation)
end

function Task:current()
  if not self:context_current() then
    return false
  end
  if not self.session then
    return true
  end
  local _, sessions, runtime = facts(self.scope.state())
  return (runtime and runtime:owns(self.session)) or sessions[self.session.id] == self.session
end

function Task:check()
  if self.status ~= "running" or not self:current() then
    self:cancel()
    error(async.CANCELLED, 0)
  end
end

function Task:call(method, ...)
  self:check()
  local ok, result = self.client[method](self.client, ...)
  self:check() -- every asynchronous boundary has the same identity fence
  return ok, result
end

function Task:cancel()
  if self.status ~= "running" then
    return
  end
  self.status = "cancelled"
  async.cancel(self.co or coroutine.running())
end

function Scope:run(key, client, session, fn, on_error, on_finally)
  self.sequence = self.sequence + 1
  local task = setmetatable({
    scope = self,
    key = key,
    client = client,
    client_generation = client and client.generation,
    session = session,
    generation = self.generation,
    id = self.sequence,
    status = "running",
  }, Task)
  local previous = self.active[key]
  self.active[key] = task
  if previous then
    previous:cancel()
  end
  task.co = async.run(function()
    task.co = coroutine.running() -- available even during a reentrant send
    async.finally(function()
      local current = task:context_current()
      if task.status == "running" then
        task.status = "succeeded"
      end
      if self.active[key] == task then
        self.active[key] = nil
      end
      if on_finally then
        on_finally(task, current)
      end
    end)
    task:check()
    fn(task)
  end, function(err)
    task.status = "failed"
    if task:context_current() and on_error then
      on_error(err, task)
    end
  end)
  return task
end

function Scope:reset()
  self.generation = self.generation + 1
  local previous = self.active
  self.active = {}
  for _, task in pairs(previous) do
    task:cancel()
  end
end

function Scope:cancel_session(session, except)
  local matches = {}
  for _, task in pairs(self.active) do
    if task.session and task.session.id == session.id and task ~= except then
      matches[#matches + 1] = task
    end
  end
  for _, task in ipairs(matches) do
    task:cancel()
  end
end

return M
