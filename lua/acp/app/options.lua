-- Session control pickers: mode, model, thinking level and extra options.
--
-- Every choice is driven by `session.controls` (session/controls.lua), so the
-- picker never has to guess which agent reported what. Changing a control uses
-- the method that produced it: `session/set_mode` for legacy `modes`, and
-- `session/set_config_option` for config options.
local presenter = require("acp.app.presenter")
local controls_mod = require("acp.session.controls")

local Options = {}
Options.__index = Options

---@param opts {config: fun(): table, current: fun(): AcpSessionState|nil,
---  client: fun(): table|nil, generation: fun(): integer,
---  ui_current: fun(client: table|nil, generation: integer, session: AcpSessionState|nil): boolean,
---  run: fun(key: string, client: table|nil, session: AcpSessionState|nil, fn: fun(task: table)),
---  on_changed: fun(), notify: fun(message: string, level: integer|nil)}
function Options.new(opts)
  return setmetatable({
    config = opts.config,
    current = opts.current,
    get_client = opts.client,
    generation = opts.generation,
    ui_current = opts.ui_current,
    run = opts.run,
    on_changed = opts.on_changed,
    notify = opts.notify,
  }, Options)
end

---Whether a captured session is still the right target for a write.
---@param client table|nil
---@param generation integer
---@param session table
---@return boolean
function Options:still_current(client, generation, session)
  return self.ui_current(client, generation, session) and self.current() == session
end

---Apply one control value.
---@param control table
---@param value any
---@param client table|nil
---@param generation integer
---@param session table
function Options:apply(control, value, client, generation, session)
  if not self:still_current(client, generation, session) then
    return
  end
  self.run("control:" .. session.id .. ":" .. control.id, client, session, function(task)
    local ok, result
    if control.source == "modes" then
      ok, result = task:call("set_mode", session.id, value)
    else
      ok, result = task:call("set_config_option", session.id, control.id, value)
    end
    if not ok then
      task.status = "failed"
      local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      self.notify("unable to change " .. (control.name or control.id) .. ": " .. message, vim.log.levels.ERROR)
      return
    end
    if control.source == "modes" then
      session.current_mode = value
      session:refresh_controls()
    elseif result and type(result) == "table" and result.configOptions then
      session:configure(result)
    else
      -- The agent acknowledged without a new option list. Record the value on
      -- the option itself: controls are derived from it on every refresh, so
      -- writing only `control.current` would be overwritten immediately.
      control.current = value
      if control.option then
        control.option.currentValue = value
      end
      session:refresh_controls()
    end
    session._toolbar_labels = nil
    self.on_changed()
  end, function(err)
    self.notify("unable to change " .. (control.name or control.id) .. ": " .. tostring(err), vim.log.levels.ERROR)
  end)
end

---Toggle a boolean control.
---@param control table
---@param client table|nil
---@param generation integer
---@param session table
function Options:toggle(control, client, generation, session)
  local next_value = not control.current
  if control.source == "modes" then
    -- A boolean never comes from `modes`; guard anyway.
    return
  end
  self:apply(control, next_value, client, generation, session)
end

---Picker title for a control: avoid repeating the same name twice.
---@param control table
---@param title string|nil
---@return string
local function picker_title(control, title)
  local name = control.name or control.id
  if not title or title == "" or title == name then
    return name
  end
  return title .. " · " .. name
end

---Picker for a select control.
---@param control table
---@param title string|nil
---@param client table|nil
---@param generation integer
---@param session table
function Options:pick_control(control, title, client, generation, session)
  local ic = presenter.icons(self.config().ui.icons)
  local items = {}
  for _, entry in ipairs(control.options or {}) do
    local marked = entry.value == control.current and (ic.check_circle .. " ") or (ic.tool_pending .. " ")
    items[#items + 1] = {
      label = marked .. (entry.name or tostring(entry.value)),
      description = entry.description,
      value = entry.value,
    }
  end
  if #items == 0 then
    self.notify("this option has no values", vim.log.levels.INFO)
    return
  end
  presenter.select({
    title = picker_title(control, title),
    items = items,
    on_choice = function(value)
      self:apply(control, value, client, generation, session)
    end,
  })
end

---Select by control key ("mode" | "model" | "thinking") or control id.
---@param key string
---@param title string
function Options:pick(key, title)
  local session = self.current()
  if not session then
    return
  end
  if not session.controls then
    session:refresh_controls()
  end
  local client, generation = self.get_client(), self.generation()
  local control = session.controls[key]
  if not control then
    control = controls_mod.by_id(session.controls, key)
  end
  if not control then
    self.notify("this agent does not offer " .. key .. " selection", vim.log.levels.INFO)
    return
  end
  if control.kind == "boolean" then
    self:toggle(control, client, generation, session)
    return
  end
  self:pick_control(control, title, client, generation, session)
end

function Options:pick_model()
  self:pick("model", "Model")
end

function Options:pick_mode()
  self:pick("mode", "Mode")
end

function Options:pick_thinking()
  self:pick("thinking", "Thinking")
end

---One picker for every control the agent offers.
function Options:pick_config()
  local session = self.current()
  if not session then
    return
  end
  if not session.controls then
    session:refresh_controls()
  end
  local client, generation = self.get_client(), self.generation()
  local items = {}
  for _, key in ipairs({ "mode", "model", "thinking" }) do
    local control = session.controls[key]
    if control then
      items[#items + 1] = {
        label = string.format("%s: %s", control.name or control.id, controls_mod.label(control) or "?"),
        description = control.description,
        value = { control = control, title = control.name },
      }
    end
  end
  for _, control in ipairs(session.controls.extras or {}) do
    items[#items + 1] = {
      label = string.format("%s: %s", control.name or control.id, controls_mod.label(control) or "?"),
      description = control.description,
      value = { control = control, title = control.name },
    }
  end
  if #items == 0 then
    self.notify("this agent offers no session options", vim.log.levels.INFO)
    return
  end
  presenter.select({
    title = "Configure",
    items = items,
    on_choice = function(choice)
      if not self:still_current(client, generation, session) then
        return
      end
      if choice.control.kind == "boolean" then
        self:toggle(choice.control, client, generation, session)
      else
        self:pick_control(choice.control, choice.title, client, generation, session)
      end
    end,
  })
end

return Options
