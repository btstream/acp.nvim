-- Permission presentation and the `auto_allow` policy.
--
-- Pending state lives in `app/interactions`; this module only turns one
-- interaction into a picker and decides which requests may be pre-approved.
local log = require("acp.log")
local picker = require("acp.ui.picker")
local details = require("acp.ui.permission_details")

local Permissions = {}
Permissions.__index = Permissions

---@param opts {config: fun(): table, valid: fun(interaction: table): boolean,
---  answer: fun(interaction: table, option_id: string|nil),
---  dismiss: fun(interaction: table), notify: fun(message: string, level: integer|nil),
---  session: fun(): table|nil}
function Permissions.new(opts)
  return setmetatable({
    config = opts.config,
    valid = opts.valid,
    answer = opts.answer,
    dismiss = opts.dismiss,
    notify = opts.notify,
    current_session = opts.session,
    shown = nil,
  }, Permissions)
end

---A request that asks a question rather than for tool approval.
---
---The profile knows its agent's own wrapping (pi's select/confirm, Claude's
---ExitPlanMode). When it does not claim the request, the generic heuristics
---apply: a single option carries no choice, and options of differing kinds are
---an approval rather than a question.
---@param interaction table
---@return boolean
function Permissions:is_question(interaction)
  local request = interaction.request or {}
  local tool = request.toolCall or request.tool_call or {}
  local session = self.current_session and self.current_session() or nil
  local profile = session and session.profile or nil
  if profile and profile.is_question and profile.is_question(request) then
    return true
  end
  if tool.kind == "switch_mode" then
    return true
  end
  local method = type(tool.rawInput) == "table" and tool.rawInput.method or nil
  if method == "select" or method == "confirm" then
    return true
  end
  local options = request.options or {}
  -- A single option carries no choice: it is an ordinary approval, and
  -- `auto_allow` must still be able to pre-approve it.
  if #options < 2 then
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

  local question = self:is_question(interaction)
  local labels = {
    execute = "Run command",
    edit = "Edit file",
    delete = "Delete file",
    move = "Move file",
    read = "Read file",
    search = "Search",
    fetch = "Fetch",
  }
  -- Claude puts the human question in `_meta.permission.title` and the tool
  -- name (`ExitPlanMode`) in `toolCall.title`; the question is what to show.
  local meta_title = type(request._meta) == "table"
      and type(request._meta.permission) == "table"
      and request._meta.permission.title
    or type(tool._meta) == "table" and type(tool._meta.permission) == "table" and tool._meta.permission.title
  local title
  if question then
    title = meta_title or tool.title or "Question"
  else
    title = labels[tool.kind] or meta_title or tool.title or tool.kind or "Permission required"
    local input = tool.rawInput or {}
    if tool.kind == "execute" and (input.command or input.cmd) then
      title = title .. ": " .. tostring(input.command or input.cmd)
    end
  end
  local items = {}
  for _, option in ipairs(options) do
    items[#items + 1] = {
      label = option.name or option.optionId,
      description = question and option.description or option.kind,
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

  if (self.config().permissions or {}).show_details ~= false then
    details.open(request, {
      title = title,
      cwd = tool.locations and tool.locations[1] and tool.locations[1].path or nil,
    })
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
  details.close()
end

return Permissions
