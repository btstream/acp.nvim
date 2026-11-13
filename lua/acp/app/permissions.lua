-- Permission presentation and the `auto_allow` policy.
--
-- Pending state lives in `app/interactions`; this module only turns one
-- interaction into a picker and decides which requests may be pre-approved.
local log = require("acp.log")
local picker = require("acp.ui.picker")

local Permissions = {}
Permissions.__index = Permissions

---@param opts {config: fun(): table, valid: fun(interaction: table): boolean,
---  answer: fun(interaction: table, option_id: string|nil),
---  dismiss: fun(interaction: table), notify: fun(message: string, level: integer|nil)}
function Permissions.new(opts)
  return setmetatable({
    config = opts.config,
    valid = opts.valid,
    answer = opts.answer,
    dismiss = opts.dismiss,
    notify = opts.notify,
    shown = nil,
  }, Permissions)
end

---A request that asks a question rather than for tool approval.
---
---pi wraps questions in a permission request whose options all share one kind,
---and Claude's plan approval is a switch_mode call. Neither may be auto-answered.
---@param interaction table
---@return boolean
function Permissions:is_question(interaction)
  local request = interaction.request or {}
  local tool = request.toolCall or request.tool_call or {}
  if tool.kind == "switch_mode" then
    return true
  end
  local options = request.options or {}
  if #options == 0 then
    return false
  end
  local kind = options[1].kind
  for _, option in ipairs(options) do
    if option.kind ~= kind then
      return false
    end
  end
  return true
end

---Policy: pre-approve tool permissions listed in `permissions.auto_allow`.
---@param interaction table
---@return table|nil
function Permissions:auto(interaction)
  if interaction.type ~= "permission" or self:is_question(interaction) then
    return nil
  end
  local auto = (self.config().permissions or {}).auto_allow or {}
  if #auto == 0 then
    return nil
  end
  for _, option in ipairs(interaction.request.options or {}) do
    for _, allowed in ipairs(auto) do
      if option.kind == allowed then
        log.info("auto-approving permission via %s", allowed)
        return { outcome = { outcome = "selected", optionId = option.optionId } }
      end
    end
  end
  return nil
end

---Presenter: open the picker for one interaction.
---@param interaction table
---@return boolean shown
function Permissions:present(interaction)
  local request = interaction.request or {}
  local tool = request.toolCall or request.tool_call or {}
  local options = request.options or {}
  if (self.config().permissions or {}).prompt ~= "select" then
    self.notify("Permission required: " .. (tool.title or ""), vim.log.levels.WARN)
    return false
  end

  local title = tool.title or tool.kind or "tool"
  local items = {}
  for _, option in ipairs(options) do
    items[#items + 1] = {
      label = option.name or option.optionId,
      description = option.kind,
      value = { id = option.optionId, kind = option.kind },
    }
  end

  if #items == 0 then
    self.notify("the agent sent a permission request without options", vim.log.levels.WARN)
    if self.valid(interaction) then
      self.answer(interaction, nil)
    end
    return true
  end

  if tool.locations and #tool.locations > 0 then
    local locs = {}
    for _, loc in ipairs(tool.locations) do
      locs[#locs + 1] = loc.path and vim.fn.fnamemodify(loc.path, ":t") or "?"
    end
    title = title .. "  " .. table.concat(locs, ", ")
  end

  local handle = picker.select({
    title = "Permission required: " .. title,
    items = items,
    width = math.min(90, math.max(50, vim.o.columns - 20)),
    on_choice = function(value)
      if self.valid(interaction) then
        self.answer(interaction, value and value.id or nil)
      end
    end,
    -- Dismissing the dialog must never leave the turn blocked forever.
    on_cancel = function()
      if self.valid(interaction) then
        self.dismiss(interaction)
      end
    end,
  })
  self.shown = handle
  return true
end

---Close the picker for a dismissed/cancelled interaction.
function Permissions:dismiss_presented()
  local handle = self.shown
  self.shown = nil
  if handle and handle.close then
    pcall(handle.close)
  end
end

return Permissions
