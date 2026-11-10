-- Session config option pickers: model, mode and other agent options.
--
-- Asynchronous writes still go through the controller's task scope, so the
-- identity fences and cancellation semantics stay in one place.
local Icons = require("acp.ui.icons")
local picker = require("acp.ui.picker")
local state = require("acp.session.state")

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

---@param category string
---@param title string
function Options:pick(category, title)
  local session = self.current()
  if not session then
    return
  end
  local option = session:option_by_category(category)
  local client, generation = self.get_client(), self.generation()
  if not option then
    self.notify("this agent does not offer a " .. category .. " option", vim.log.levels.INFO)
    return
  end
  local items = {}
  local ic = Icons.get(self.config().ui.icons)
  for _, entry in ipairs(state.select_values(option)) do
    local marked = entry.value == option.currentValue and (ic.check_circle .. " ") or (ic.tool_pending .. " ")
    items[#items + 1] = {
      label = marked .. (entry.name or tostring(entry.value)),
      description = entry.description,
      value = entry.value,
    }
  end
  picker.select({
    title = title .. " · " .. option.name,
    items = items,
    on_choice = function(value)
      -- The agent may have gone away (crash, explicit disconnect) while the
      -- picker was open.
      if not self.ui_current(client, generation, session) then
        return
      end
      -- The session may also have been switched; do not apply the choice to a
      -- stale object.
      if self.current() ~= session then
        return
      end
      self.run("option:" .. session.id .. ":" .. option.id, client, session, function(task)
        local ok, result = task:call("set_config_option", session.id, option.id, value)
        if not ok then
          task.status = "failed"
          local message = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
          self.notify("unable to change option: " .. message, vim.log.levels.ERROR)
          return
        end
        session:set_option(option, value, result)
        self.on_changed()
      end, function(err)
        self.notify("unable to change option: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end,
  })
end

function Options:pick_model()
  self:pick("model", "Model")
end

function Options:pick_mode()
  self:pick("mode", "Mode")
end

function Options:pick_config()
  local session = self.current()
  if not session then
    return
  end
  local client, generation = self.get_client(), self.generation()
  local items = {}
  for _, option in ipairs(session.config_options or {}) do
    if option.category ~= "model" and option.category ~= "mode" then
      local label = state.option_label(option, option.currentValue) or tostring(option.currentValue)
      items[#items + 1] = {
        label = string.format("%s: %s", option.name, label),
        description = option.description,
        value = option.id,
      }
    end
  end
  if #items == 0 then
    self.notify("no additional session options", vim.log.levels.INFO)
    return
  end
  picker.select({
    title = "Configure",
    items = items,
    on_choice = function(id)
      if not self.ui_current(client, generation, session) then
        return
      end
      local option = nil
      for _, opt in ipairs(session.config_options) do
        if opt.id == id then
          option = opt
        end
      end
      if option then
        self:pick(option.category or "", option.name)
      end
    end,
  })
end

return Options
