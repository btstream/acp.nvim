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
  -- Thoughts borrow the search highlight's *foreground* only. Linking the group
  -- wholesale would also take `IncSearch`'s background, painting a solid block
  -- behind the label instead of colouring the text.
  AcpThought = { link = "Comment" },
  -- Tool headers are deliberately quiet: they label a call, they are not the
  -- content. Linking `AcpToolTitle` to `Function` made long commands glare.
  AcpToolTitle = { link = "Comment" },
  AcpToolTag = { link = "Comment" },
  -- There is deliberately no `AcpToolBody` group: card body text must inherit
  -- whatever is behind it so the card's background shows through. A group
  -- linked to `Normal` (or any group carrying its own background) would repaint
  -- over the card and split it into strips.
  AcpCardBg = { link = "NormalFloat" },
  AcpCodeBlockBg = { link = "NormalFloat" },
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

---Relative luminance of a `#rrggbb` colour, 0 (black) to 1 (white).
---@param hex string
---@return number|nil
local function luminance(hex)
  if type(hex) ~= "string" or #hex ~= 7 then
    return nil
  end
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  if not (r and g and b) then
    return nil
  end
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

---Take the colour a highlight group *looks* like and apply it as a foreground.
---
---A search highlight usually pairs a dark foreground with a bright background,
---so copying `fg` alone would put near-black text on a dark transcript. The
---pair is resolved to whichever of the two reads clearly against `bg`.
---@param target string
---@param source string
---@param bg string current background, as `#rrggbb`
local function set_accent_fg(target, source, bg)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
  if not ok or type(hl) ~= "table" then
    return
  end
  local fg, source_bg = hl.fg, hl.bg
  if type(fg) == "number" then
    fg = string.format("#%06x", fg)
  end
  if type(source_bg) == "number" then
    source_bg = string.format("#%06x", source_bg)
  end

  local base = luminance(bg) or 0
  local function distance(hex)
    local l = luminance(hex)
    return l and math.abs(l - base) or -1
  end
  -- Prefer the pair member that is furthest from the background it will sit on.
  local chosen
  if fg and source_bg then
    chosen = distance(fg) >= distance(source_bg) and fg or source_bg
  else
    chosen = fg or source_bg
  end
  if chosen and distance(chosen) > 0.15 then
    vim.api.nvim_set_hl(0, target, { fg = chosen })
  end
end

---Shift `hex` away from `base` by `amount` (0 = unchanged, 1 = fully crossed).
---
---Moving *away* from the surface the value sits on is what makes a card
---distinguishable: mixing towards a colour it already equals is a no-op, which
---is how these surfaces once ended up identical to `Normal`.
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
  -- Light surfaces get lighter, and so do dark ones (a card reads as a raised
  -- surface); a near-white background is darkened instead so the card stays
  -- visible.
  local luma = (0.2126 * br + 0.7152 * bg + 0.0722 * bb) / 255
  local target = luma > 0.5 and 0 or 255
  local function blend(a, t)
    local v = math.floor(a + (t - a) * amount + 0.5)
    return math.max(0, math.min(255, v))
  end
  return string.format("#%02x%02x%02x", blend(hr, target), blend(hg, target), blend(hb, target))
end

---Colour a subtle surface derived from the current theme background.
---@param name string
---@param amount number how far to move away from the background
local function set_surface(name, amount)
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal and normal.bg
  if type(bg) == "number" then
    bg = string.format("#%06x", bg)
  end
  if type(bg) ~= "string" or #bg ~= 7 then
    return
  end
  local spec = M.groups[name] or {}
  local fg = spec.fg
  if type(fg) == "number" then
    fg = string.format("#%06x", fg)
  end
  local blended = mix(bg, bg, amount)
  if blended then
    vim.api.nvim_set_hl(0, name, { fg = fg, bg = blended })
  elseif spec.link then
    vim.api.nvim_set_hl(0, name, spec)
  end
end

---Copy the foreground of `source` onto `target`, ignoring its background.
---Define every group. Safe to call again after a colorscheme change.
local function apply()
  for name, spec in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  -- Thoughts take the search highlight's text colour only.
  -- Thoughts take the search highlight's accent colour as text colour. Which of
  -- its two colours that is depends on the theme: some pair a dark foreground
  -- with a bright background, so the pair member that reads against our own
  -- background is chosen.
  local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  if type(normal_bg) == "number" then
    normal_bg = string.format("#%06x", normal_bg)
  end
  if type(normal_bg) == "string" then
    set_accent_fg("AcpThought", "IncSearch", normal_bg)
  end
  -- Surfaces derived from the theme background so they work on light and dark
  -- themes. The card is the most prominent and the code block subtler so the
  -- two read as different things. Inline code intentionally has no surface:
  -- a background per word is noisy in prose and breaks up a card.
  set_surface("AcpCodeBlockBg", 0.11)
  set_surface("AcpCardBg", 0.15)
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
