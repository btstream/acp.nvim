-- Agent profiles: the per-agent knowledge the core must not hard-code.
--
-- Every hook is optional and has a safe default in `generic`. An agent with no
-- profile behaves exactly like a generic ACP agent: nothing is inferred, no
-- name is matched and no `_meta` extension is read.
local M, Profile = {}, {}
Profile.__index = Profile

---@class AcpAgentProfile
---@field name string
---@field install_hint string|nil
---@field classify_mode fun(control: table): "work"|"thinking"|nil
---@field plan_mode fun(value_id: string|nil): boolean
---@field unsafe_edit_mode fun(value_id: string|nil): boolean
---@field tool_name fun(tool_call: table): string|nil
---@field update_meta fun(update: table, session: table): table|nil
---@field is_question fun(request: table): boolean|nil
---@field error_hint fun(err: table): string|nil

---@param spec AcpAgentProfile
---@return table
local function profile(spec)
  local self = setmetatable({}, Profile)
  for key, value in pairs(spec) do
    self[key] = value
  end
  -- Defaults keep every call site free of nil checks.
  self.classify_mode = self.classify_mode or function()
    return nil
  end
  self.plan_mode = self.plan_mode or function()
    return false
  end
  self.unsafe_edit_mode = self.unsafe_edit_mode or function()
    return false
  end
  self.tool_name = self.tool_name or function()
    return nil
  end
  self.update_meta = self.update_meta or function()
    return nil
  end
  return self
end

---Whether a value id is one of the ids, case-insensitively.
---@param value string|nil
---@param candidates string[]
---@return boolean
local function matches(value, candidates)
  if type(value) ~= "string" then
    return false
  end
  local lower = value:lower()
  for _, candidate in ipairs(candidates) do
    if lower == candidate then
      return true
    end
  end
  return false
end

---Modes that switch the agent into planning.
---@param value_id string|nil
---@return boolean
local function plan_mode(value_id)
  return matches(value_id, { "plan", "architect" })
end

---Modes where edits are applied without asking.
---@param value_id string|nil
---@return boolean
local function unsafe_edit_mode(value_id)
  return matches(value_id, {
    "acceptedits",
    "accept_edits",
    "auto",
    "autoreview",
    "auto_review",
    "bypasspermissions",
    "bypass_permissions",
    "full_access",
    "yolo",
  })
end

local registry = {}

---@param name string
---@param spec AcpAgentProfile
local function register(name, spec)
  spec.name = spec.name or name
  registry[name] = profile(spec)
end

register("generic", {
  install_hint = "Install the agent you configured, then run :Acp login if it needs credentials.",
  plan_mode = plan_mode,
  unsafe_edit_mode = unsafe_edit_mode,
})

register("opencode", {
  install_hint = "Install OpenCode (https://opencode.ai/docs/).",
  plan_mode = plan_mode,
  unsafe_edit_mode = unsafe_edit_mode,
  -- OpenCode marks its mode with `_meta.kind` on the option; there is no
  -- separate profile decision beyond that.
  classify_mode = function(control)
    local meta = type(control) == "table" and control._meta or nil
    local kind = type(meta) == "table" and meta.kind or nil
    if kind == "plan" or kind == "full_access" or kind == "auto_review" then
      return "work"
    end
    return nil
  end,
  update_meta = function(update, session)
    local meta = type(update) == "table" and update._meta or nil
    if type(meta) ~= "table" then
      return nil
    end
    local seen = {}
    if meta["opencode/retry"] ~= nil then
      seen.retry = meta["opencode/retry"]
    end
    if meta["opencode/compaction"] then
      seen.compaction = meta["opencode/compaction"]
    end
    if meta["opencode/child-session"] then
      seen.child = meta["opencode/child-session"]
    end
    if next(seen) == nil then
      return nil
    end
    return seen
  end,
})

register("claude", {
  install_hint = "Install claude-agent-acp (`npm i -g @agentclientprotocol/claude-agent-acp`).",
  plan_mode = plan_mode,
  unsafe_edit_mode = unsafe_edit_mode,
  -- The tool name also lives in `_meta.claudeCode.toolName`; `toolCall.name` is
  -- preferred, but agents have shipped both forms.
  tool_name = function(tool_call)
    if type(tool_call) ~= "table" then
      return nil
    end
    local meta = tool_call._meta
    local claude = type(meta) == "table" and meta.claudeCode or nil
    if type(claude) == "table" and type(claude.toolName) == "string" and claude.toolName ~= "" then
      return claude.toolName
    end
    return nil
  end,
  -- ExitPlanMode is a question, not a tool approval.
  is_question = function(request)
    local tool = type(request) == "table" and request.toolCall or nil
    return type(tool) == "table" and tool.kind == "switch_mode"
  end,
  update_meta = function(update)
    local meta = update._meta
    local claude = type(meta) == "table" and meta.claudeCode or nil
    if type(claude) == "table" and claude.toolName then
      return "tool_name"
    end
    return nil
  end,
})

register("pi", {
  install_hint = "Install pi-acp (`npm i -g pi-acp`, or keep the npx command).",
  plan_mode = plan_mode,
  unsafe_edit_mode = unsafe_edit_mode,
  -- pi exposes thinking levels as `modes`; the same list is duplicated as a
  -- thought_level config option. A mode that is a thinking level is not a
  -- work mode.
  classify_mode = function()
    return "thinking"
  end,
  -- pi wraps a select/confirm UI request in a permission request.
  is_question = function(request)
    local tool = type(request) == "table" and request.toolCall or nil
    local input = type(tool) == "table" and tool.rawInput or nil
    local method = type(input) == "table" and input.method or nil
    return method == "select" or method == "confirm"
  end,
})

---Resolve the profile for an agent.
---
---An explicit `profile` wins. Otherwise the agent name is matched against the
---built-ins, and an unknown agent gets `generic`.
---@param agent table|nil
---@param name string|nil
---@return table
function M.get(agent, name)
  local requested = type(agent) == "table" and agent.profile or nil
  if type(requested) == "string" and registry[requested] then
    return registry[requested]
  end
  local candidate = name or (type(agent) == "table" and agent.name) or nil
  if type(candidate) == "string" and registry[candidate] then
    return registry[candidate]
  end
  return registry.generic
end

---Whether a profile name is built in.
---@param name string
---@return boolean
function M.exists(name)
  return registry[name] ~= nil
end

---All registered profile names, sorted.
---@return string[]
function M.names()
  local names = vim.tbl_keys(registry)
  table.sort(names)
  return names
end

-- Exposed for unit tests.
M._registry = registry
M._plan_mode = plan_mode
M._unsafe_edit_mode = unsafe_edit_mode

return M
