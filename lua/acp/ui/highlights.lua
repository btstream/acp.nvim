-- Semantic highlight groups. Themes can override any of these.
local M = {}

M.groups = {
  AcpNormal = { link = "Normal" },
  AcpMuted = { link = "Comment" },
  AcpBorder = { link = "FloatBorder" },
  AcpTitle = { link = "Title", bold = true },
  AcpToolbar = { link = "StatusLine" },
  AcpToolbarAccent = { link = "DiagnosticInfo" },
  AcpUser = { link = "Identifier" },
  AcpUserChip = { link = "Visual" },
  AcpAssistant = { link = "Normal" },
  AcpThought = { link = "Comment", italic = true },
  AcpToolTitle = { link = "Function" },
  AcpToolRunning = { link = "DiagnosticWarn" },
  AcpToolSuccess = { link = "DiagnosticOk" },
  AcpToolError = { link = "DiagnosticError" },
  AcpToolCancelled = { link = "Comment" },
  AcpCode = { link = "NormalFloat" },
  AcpCodeFence = { link = "Comment" },
  AcpInlineCode = { link = "String" },
  AcpHeading = { link = "Title", bold = true },
  AcpQuote = { link = "Comment", italic = true },
  AcpLink = { link = "Underlined" },
  AcpPlan = { link = "DiagnosticInfo" },
  AcpPlanDone = { link = "DiagnosticOk" },
  AcpPlanPending = { link = "Comment" },
  AcpNotice = { link = "DiagnosticInfo" },
  AcpNoticeWarn = { link = "DiagnosticWarn" },
  AcpNoticeError = { link = "DiagnosticError" },
  AcpPermission = { link = "DiagnosticWarn", bold = true },
  AcpChild = { link = "Comment" },
  AcpSeparator = { link = "NonText" },
  AcpStreaming = { link = "DiagnosticInfo" },
  AcpSelection = { link = "Visual" },
  AcpPinned = { link = "StatusLine" },
}

local zed_style = true
local augroup = nil

---Define every group. Safe to call again after a colorscheme change.
local function apply()
  for name, spec in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  if zed_style then
    -- Low contrast surfaces: no hard borders, muted user text, quiet chrome.
    vim.api.nvim_set_hl(0, "AcpUser", { link = "Function" })
    vim.api.nvim_set_hl(0, "AcpUserChip", { link = "Visual" })
    vim.api.nvim_set_hl(0, "AcpSeparator", { fg = "grey30" })
  end
end

M.apply = apply

---Apply highlights. `zed` selects a lower-contrast palette on top of the theme links.
---
---A colorscheme load clears every user group, so the definitions are re-applied
---on ColorScheme. Without this the whole panel loses its colours when the user
---switches theme after setup.
---@param zed boolean|nil
function M.setup(zed)
  zed_style = zed ~= false
  apply()

  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("AcpHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      apply()
    end,
  })
end

---Resolve a status to a highlight group.
---@param status string|nil
---@return string
function M.tool_status(status)
  if status == "completed" then
    return "AcpToolSuccess"
  elseif status == "failed" then
    return "AcpToolError"
  elseif status == "in_progress" or status == "pending" then
    return "AcpToolRunning"
  elseif status == "cancelled" then
    return "AcpToolCancelled"
  end
  return "AcpMuted"
end

return M
