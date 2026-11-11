-- Session data model and update reduction.
local M = {}
local memory = require("acp.session.memory")

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
---@field toggled boolean|nil user collapsed/expanded it explicitly
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
      rawset(tbl, "_append_base", nil)
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
  if block._max_bytes then
    local size = block._text_bytes or #(rawget(block, "text") or "")
    local remaining = block._max_bytes - size
    if remaining <= 0 then
      block.truncated = true
      return
    end
    if #text > remaining then
      text = memory.clip(text, remaining)
      block.truncated = true
    end
    block._text_bytes = size + #text
  end
  if getmetatable(block) ~= block_mt then
    setmetatable(block, block_mt)
  end
  local parts = rawget(block, "_parts")
  if not parts then
    parts = { rawget(block, "text") or "" }
    rawset(block, "_append_base", parts[1])
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
---@field historical boolean|nil replayed from history, not a live session

local Session = {}
Session.__index = Session

---@param id string
---@param cwd string
---@return AcpSessionState
function M.new(id, cwd, limits)
  local queue = {}
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
    queue = queue,
    outbox = { messages = queue, bytes = 0 },
    started_at = os.time(),
    turn = 0,
    pending_user = nil,
    dirty = false,
    thoughts = require("acp.config").defaults.ui.thoughts,
    limits = limits or require("acp.config").defaults.memory,
    bytes = 0,
    version = 0,
    changes = {},
  }, Session)
end

function Session:append(block)
  self:finish_thought()
  if block.kind == "thought" and block.status == "streaming" then
    self.active_thought = block
  end
  block._index = #self.blocks + 1
  block._max_bytes = self.limits.max_block_bytes
  self.blocks[#self.blocks + 1] = block
  self:touch(block)
  return block
end

---Record explicit model mutations so controller-owned views need not scan
---stable history. Untracked standalone consumers retain the legacy diff path.
function Session:track_changes()
  self.tracked = true
end

---Mutation boundary for UI/controller changes; reducers remain model-internal.
function Session:update(block, fields, payload_changed)
  for key, value in pairs(fields) do
    block[key] = value
  end
  self:touch(block, payload_changed)
end

function Session:toggle(block)
  -- Remember that the user made the call: later tool updates must not reopen a
  -- card that was deliberately closed.
  block.toggled = true
  self:update(block, { expanded = not block.expanded }, false)
end

---Close a streaming thought. A finished thought defaults to collapsed; the
---text stays in the model so it can be reopened.
---@param block AcpBlock
function Session:finish_thought(block)
  block = block or self.active_thought
  if not block then
    return
  end
  if self.active_thought == block then
    self.active_thought = nil
  end
  if block.kind ~= "thought" or block.status ~= "streaming" then
    return
  end
  block.status = nil
  block._append_base = nil
  if (self.thoughts or {}).collapse_on_finish ~= false then
    block.expanded = false
  end
  self:touch(block, false)
end

function Session:configure(result)
  assert(type(result) == "table", "invalid session response")
  for _, field in ipairs({ "configOptions", "modes" }) do
    assert(result[field] == nil or type(result[field]) == "table", "invalid session " .. field)
  end
  if result.configOptions then
    self.config_options = result.configOptions
  end
  if result.modes then
    self.modes, self.current_mode = result.modes, result.currentModeId
  end
end

function Session:set_option(option, value, result)
  if result and result.configOptions then
    self:configure(result)
  else
    option.currentValue = value
  end
end

function Session:cancel_turn()
  if self.status ~= "running" then
    return false
  end
  self.status = "cancelling"
  self:finish_thought()
  for _, block in ipairs(self.blocks) do
    if block.kind == "tool" and (block.status == "pending" or block.status == "in_progress") then
      self:update(block, { status = "cancelled" }, false)
    end
  end
  return true
end

function Session:touch(block, payload_changed)
  if not block then
    return
  end
  if payload_changed ~= false then
    if rawget(block, "text") ~= nil then
      block._append_base = nil
    end
    local previous = block._bytes or 0
    block._bytes = memory.bound_block(block, self.limits.max_block_bytes)
    self.bytes = self.bytes + block._bytes - previous
    block._text_bytes = rawget(block, "text") and #rawget(block, "text") or block._text_bytes
  end
  block._revision = (block._revision or 0) + 1
  self.version = self.version + 1
  self.changes[(self.version - 1) % 256 + 1] = { version = self.version, index = block._index or 1 }
  self:trim()
end

function Session:changed_since(version)
  if version == self.version then
    return nil
  end
  if not version or self.version - version > 256 then
    return 1
  end
  local first = #self.blocks + 1
  for seq = version + 1, self.version do
    local change = self.changes[(seq - 1) % 256 + 1]
    if not change or change.version ~= seq then
      return 1
    end
    first = math.min(first, change.index)
  end
  return first
end

---Drop the oldest blocks once the transcript is over the cap.
---
---Trimming happens in batches (down to 90% of the cap) so the O(n) compaction
---cost is amortised over many appends instead of running on every render tick.
function Session:trim()
  local n = #self.blocks
  if n <= MAX_BLOCKS and self.bytes <= self.limits.max_session_bytes then
    return
  end
  local keep_from = math.max(1, n - math.floor(MAX_BLOCKS * 0.9) + 1)
  local retained = self.bytes
  for i = 1, keep_from - 1 do
    retained = retained - (self.blocks[i]._bytes or 0)
  end
  while keep_from < n and retained > self.limits.max_session_bytes * 0.9 do
    retained = retained - (self.blocks[keep_from]._bytes or 0)
    keep_from = keep_from + 1
  end
  local kept = {}
  local removed = {}
  for i = 1, keep_from - 1 do
    removed[self.blocks[i].id] = true
    if self.blocks[i] == self.active_thought then
      self.active_thought = nil
    end
  end
  for i = keep_from, n do
    kept[#kept + 1] = self.blocks[i]
  end
  self.blocks = kept
  self.bytes = retained
  for index, block in ipairs(kept) do
    block._index = index
  end
  self.version = self.version + 1
  self.changes[(self.version - 1) % 256 + 1] = { version = self.version, index = 1 }
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
  local cancelled_thought = kind == "thought" and self.status == "cancelling"
  if last and last.kind == kind and (last.status == "streaming" or cancelled_thought) then
    if not message_id or last.message_id == nil or last.message_id == message_id then
      last.message_id = last.message_id or message_id
      M.append_block_text(last, text)
      self:touch(last)
      return last
    end
  end
  if kind == "thought" and last and last.kind == "thought" then
    self:finish_thought(last)
  end
  local block = self:append({
    id = next_id(kind),
    kind = kind,
    text = text,
    status = "streaming",
    message_id = message_id,
    expanded = kind == "thought" and (self.thoughts or {}).expand_while_streaming ~= false and true or nil,
  })
  if cancelled_thought then
    self:finish_thought(block)
  end
  return block
end

---Start a new turn: close out any streaming blocks.
---@return integer turn the new turn number, used to reject stale events
function Session:begin_turn()
  self.turn = self.turn + 1
  self.status = "running"
  for _, block in ipairs(self.blocks) do
    if block.kind == "thought" then
      self:finish_thought(block)
    elseif block.status == "streaming" then
      block.status = nil
      block._append_base = nil
      self:touch(block, false)
    end
  end
  self.pending_user = nil
  return self.turn
end

---Insert the optimistic user message for a prompt.
---@param text string
---@param attachments table|nil
function Session:add_local_user(text, attachments)
  local positioned = false
  for _, att in ipairs(attachments or {}) do
    if att.kind == "image" and type(att.prompt_offset) == "number" then
      positioned = true
      break
    end
  end
  local block = self:append({
    id = next_id("user"),
    kind = "user",
    text = text,
    status = nil,
    optimistic = true,
    attachments = attachments,
    positioned_prompt = positioned or nil,
  })
  self.pending_user = block
  return block
end

---Handle a streamed user message chunk, replacing the optimistic message when possible.
function Session:user_chunk(text, message_id)
  local pending = self.pending_user
  if pending and pending.positioned_prompt then
    -- The local message already has the complete ordered multimodal prompt.
    -- Agents may echo text and images as separate chunks (or omit images from
    -- their echo). Replacing/concatenating those would corrupt saved offsets.
    pending.optimistic = false
    pending.message_id = message_id or pending.message_id
    pending.status = "streaming"
    self:touch(pending, false)
    return pending
  end
  if pending and pending.optimistic then
    pending.optimistic = false
    pending.text = text
    pending.message_id = message_id
    pending.status = "streaming"
    self:touch(pending)
    return pending
  end
  return self:append_text("user", text, message_id)
end

---Close streaming blocks at the end of a turn.
---@param stop_reason string|nil
function Session:finish_turn(stop_reason)
  self:finish_thought()
  -- Cancelled and error turns both leave tools that will never report again;
  -- they must not keep showing as "running" forever.
  local interrupted = stop_reason == "cancelled" or stop_reason == "error"
  for _, block in ipairs(self.blocks) do
    local previous = block.status
    if block.kind == "thought" and block.status == "streaming" then
      block.status = nil
      block._append_base = nil
      if (self.thoughts or {}).collapse_on_finish ~= false then
        block.expanded = false
      end
    elseif block.status == "streaming" then
      block.status = nil
      block._append_base = nil
    end
    if block.kind == "tool" and (block.status == "pending" or block.status == "in_progress") then
      if interrupted then
        block.status = stop_reason == "cancelled" and "cancelled" or "failed"
      end
    end
    if previous ~= block.status then
      self:touch(block, false)
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
