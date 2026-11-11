-- Optional, per-view counters. No logging or timers on the disabled path.
--
-- The averages answer "how expensive is this on average"; the buckets answer
-- "how bad is the worst one", which is what decides whether the spinner stalls.
local M = {}

-- Upper bounds in milliseconds. Anything above the last bucket is counted in
-- `overflow`, so a pathological call is still visible without tracking every
-- sample.
local BUCKETS = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 }
local SLOW_MS = 8
local SLOW_KEEP = 20

function M.record(view, name, start, context)
  if not start then
    return
  end
  local elapsed = (vim.uv.hrtime() - start) / 1e6
  view.metrics = view.metrics or {}
  local entry = view.metrics[name]
  if not entry then
    entry = { count = 0, total_ms = 0, max_ms = 0, buckets = {}, overflow = 0 }
    for i = 1, #BUCKETS do
      entry.buckets[i] = 0
    end
    view.metrics[name] = entry
  end
  entry.count = entry.count + 1
  entry.total_ms = entry.total_ms + elapsed
  entry.max_ms = math.max(entry.max_ms, elapsed)
  local placed = false
  for i = 1, #BUCKETS do
    if elapsed <= BUCKETS[i] then
      entry.buckets[i] = entry.buckets[i] + 1
      placed = true
      break
    end
  end
  if not placed then
    entry.overflow = entry.overflow + 1
  end
  if elapsed >= SLOW_MS then
    view.slow_tasks = view.slow_tasks or {}
    local list = view.slow_tasks
    list[#list + 1] = { name = name, ms = math.floor(elapsed * 10 + 0.5) / 10, context = context }
    if #list > SLOW_KEEP then
      table.remove(list, 1)
    end
  end
end

function M.start(view)
  local render = view.config.ui.render
  return render and render.profile and vim.uv.hrtime() or nil
end

---Describe a block for a slow-task record without embedding its content.
---@param block table|nil
---@return table|nil
function M.describe(block)
  if not block then
    return nil
  end
  return {
    id = block.id,
    kind = block.kind,
    tool_kind = block.tool_kind,
    text_bytes = type(block.text) == "string" and #block.text or nil,
    items = type(block.content) == "table" and #block.content or nil,
  }
end

M.BUCKETS = BUCKETS
M.SLOW_MS = SLOW_MS
M.SLOW_KEEP = SLOW_KEEP

return M
