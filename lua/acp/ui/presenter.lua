-- Presentation data derived from session state.
--
-- Nothing here sends RPC, touches windows or mutates session semantics; these
-- helpers exist so the controller and the winbar can ask for display labels
-- without reaching into the update reducer.
local state = require("acp.session.state")

local M = {}

---Strip the provider prefix from a model name.
---
---Agents prefix model names with their provider ("commandcode/DeepSeek V4.1
---Flash", "anthropic/claude-sonnet-5-5"). The toolbar has little room and the
---provider adds little once a model is selected, so only the model part is
---shown. Picker entries keep the full name so two providers offering the same
---model stay distinguishable.
---@param name string|nil
---@return string|nil
function M.short_model_name(name)
  if type(name) ~= "string" or name == "" then
    return name
  end
  -- Only the display name matters. If it has no provider prefix there is
  -- nothing to strip, even when the value happens to carry one: the name is
  -- what the user already sees elsewhere.
  local _, rest = name:match("^([^/]+)/(.+)$")
  if rest and rest ~= "" then
    return rest
  end
  return name
end

---Extract the model and mode labels used by the composer toolbar.
---
---Called from the winbar, which Vim evaluates on every redraw (cursor moves,
---scrolls, resizes). The labels only change when the session's config options
---or current values change, so the result is memoised per option table.
---@param session AcpSessionState
---@return string|nil model_label
---@return string|nil mode_label
function M.toolbar_labels(session)
  local cached = session._toolbar_labels
  local opts = session.config_options
  local model = session:option_by_category("model")
  local mode = session:option_by_category("mode")
  local model_value = model and model.currentValue or nil
  local mode_value = mode and mode.currentValue or nil
  if
    cached
    and cached.options == opts
    and cached.model == model
    and cached.mode == mode
    and cached.model_value == model_value
    and cached.mode_value == mode_value
  then
    return cached.model_label, cached.mode_label
  end

  local model_label = model and state.option_label(model, model.currentValue) or nil
  model_label = M.short_model_name(model_label)
  local mode_label = mode and state.option_label(mode, mode.currentValue) or nil
  session._toolbar_labels = {
    options = opts,
    model = model,
    mode = mode,
    model_value = model_value,
    mode_value = mode_value,
    model_label = model_label,
    mode_label = mode_label,
  }
  return model_label, mode_label
end

return M
