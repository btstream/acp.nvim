-- Shared cooperative work queue for the editor thread.
--
-- Several subsystems each used to keep their own 4ms budget. Running them in
-- sequence could still block input for much longer, so they now share one
-- scheduler: every job runs at most one slice and then yields.
--
-- Slice cost is measured with hrtime rather than counted in items: one table
-- row and one short text line are not comparable units of work.
local M = {}

local PRIORITY = {
  ui = 1, -- interaction feedback, chrome
  protocol = 2, -- ordered wire work; may not be overtaken
  layout = 3,
  decoration = 4,
  background = 5,
}

local Scheduler = {}
Scheduler.__index = Scheduler

---@param opts {budget_ms?: number, clock?: fun(): number, defer?: fun(fn)}
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    budget = (opts.budget_ms or 4) * 1e6,
    clock = opts.clock or vim.uv.hrtime,
    defer = opts.defer or vim.schedule,
    queues = {},
    seq = 0,
    scheduled = false,
    disposed = false,
    wait = {},
    stats = { runs = 0, slices = 0, jobs = 0, max_slice_ms = 0, max_batch_ms = 0, starved = 0 },
  }, Scheduler)
end

---@param priority "ui"|"protocol"|"layout"|"decoration"|"background"
---@param fn fun(): boolean keep going
---@param opts table|nil
---@return table ticket
function Scheduler:enqueue(priority, fn, opts)
  assert(fn, "job callback is required")
  local ticket = {
    priority = priority,
    fn = fn,
    key = opts and opts.key,
    label = opts and opts.label,
    queued_at = self.clock(),
    seq = self.seq + 1,
  }
  self.seq = ticket.seq
  local queue = self.queues[priority]
  if not queue then
    queue = {}
    self.queues[priority] = queue
  end
  queue[#queue + 1] = ticket
  self.stats.jobs = self.stats.jobs + 1
  self:schedule()
  return ticket
end

---Drop queued and in-flight jobs matching a predicate.
---@param predicate fun(ticket: table): boolean
---@return integer dropped
function Scheduler:cancel(predicate)
  local dropped = 0
  for _, queue in pairs(self.queues) do
    for i = #queue, 1, -1 do
      if predicate(queue[i]) then
        queue[i].cancelled = true
        table.remove(queue, i)
        dropped = dropped + 1
      end
    end
  end
  if self.current and predicate(self.current) then
    self.current.cancelled = true
    dropped = dropped + 1
  end
  return dropped
end

function Scheduler:schedule()
  if self.scheduled or self.disposed then
    return
  end
  self.scheduled = true
  self.defer(function()
    self.scheduled = false
    self:run()
  end)
end

---Failures are contained per job so one bad callback cannot wedge the queue.
local function report(ticket, err)
  require("acp.log").error("scheduled %s job failed: %s", ticket.label or ticket.priority, tostring(err))
end

---Run one round. Each queue is visited in priority order and gets at most one
---slice; deadline checks happen between slices, never inside a job.
function Scheduler:run()
  if self.disposed then
    return
  end
  local started = self.clock()
  local deadline = started + self.budget
  local order = {}
  for name in pairs(self.queues) do
    order[#order + 1] = name
  end
  table.sort(order, function(a, b)
    -- A queue skipped by a spent budget takes precedence next round. This
    -- bounds starvation even when a high-priority slice spends the whole batch.
    local wa, wb = self.wait[a] or 0, self.wait[b] or 0
    if wa ~= wb then
      return wa > wb
    end
    return (PRIORITY[a] or 99) < (PRIORITY[b] or 99)
  end)
  local visited = {}
  for _, name in ipairs(order) do
    if self.clock() >= deadline then
      break
    end
    local queue = self.queues[name]
    while queue and queue[1] and queue[1].cancelled do
      table.remove(queue, 1)
    end
    -- FIFO within a priority: protocol order is part of the contract.
    local ticket = queue and queue[1]
    if ticket then
      table.remove(queue, 1)
      self.current = ticket
      local slice_start = self.clock()
      local ok, more = pcall(ticket.fn)
      local slice_ms = (self.clock() - slice_start) / 1e6
      self.current = nil
      visited[name] = true
      self.wait[name] = 0
      self.stats.slices = self.stats.slices + 1
      if slice_ms > self.stats.max_slice_ms then
        self.stats.max_slice_ms = slice_ms
      end
      if not ok then
        report(ticket, more)
      elseif not ticket.cancelled and more then
        if name == "protocol" then
          table.insert(queue, 1, ticket)
        else
          queue[#queue + 1] = ticket
        end
      end
    end
  end
  self.stats.runs = self.stats.runs + 1
  for name, queue in pairs(self.queues) do
    if #queue > 0 and not visited[name] then
      self.wait[name] = (self.wait[name] or 0) + 1
      self.stats.starved = self.stats.starved + 1
    end
  end
  self.stats.max_batch_ms = math.max(self.stats.max_batch_ms, (self.clock() - started) / 1e6)
  for _, queue in pairs(self.queues) do
    if #queue > 0 then
      self:schedule()
      return
    end
  end
end

---Wait until no queued or in-flight work remains. Tests only: production code
---must stay event driven so the editor keeps handling input.
---@param timeout_ms integer|nil
---@return boolean idle
function Scheduler:flush(timeout_ms)
  local deadline = vim.uv.hrtime() + (timeout_ms or 1000) * 1e6
  while vim.uv.hrtime() < deadline do
    local pending = false
    for _, queue in pairs(self.queues) do
      if #queue > 0 then
        pending = true
        break
      end
    end
    if not pending and not self.current then
      return true
    end
    vim.wait(1)
  end
  return false
end

function Scheduler:depth()
  local total = 0
  for _, queue in pairs(self.queues) do
    total = total + #queue
  end
  return total
end

function Scheduler:dispose()
  self.disposed = true
  self.queues = {}
  self.current = nil
end

M.Scheduler = Scheduler
M.PRIORITY = PRIORITY

---One editor-wide queue: transport, layout and decoration must share a budget
---or they can each spend it in the same loop iteration.
M.shared = M.new()

---@param budget_ms number
function M.configure(budget_ms)
  M.shared.budget = math.max(1, budget_ms) * 1e6
end

return M
