-- Session data model and update reduction.
local M = {}

---@class AcpBlock
---@field id string
---@field kind string user|agent|thought|tool|plan|notice|compaction|error|system
---@field text string
---@field role string|nil
---@field status string|nil
---@field title string|nil
---@field name string|nil
---@field tool_kind string|nil
---@field content table[]|nil
---@field locations table[]|nil
---@field raw_input any
---@field raw_output any
---@field expanded boolean|nil
---@field optimistic boolean|nil
---@field child table|nil
---@field entries table[]|nil
---@field severity string|nil

local counter = 0

local function next_id(prefix)
  counter = counter + 1
  return (prefix or "b") .. counter
end

-- Long-running sessions used to keep every block forever, so a session left
-- open for days grew without bound and every render walked the whole history.
-- Older blocks are dropped once the transcript exceeds this many entries.
local MAX_BLOCKS = 2000

-- Streaming text accumulates one chunk at a time. Concatenating with `..` on
-- every chunk copies the whole message, so a long streamed answer used to cost
-- O(n²). Chunks are buffered in `_parts`; a metatable materialises them once,
-- on first read, keeping `block.text` a plain string for every caller.
local block_mt = {
  __index = function(tbl, key)
    if key == "text" then
      local parts = rawget(tbl, "_parts")
      if parts then
        local joined = #parts > 0 and table.concat(parts) or ""
        rawset(tbl, "_parts", nil)
        rawset(tbl, "text", joined)
        return joined
      end
    end
    return nil
  end,
  __newindex = function(tbl, key, value)
    -- An explicit assignment supersedes any buffered chunks.
    if key == "text" then
      rawset(tbl, "_parts", nil)
    end
    rawset(tbl, key, value)
  end,
}

---Append `text` to a block's streaming text without copying what came before.
---@param block AcpBlock
---@param text string
function M.append_block_text(block, text)
  if text == nil or text == "" then
    return
  end
  if getmetatable(block) ~= block_mt then
    setmetatable(block, block_mt)
  end
  local parts = rawget(block, "_parts")
  if not parts then
    parts = { rawget(block, "text") or "" }
    rawset(block, "text", nil)
    rawset(block, "_parts", parts)
  end
  parts[#parts + 1] = text
end

---Materialise a block's text, folding any buffered streaming chunks.
---@param block AcpBlock
---@return string
function M.block_text(block)
  return block.text or ""
end

---@class AcpSessionState
---@field id string
---@field cwd string
---@field title string|nil
---@field blocks AcpBlock[]
---@field tools table<string, AcpBlock>
---@field status string idle|running|cancelling
---@field config_options table[]
---@field modes table[]|nil
---@field current_mode string|nil
---@field commands table[]
---@field usage table|nil
---@field queue table[]
---@field started_at integer
---@field turn integer
---@field pending_user AcpBlock|nil
---@field last_error string|nil

local Session = {}
Session.__index = Session

---@param id string
---@param cwd string
---@return AcpSessionState
function M.new(id, cwd)
  return setmetatable({
    id = id,
    cwd = cwd,
    title = nil,
    blocks = {},
    tools = {},
    status = "idle",
    config_options = {},
    modes = nil,
    current_mode = nil,
    commands = {},
    usage = nil,
    queue = {},
    started_at = os.time(),
    turn = 0,
    pending_user = nil,
    dirty = false,
  }, Session)
end

function Session:append(block)
  self.blocks[#self.blocks + 1] = block
  self:trim()
  return block
end

---Drop the oldest blocks once the transcript is over the cap.
---
---Trimming happens in batches (down to 90% of the cap) so the O(n) compaction
---cost is amortised over many appends instead of running on every render tick.
function Session:trim()
  local n = #self.blocks
  if n <= MAX_BLOCKS then
    return
  end
  local keep_from = n - math.floor(MAX_BLOCKS * 0.9) + 1
  local kept = {}
  local removed = {}
  for i = 1, keep_from - 1 do
    removed[self.blocks[i].id] = true
  end
  for i = keep_from, n do
    kept[#kept + 1] = self.blocks[i]
  end
  self.blocks = kept
  -- Drop tool mappings whose block was trimmed; otherwise `session.tools`
  -- would keep resurrecting removed entries on the next tool_call_update.
  for id, tool in pairs(self.tools) do
    if removed[tool.id] then
      self.tools[id] = nil
    end
  end
  self.trimmed = true
end

function Session:append_text(kind, text, message_id)
  local last = self.blocks[#self.blocks]
  if last and last.kind == kind and last.status == "streaming" then
    if not message_id or last.message_id == nil or last.message_id == message_id then
      last.message_id = last.message_id or message_id
      M.append_block_text(last, text)
      return last
    end
  end
  return self:append({
    id = next_id(kind),
    kind = kind,
    text = text,
    status = "streaming",
    message_id = message_id,
  })
end

---Start a new turn: close out any streaming blocks.
---@return integer turn the new turn number, used to reject stale events
function Session:begin_turn()
  self.turn = self.turn + 1
  self.status = "running"
  for _, block in ipairs(self.blocks) do
    if block.status == "streaming" then
      block.status = nil
    end
  end
  self.pending_user = nil
  return self.turn
end

---Insert the optimistic user message for a prompt.
---@param text string
---@param attachments table|nil
function Session:add_local_user(text, attachments)
  local block = self:append({
    id = next_id("user"),
    kind = "user",
    text = text,
    status = nil,
    optimistic = true,
    attachments = attachments,
  })
  self.pending_user = block
  return block
end

---Handle a streamed user message chunk, replacing the optimistic message when possible.
function Session:user_chunk(text, message_id)
  local pending = self.pending_user
  if pending and pending.optimistic then
    pending.optimistic = false
    pending.text = text
    pending.message_id = message_id
    pending.status = "streaming"
    return pending
  end
  return self:append_text("user", text, message_id)
end

---Close streaming blocks at the end of a turn.
---@param stop_reason string|nil
function Session:finish_turn(stop_reason)
  -- Cancelled and error turns both leave tools that will never report again;
  -- they must not keep showing as "running" forever.
  local interrupted = stop_reason == "cancelled" or stop_reason == "error"
  for _, block in ipairs(self.blocks) do
    if block.status == "streaming" then
      block.status = nil
    end
    if block.kind == "tool" and (block.status == "pending" or block.status == "in_progress") then
      if interrupted then
        block.status = stop_reason == "cancelled" and "cancelled" or "failed"
      end
    end
  end
  self.status = "idle"
  self.pending_user = nil
  self.stop_reason = stop_reason
end

---Return the active config option with the given category.
---@param category string
---@return table|nil
function Session:option_by_category(category)
  for _, opt in ipairs(self.config_options or {}) do
    if opt.category == category then
      return opt
    end
  end
  return nil
end

---@param option table
---@return {value: string|boolean, name: string, description: string|nil}[]
function M.select_values(option)
  local cached = option._select_values
  if cached and cached.src == option.options then
    return cached.values
  end
  local out = {}
  for _, entry in ipairs(option.options or {}) do
    if entry.group then
      for _, child in ipairs(entry.options or {}) do
        out[#out + 1] = child
      end
    else
      out[#out + 1] = entry
    end
  end
  option._select_values = { src = option.options, values = out }
  return out
end

---@param option table
---@param value string|boolean
---@return string|nil
function M.option_label(option, value)
  -- The toolbar calls this on every redraw; index the values once instead of
  -- rescanning the option list each time.
  local cached = option._value_names
  if not cached or cached.src ~= option.options then
    cached = { src = option.options, names = {} }
    for _, entry in ipairs(M.select_values(option)) do
      if entry.value ~= nil and cached.names[entry.value] == nil then
        cached.names[entry.value] = entry.name
      end
    end
    option._value_names = cached
  end
  if value ~= nil and cached.names[value] ~= nil then
    return cached.names[value]
  end
  if type(value) == "string" then
    return value
  end
  return nil
end

return M
