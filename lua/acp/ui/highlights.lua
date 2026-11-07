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

---Apply highlights. `zed` selects a lower-contrast palette on top of the theme links.
---@param zed boolean|nil
function M.setup(zed)
  for name, spec in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  if zed then
    -- Low contrast surfaces: no hard borders, muted user text, quiet chrome.
    vim.api.nvim_set_hl(0, "AcpUser", { link = "Function" })
    vim.api.nvim_set_hl(0, "AcpUserChip", { link = "Visual" })
    vim.api.nvim_set_hl(0, "AcpSeparator", { fg = "grey30" })
  end
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
