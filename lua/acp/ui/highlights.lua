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
  AcpMdCode = { link = "String" },
  AcpBold = { bold = true },
  AcpItalic = { italic = true },
  AcpStrike = { strikethrough = true },
  AcpMdLink = { link = "Underlined" },
  AcpH1 = { link = "Title", bold = true },
  AcpH2 = { link = "Title" },
  AcpH3 = { link = "Function" },
  AcpH4 = { link = "Function" },
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

---Blend `hex` towards `base` by `amount` (0 = hex, 1 = base).
---
---Used to derive the code-block and inline-code surfaces from the theme's own
---background, so they stay readable on light and dark colourschemes alike.
---@param hex string
---@param base string
---@param amount number
---@return string|nil
local function mix(hex, base, amount)
  if type(hex) ~= "string" or type(base) ~= "string" then
    return nil
  end
  if #hex ~= 7 or #base ~= 7 then
    return nil
  end
  local function parts(s)
    return tonumber(s:sub(2, 3), 16), tonumber(s:sub(4, 5), 16), tonumber(s:sub(6, 7), 16)
  end
  local hr, hg, hb = parts(hex)
  local br, bg, bb = parts(base)
  if not (hr and br) then
    return nil
  end
  local function blend(a, b)
    return math.floor(a + (b - a) * amount + 0.5)
  end
  return string.format("#%02x%02x%02x", blend(hr, br), blend(hg, bg), blend(hb, bb))
end

---Colour a subtle surface derived from the current theme background.
---@param name string
---@param amount number how far to move towards the background
local function set_surface(name, amount)
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal and normal.bg
  if type(bg) == "number" then
    bg = string.format("#%06x", bg)
  end
  local spec = M.groups[name] or {}
  local base = spec.bg or bg
  if type(base) == "number" then
    base = string.format("#%06x", base)
  end
  local fg = spec.fg
  if type(fg) == "number" then
    fg = string.format("#%06x", fg)
  end
  local blended = mix(base, bg, amount)
  if blended then
    vim.api.nvim_set_hl(0, name, { fg = fg, bg = blended })
  elseif spec.link then
    vim.api.nvim_set_hl(0, name, spec)
  end
end

---Define every group. Safe to call again after a colorscheme change.
local function apply()
  for name, spec in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  -- Surfaces derived from the theme so they work on light and dark themes.
  set_surface("AcpMdCode", 0.15)
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
