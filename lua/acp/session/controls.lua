-- Normalised session controls: one shape for modes, models, thinking levels
-- and any extra config option, whichever way the agent reported them.
--
-- The rules, in order:
--   1. When `configOptions` exist they are authoritative and `modes` is
--      ignored. pi duplicates its thinking levels as both, and mixing them
--      produced two choosers for one setting.
--   2. With only `modes`, a work mode is built and changing it uses
--      `session/set_mode`. A mode the profile classifies as a thinking level
--      becomes `thinking` instead.
--   3. Values come from the config option's category: model, mode,
--      thought_level, everything else in `extras`.
local M = {}

---Flatten grouped select options.
---@param option table
---@return table[]
local function values_of(option)
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
---@param profile table
---@return table
local function from_config(option, profile)
  local control = {
    id = option.id,
    name = option.name or option.id,
    description = option.description,
    kind = option.type == "boolean" and "boolean" or "select",
    current = option.currentValue,
    source = "config",
    option = option,
  }
  if control.kind == "select" then
    control.options = values_of(option)
  end
  control.plan = false
  control.unsafe = false
  if option.category == "mode" then
    -- Claude reports the semantic kind on each option; prefer it over the
    -- profile hook, which can only guess from the id.
    local current = nil
    for _, entry in ipairs(control.options or {}) do
      if entry.value == option.currentValue then
        current = entry
        break
      end
    end
    local kind = type(current) == "table" and type(current._meta) == "table" and current._meta.kind or nil
    if kind == "plan" then
      control.plan = true
    elseif kind == "full_access" or kind == "auto_review" then
      control.unsafe = true
    else
      control.plan = profile.plan_mode(option.currentValue)
      control.unsafe = profile.unsafe_edit_mode(option.currentValue)
    end
    -- Option-level metadata can also carry the kind for every entry.
    for _, entry in ipairs(control.options or {}) do
      if entry.value == option.currentValue and type(entry._meta) == "table" then
        if entry._meta.kind == "plan" then
          control.plan = true
        elseif entry._meta.kind == "full_access" or entry._meta.kind == "auto_review" then
          control.unsafe = true
        end
      end
    end
  end
  return control
end

---Normalise a legacy mode entry to the config-option option shape.
---@param entry table
---@return table
local function mode_option(entry)
  return {
    value = entry.id,
    name = entry.name or entry.id,
    description = entry.description,
    _meta = entry._meta,
  }
end

---@param mode table
---@param profile table
---@return table|nil work, table|nil thinking
local function from_modes(modes, profile)
  local current = modes.currentModeId
  local available = modes.availableModes or {}
  local thinking_values, work_values = {}, {}
  for _, entry in ipairs(available) do
    local kind = profile.classify_mode(entry)
    if kind == "thinking" then
      thinking_values[#thinking_values + 1] = mode_option(entry)
    else
      work_values[#work_values + 1] = mode_option(entry)
    end
  end
  local work, thinking
  if #work_values > 0 then
    work = {
      id = "mode",
      name = "Mode",
      kind = "select",
      current = current,
      options = work_values,
      source = "modes",
      plan = profile.plan_mode(current),
      unsafe = profile.unsafe_edit_mode(current),
    }
    -- If the current mode is a thinking level it does not belong to this list.
    local in_work = false
    for _, entry in ipairs(work_values) do
      if entry.value == current then
        in_work = true
        break
      end
    end
    if not in_work then
      work = nil
    end
  end
  if #thinking_values > 0 then
    thinking = {
      id = "thinking",
      name = "Thinking",
      kind = "select",
      current = current,
      options = thinking_values,
      source = "modes",
      plan = false,
      unsafe = false,
    }
    local in_thinking = false
    for _, entry in ipairs(thinking_values) do
      if entry.value == current then
        in_thinking = true
        break
      end
    end
    if not in_thinking then
      thinking = nil
    end
  end
  return work, thinking
end

---Build the normalised controls for a session.
---@param session table
---@param profile table
---@return table
function M.build(session, profile)
  local controls = { mode = nil, model = nil, thinking = nil, extras = {} }
  local options = session.config_options or nil
  if type(options) == "table" and #options > 0 then
    for _, option in ipairs(options) do
      local control = from_config(option, profile)
      if option.category == "model" then
        controls.model = control
      elseif option.category == "mode" then
        controls.mode = control
      elseif option.category == "thought_level" then
        controls.thinking = control
      else
        controls.extras[#controls.extras + 1] = control
      end
    end
    return controls
  end

  local modes = session.modes
  if type(modes) == "table" and type(modes.availableModes) == "table" then
    -- `current_mode` is the live value: `set_mode` updates it without a new
    -- `modes` payload, so reading `modes.currentModeId` alone would keep the
    -- previous mode selected.
    local work, thinking = from_modes({
      currentModeId = session.current_mode or modes.currentModeId,
      availableModes = modes.availableModes,
    }, profile)
    controls.mode, controls.thinking = work, thinking
  end
  return controls
end

---Whether any control exists.
---@param controls table
---@return boolean
function M.any(controls)
  return controls.mode ~= nil or controls.model ~= nil or controls.thinking ~= nil or #(controls.extras or {}) > 0
end

---Find a control by id, including extras.
---@param controls table
---@param id string
---@return table|nil
function M.by_id(controls, id)
  for _, key in ipairs({ "mode", "model", "thinking" }) do
    local control = controls[key]
    if control and control.id == id then
      return control, key
    end
  end
  for _, control in ipairs(controls.extras or {}) do
    if control.id == id then
      return control, "extras"
    end
  end
  return nil
end

---Human label for a control's current value.
---@param control table
---@return string|nil
function M.label(control)
  if not control then
    return nil
  end
  if control.kind == "boolean" then
    return control.current and "on" or "off"
  end
  for _, entry in ipairs(control.options or {}) do
    if entry.value == control.current then
      return entry.name or tostring(entry.value)
    end
  end
  if type(control.current) == "string" then
    return control.current
  end
  return nil
end

return M
