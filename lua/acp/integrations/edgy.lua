-- edgy.nvim integration helpers.
--
-- acp.nvim exposes two ordinary views (`acp_chat` and `acp_input`) so that a
-- layout manager can own their position. This module builds the recommended
-- edgy view definitions without touching the user's configuration.
local M = {}

---@param opts {agent_title?: string, width?: number, input_height?: number, toolbar_winbar?: boolean, title_winbar?: boolean}|nil
---@return {chat: table, input: table}
function M.views(opts)
  opts = opts or {}
  local toolbar_winbar = opts.toolbar_winbar ~= false
  local title_winbar = opts.title_winbar == true
  return {
    chat = {
      ft = "acp_chat",
      title = opts.agent_title or "Agent",
      size = { width = opts.width or require("acp.config").defaults.layout.width },
      wo = {
        -- acp renders a richer title (session name, new-output marker) by
        -- default. Set title_winbar = true to let edgy own it instead.
        winbar = title_winbar,
        winfixwidth = true,
      },
    },
    input = {
      ft = "acp_input",
      title = "Message",
      size = { height = opts.input_height or require("acp.config").defaults.layout.input_height },
      wo = {
        winbar = not toolbar_winbar,
        winfixwidth = true,
        winfixheight = true,
      },
    },
  }
end

---Append the ACP views to an edgy config in place.
---Use inside a lazy.nvim `opts` function:
---
---   opts = function(_, opts)
---     require("acp.integrations.edgy").extend(opts)
---   end
---@param edgy_opts table
---@param view_opts table|nil
---@return table
function M.extend(edgy_opts, view_opts)
  edgy_opts = edgy_opts or {}
  -- Honour the configured panel side instead of always using `right`.
  local position = "right"
  local ok, config = pcall(require, "acp.config")
  if ok and config.defaults and config.defaults.layout then
    position = config.defaults.layout.position or "right"
  end
  if view_opts and view_opts.position then
    position = view_opts.position
  end
  edgy_opts[position] = edgy_opts[position] or {}
  local views = M.views(view_opts)
  local present = {}
  for _, view in ipairs(edgy_opts[position]) do
    if type(view) == "table" and view.ft then
      present[view.ft] = true
    elseif type(view) == "string" then
      present[view] = true
    end
  end
  if not present["acp_chat"] then
    table.insert(edgy_opts[position], 1, views.chat)
  end
  if not present["acp_input"] then
    table.insert(edgy_opts[position], 2, views.input)
  end
  return edgy_opts
end

---Whether edgy is installed and loaded.
---
---Uses `package.loaded` first so merely checking availability cannot trigger a
---lazy-load of edgy as a side effect.
---@return boolean
function M.available()
  if package.loaded["edgy"] ~= nil then
    return true
  end
  local ok, edgy = pcall(require, "edgy")
  return ok and edgy ~= nil
end

---Whether a view for `ft` is registered with edgy.
---
---edgy only builds a layout for a position when its view list has a non-empty
---array part (`#views > 0`). A config written as `right = { chat = {...} }`
---therefore silently registers nothing, and the panel windows stay where acp
---creates them. Detecting this lets us warn instead of leaving the user with a
---misplaced layout.
---@param ft string
---@return boolean
function M.has_view(ft)
  local ok, config = pcall(require, "edgy.config")
  if not ok or type(config) ~= "table" then
    return false
  end
  for _, position in ipairs({ "left", "right", "bottom", "top" }) do
    local views = config[position]
    if type(views) == "table" then
      for _, view in ipairs(views) do
        if type(view) == "table" and view.ft == ft then
          return true
        end
        if view == ft then
          return true
        end
      end
    end
  end
  return false
end

---Warn when edgy is the layout backend but the ACP views are not registered.
---
---Registers a single delayed check so the warning appears at most once per
---session, and only when the user actually opened the panel.
function M.check_registered()
  if not M.available() then
    return
  end
  if M._checked then
    return
  end
  M._checked = true
  local missing = {}
  for _, ft in ipairs({ "acp_chat", "acp_input" }) do
    if not M.has_view(ft) then
      missing[#missing + 1] = ft
    end
  end
  if #missing == 0 then
    return
  end
  vim.schedule(function()
    vim.notify(
      string.format(
        "acp.nvim: %s is not registered with edgy. Add the views as array "
          .. "entries (not as named keys) or call require('acp.integrations.edgy').extend(opts).",
        table.concat(missing, " and ")
      ),
      vim.log.levels.WARN
    )
  end)
end

return M
