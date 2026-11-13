-- Presentation boundary for the `app/*` services.
--
-- Application services decide *what* to show and *when*; this module owns the
-- `ui/*` modules that draw it. Keeping the imports here means `app/*` no longer
-- depends on a specific picker, form or diff renderer, and a test can replace a
-- backend in one place.
--
-- Everything is resolved lazily, at call time: tests and integrations swap
-- `acp.ui.picker.select`, `acp.ui.form.open` and friends on the module tables,
-- and a cached local binding here would silently ignore those swaps.
local M = {}

---Select one item through the configured picker backend.
---@param opts table picker options (`title`, `items`, `on_choice`, ...)
function M.select(opts)
  return require("acp.ui.picker").select(opts)
end

---Own the floating permission-details window.
M.details = {
  open = function(request, opts)
    return require("acp.ui.permission_details").open(request, opts)
  end,
  close = function()
    return require("acp.ui.permission_details").close()
  end,
}

---Own the elicitation form window.
M.form = {
  open = function(request, opts)
    return require("acp.ui.form").open(request, opts)
  end,
  dismiss = function()
    return require("acp.ui.form").dismiss()
  end,
}

---Session browser backends.
---
---`backend` is the configured `ui.session_picker`: "snacks" tries snacks first
---and falls back to the built-in window, anything else uses the built-in window
---directly so an explicit choice is honoured even when snacks is installed.
---@param opts table session picker options
---@param backend string|nil "snacks" | "internal"
---@return boolean opened
function M.open_session_browser(opts, backend)
  if backend == "snacks" then
    local snacks = require("acp.ui.session_snacks")
    if snacks.open(opts) then
      return true
    end
  end
  require("acp.ui.session_picker").open(opts)
  return true
end

---Icons for the given mode, e.g. `check_circle`.
---@param enabled boolean|nil
function M.icons(enabled)
  return require("acp.ui.icons").get(enabled)
end

---Diff rows for a set of hunks, used by the inline review card.
---@param opts table
function M.diff_lines(opts)
  return require("acp.ui.diff").lines(opts)
end

return M
