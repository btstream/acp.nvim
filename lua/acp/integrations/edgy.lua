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
      size = { width = opts.width or 0.38 },
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
      size = { height = opts.input_height or 8 },
      wo = {
        winbar = not toolbar_winbar,
        winfixwidth = true,
        winfixheight = false,
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
  edgy_opts.right = edgy_opts.right or {}
  local views = M.views(view_opts)
  local present = {}
  for _, view in ipairs(edgy_opts.right) do
    if type(view) == "table" and view.ft then
      present[view.ft] = true
    elseif type(view) == "string" then
      present[view] = true
    end
  end
  if not present["acp_chat"] then
    table.insert(edgy_opts.right, 1, views.chat)
  end
  if not present["acp_input"] then
    table.insert(edgy_opts.right, 2, views.input)
  end
  return edgy_opts
end

---Whether edgy is installed and loaded.
---@return boolean
function M.available()
  local ok, edgy = pcall(require, "edgy")
  return ok and edgy ~= nil
end

return M
