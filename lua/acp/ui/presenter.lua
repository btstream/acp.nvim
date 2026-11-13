-- Presentation data derived from session state.
--
-- Nothing here sends RPC, touches windows or mutates session semantics; these
-- helpers exist so the controller and the winbar can ask for display labels
-- without reaching into the update reducer.

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
---scrolls, resizes). The labels only change when the derived controls change,
---so the result is memoised per control object.
---@param session AcpSessionState
---@return string|nil model_label
---@return string|nil mode_label
---@return string|nil thinking_label
function M.toolbar_labels(session)
  local cached = session._toolbar_labels
  local controls = session.controls
  if cached and cached.controls == controls then
    return cached.model_label, cached.mode_label, cached.thinking_label
  end
  local controls_mod = require("acp.session.controls")
  local model_label = M.short_model_name(controls_mod.label(controls and controls.model))
  local mode_label = controls_mod.label(controls and controls.mode)
  local thinking_label = controls_mod.label(controls and controls.thinking)
  session._toolbar_labels = {
    controls = controls,
    model_label = model_label,
    mode_label = mode_label,
    thinking_label = thinking_label,
  }
  return model_label, mode_label, thinking_label
end

return M
