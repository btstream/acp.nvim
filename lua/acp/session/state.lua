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
  return block
end

function Session:append_text(kind, text, message_id)
  local last = self.blocks[#self.blocks]
  if last and last.kind == kind and last.status == "streaming" then
    if not message_id or last.message_id == nil or last.message_id == message_id then
      last.message_id = last.message_id or message_id
      last.text = last.text .. text
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
function Session:finish_turn(stop_reason)
  for _, block in ipairs(self.blocks) do
    if block.status == "streaming" then
      block.status = nil
    end
    if block.kind == "tool" and (block.status == "pending" or block.status == "in_progress") then
      if stop_reason == "cancelled" then
        block.status = "cancelled"
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

---Flatten select option values.
---@param option table
---@return {value: string|boolean, name: string, description: string|nil}[]
function M.select_values(option)
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
  return out
end

---@param option table
---@param value string|boolean
---@return string|nil
function M.option_label(option, value)
  for _, entry in ipairs(M.select_values(option)) do
    if entry.value == value then
      return entry.name
    end
  end
  if type(value) == "string" then
    return value
  end
  return nil
end

return M
