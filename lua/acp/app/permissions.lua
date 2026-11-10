-- Permission request policy and interaction.
--
-- The client owns the RPC respond callbacks; this module owns what the user
-- sees and which option is sent back. The pending table is shared with the
-- controller so the diagnostic state view keeps working during the migration.
local log = require("acp.log")
local picker = require("acp.ui.picker")

local Permissions = {}
Permissions.__index = Permissions

---@param opts {pending: fun(): table, config: fun(): table, client: fun(): table|nil,
---  on_changed: fun(), valid: fun(entry: table|nil, key: string): boolean,
---  notify: fun(message: string, level: integer|nil)}
function Permissions.new(opts)
  return setmetatable({
    get_pending = opts.pending,
    config = opts.config,
    get_client = opts.client,
    on_changed = opts.on_changed or function() end,
    valid = opts.valid,
    notify = opts.notify,
  }, Permissions)
end

---The controller-owned pending table. It is read through a getter so the
---diagnostic state view and the request bookkeeping never diverge.
---@return table<string, table>
function Permissions:pending()
  return self.get_pending()
end

---Whether `session` has a permission request awaiting an answer.
---@param session AcpSessionState|nil
---@return boolean
function Permissions:waiting(session)
  if not session then
    return false
  end
  for _, entry in pairs(self:pending()) do
    if entry.session_id == session.id then
      return true
    end
  end
  return false
end

---Register a request coming from the client.
---@param payload table
---@return table|nil entry, string|nil option_id
---Returns the stored entry and an option id when the user pre-approved it.
function Permissions:request(payload)
  local entry = {
    session_id = payload.session_id,
    tool_call = payload.tool_call,
    options = payload.options,
  }
  self:pending()[payload.key] = entry
  self.on_changed()

  -- Optional auto-approval, explicitly opted in by the user.
  local auto = (self.config().permissions or {}).auto_allow or {}
  if #auto > 0 then
    for _, option in ipairs(payload.options or {}) do
      for _, allowed in ipairs(auto) do
        if option.kind == allowed then
          log.info("auto-approving permission via %s", allowed)
          return entry, option.optionId
        end
      end
    end
  end

  if (self.config().permissions or {}).prompt ~= "select" then
    self.notify(
      "Permission required" .. ": " .. (payload.tool_call and payload.tool_call.title or ""),
      vim.log.levels.WARN
    )
  end
  return entry, nil
end

---Whether the prompt should be shown for this entry.
---@return boolean
function Permissions:should_prompt()
  return (self.config().permissions or {}).prompt == "select"
end

---Resolve a pending request, optionally treating dismissal as a rejection.
---@param key string
---@param option_id string|nil
---@param dismissed boolean|nil
function Permissions:resolve(key, option_id, dismissed)
  local entry = self:pending()[key]
  if not entry then
    return
  end
  if dismissed and not option_id then
    -- Pick the first reject option so the agent gets an explicit denial.
    for _, option in ipairs(entry.options or {}) do
      if option.kind and option.kind:match("^reject") then
        option_id = option.optionId
        break
      end
    end
  end
  self:pending()[key] = nil
  local client = self.get_client()
  if client then
    client:resolve_permission(key, option_id)
  end
  self.on_changed()
end

---Drop a request the client reports as already answered.
---@param key string
function Permissions:resolved(key)
  self:pending()[key] = nil
  self.on_changed()
end

---Open the picker for a pending request.
---@param payload table
function Permissions:show(payload)
  local key = payload.key
  -- Capture the shown entry: if the connection is torn down and a new request
  -- reuses the same key, the stale dialog must not answer the new one.
  local shown = self:pending()[key]
  local function valid()
    return shown ~= nil and self.valid(shown, key)
  end

  local tool = payload.tool_call or {}
  local title = tool.title or tool.kind or "tool"
  local items = {}
  for _, option in ipairs(payload.options or {}) do
    items[#items + 1] = {
      label = option.name or option.optionId,
      description = option.kind,
      value = { id = option.optionId, kind = option.kind },
    }
  end

  if #items == 0 then
    self.notify("the agent sent a permission request without options", vim.log.levels.WARN)
    if valid() then
      self:resolve(key, nil, true)
    end
    return
  end

  if tool.locations and #tool.locations > 0 then
    local locs = {}
    for _, loc in ipairs(tool.locations) do
      locs[#locs + 1] = loc.path and vim.fn.fnamemodify(loc.path, ":t") or "?"
    end
    title = title .. "  " .. table.concat(locs, ", ")
  end

  picker.select({
    title = "Permission required" .. ": " .. title,
    items = items,
    width = math.min(90, math.max(50, vim.o.columns - 20)),
    on_choice = function(value)
      if valid() then
        self:resolve(key, value and value.id or nil)
      end
    end,
    -- Dismissing the dialog must never leave the turn blocked forever.
    on_cancel = function()
      if valid() then
        self:resolve(key, nil, true)
      end
    end,
  })
end

---Reopen the oldest pending permission request.
function Permissions:show_pending()
  local keys = vim.tbl_keys(self:pending())
  table.sort(keys)
  local key = keys[1]
  if not key then
    self.notify("no pending permission requests", vim.log.levels.INFO)
    return
  end
  local entry = self:pending()[key]
  self:show({
    key = key,
    tool_call = entry.tool_call,
    options = entry.options,
  })
end

---Drop every pending request without answering it (connection teardown).
function Permissions:reset()
  for key in pairs(self:pending()) do
    self:pending()[key] = nil
  end
end

return Permissions
