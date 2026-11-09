-- Budgets cover retained payload bytes, not exact Lua allocator/RSS usage.
local M = {}
local MARK = "\n[Truncated by local memory limit]"

function M.size(value, seen)
  if type(value) == "string" then
    return #value
  end
  if type(value) ~= "table" then
    return 8
  end
  seen = seen or {}
  if seen[value] then
    return 0
  end
  seen[value] = true
  local bytes = 0
  for k, v in pairs(value) do
    bytes = bytes + 32 + M.size(k, seen) + M.size(v, seen)
  end
  return bytes
end

function M.clip(text, limit)
  if #text <= limit then
    return text
  end
  local n = math.max(0, limit - #MARK)
  -- Do not split a UTF-8 codepoint at the byte boundary.
  while n > 0 and text:byte(n + 1) and text:byte(n + 1) >= 128 and text:byte(n + 1) < 192 do
    n = n - 1
  end
  return text:sub(1, n) .. MARK:sub(1, math.max(0, limit - n))
end

local function bounded(value, budget, seen, depth)
  if budget.left <= 0 then
    budget.truncated = true
    return nil
  end
  if type(value) == "string" then
    local clipped = M.clip(value, budget.left)
    budget.truncated = budget.truncated or #clipped < #value
    budget.left = budget.left - #clipped
    return clipped
  elseif type(value) ~= "table" then
    budget.left = budget.left - 8
    return value
  end
  if seen[value] or depth > 16 then
    budget.truncated = true
    return nil
  end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    if budget.left <= 32 then
      budget.truncated = true
      break
    end
    budget.left = budget.left - 32 - (type(k) == "string" and #k or 0)
    out[k] = bounded(v, budget, seen, depth + 1)
  end
  seen[value] = nil
  return out
end

-- Text is budgeted separately during streaming; the remaining fields share
-- one budget rather than each receiving an independent megabyte allowance.
function M.bound_block(block, limit)
  local budget = { left = limit, truncated = false }
  for _, key in ipairs({
    "text",
    "title",
    "name",
    "detail",
    "entries",
    "locations",
    "attachments",
    "child",
    "content",
    "raw_input",
    "raw_output",
    "error",
  }) do
    local value = rawget(block, key)
    if value ~= nil then
      block[key] = bounded(value, budget, {}, 0)
    end
  end
  local parts = rawget(block, "_parts")
  if parts then
    -- Streaming blocks only have text; account chunks without materialising.
    local size = block._text_bytes
    if not size then
      size = 0
      for _, part in ipairs(parts) do
        size = size + #part
      end
    end
    if size > budget.left then
      local text = M.clip(table.concat(parts), math.max(0, budget.left))
      rawset(block, "_parts", nil)
      rawset(block, "text", text)
      size, budget.truncated = #text, true
    end
    block._text_bytes = size
    budget.left = budget.left - size
  end
  block.truncated = block.truncated or budget.truncated
  return math.max(0, limit - budget.left)
end

function M.prune(sessions, active, pending, limits)
  local total, count, candidates = 0, 0, {}
  for _, session in pairs(sessions) do
    count, total = count + 1, total + (session.bytes or 0)
  end
  if count <= limits.max_cached_sessions and total <= limits.max_total_bytes then
    return
  end
  local protected = {}
  for _, permission in pairs(pending or {}) do
    protected[permission.session_id] = true
  end
  for id, session in pairs(sessions) do
    if
      session ~= active
      and session.status == "idle"
      and #session.queue == 0
      and not (session.outbox and session.outbox.reserved)
      and not protected[id]
    then
      candidates[#candidates + 1] = session
    end
  end
  table.sort(candidates, function(a, b)
    return (a.last_used or 0) < (b.last_used or 0)
  end)
  for _, session in ipairs(candidates) do
    if count <= limits.max_cached_sessions and total <= limits.max_total_bytes then
      break
    end
    sessions[session.id] = nil
    count, total = count - 1, total - (session.bytes or 0)
  end
end

return M
