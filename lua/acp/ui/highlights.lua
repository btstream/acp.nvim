-- Semantic highlight groups. Themes can override any of these.
local M = {}

M.groups = {
  AcpNormal = { link = "Normal" },
  AcpMuted = { link = "Comment" },
  AcpBorder = { link = "FloatBorder" },
  AcpTitle = { link = "Title", bold = true },
  AcpToolbar = { link = "StatusLine" },
  -- Toolbar regions share the bar's background; only the foreground varies, so
  -- the bar reads as one strip instead of a set of coloured blocks.
  AcpToolbarAccent = { fg = "NONE" },
  AcpToolbarModePlan = { fg = "NONE" },
  AcpToolbarModeBuild = { fg = "NONE" },
  AcpToolbarIdle = { fg = "NONE" },
  AcpToolbarRunning = { fg = "NONE" },
  AcpToolbarWaiting = { fg = "NONE" },
  AcpToolbarCancelling = { fg = "NONE" },
  -- Low contrast surfaces: no hard borders, muted user text, quiet chrome.
  AcpUser = { link = "Function" },
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
  AcpCodeLang = { link = "Comment" },
  AcpTableHead = { link = "Function", bold = true },
  -- Every table border character shares one group so the frame reads as a
  -- single line rather than a mix of tones.
  AcpTableBorder = { link = "NonText" },
  AcpToolRunning = { link = "DiagnosticWarn" },
  AcpToolSuccess = { link = "DiagnosticOk" },
  AcpToolError = { link = "DiagnosticError" },
  AcpToolCancelled = { link = "Comment" },
  AcpMdCode = { link = "String" },
  AcpBold = { bold = true },
  AcpItalic = { italic = true },
  AcpStrike = { strikethrough = true },
  AcpMdLink = { link = "Underlined" },
  AcpH1 = { link = "Title", bold = true },
  AcpH2 = { link = "Title" },
  AcpH3 = { link = "Function" },
  AcpH4 = { link = "Function" },
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
  AcpSeparator = { fg = "grey30" },
  AcpStreaming = { link = "DiagnosticInfo" },
  AcpSelection = { link = "Visual" },
  AcpPinned = { link = "StatusLine" },
}

---Define a highlight group without clobbering an existing definition.
---
---`default = true` is Neovim's `:hi-default`: the group is only defined when it
---does not exist yet, so a colour the user set (before or after setup, or from a
---theme) always wins. A colorscheme load clears the groups, which lets the
---defaults be re-established on the next apply.
---@param name string
---@param spec table
---@return boolean applied false when the group already existed
local function set_hl(name, spec)
  -- `default` belongs *in* the spec, not in an opts argument: nvim_set_hl takes
  -- three parameters, and a fourth is silently ignored by pcall.
  local ok = pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", spec, { default = true }))
  return ok
end

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
    set_hl(target, { fg = chosen })
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
    set_hl(name, { fg = fg, bg = blended })
  elseif spec.link then
    set_hl(name, spec)
  end
end

---Copy the foreground of `source` onto `target`, ignoring its background.
---Relative luminance of a `#rrggbb` colour, 0 (black) to 1 (white).
---@param hex string
---@return number|nil
local function relative_luminance(hex)
  if type(hex) ~= "string" or #hex ~= 7 then
    return nil
  end
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  if not (r and g and b) then
    return nil
  end
  local function channel(c)
    c = c / 255
    return c <= 0.03928 and (c / 12.92) or (((c + 0.055) / 1.055) ^ 2.4)
  end
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
end

---Contrast ratio between two colours, per WCAG.
---@param a string
---@param b string
---@return number|nil
local function contrast_ratio(a, b)
  local la, lb = relative_luminance(a), relative_luminance(b)
  if not (la and lb) then
    return nil
  end
  if la < lb then
    la, lb = lb, la
  end
  return (la + 0.05) / (lb + 0.05)
end

---Lighten or darken `hex` until it reaches `target` contrast against `bg`.
---
---A theme's muted colour is often tuned for prose on `Normal`, not for a glyph
---on a statusline bar; without this an idle marker can end up all but invisible.
---@param hex string
---@param bg string
---@param target number|nil
---@return string
local function ensure_contrast(hex, bg, target)
  local want = target or 4.5
  local base = relative_luminance(bg)
  if not base then
    return hex
  end
  -- Move away from the background: brighten on dark bars, darken on light ones.
  local step = base < 0.5 and 1 or -1
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  if not (r and g and b) then
    return hex
  end
  for _ = 1, 24 do
    local current = string.format("#%02x%02x%02x", r, g, b)
    local ratio = contrast_ratio(current, bg)
    if ratio and ratio >= want then
      return current
    end
    r = math.max(0, math.min(255, r + step * 6))
    g = math.max(0, math.min(255, g + step * 6))
    b = math.max(0, math.min(255, b + step * 6))
  end
  return string.format("#%02x%02x%02x", r, g, b)
end

---Tint `hex` towards `target` by `amount`, keeping its own colour cast.
---
---@param hex string
---@param target string
---@param amount number
---@return string|nil
local function tint(hex, target, amount)
  if type(hex) ~= "string" or type(target) ~= "string" then
    return nil
  end
  if #hex ~= 7 or #target ~= 7 then
    return nil
  end
  local function parts(s)
    return tonumber(s:sub(2, 3), 16), tonumber(s:sub(4, 5), 16), tonumber(s:sub(6, 7), 16)
  end
  local hr, hg, hb = parts(hex)
  local tr, tg, tb = parts(target)
  if not (hr and tr) then
    return nil
  end
  local function blend(a, b)
    return math.max(0, math.min(255, math.floor(a + (b - a) * amount + 0.5)))
  end
  return string.format("#%02x%02x%02x", blend(hr, tr), blend(hg, tg), blend(hb, tb))
end

---Style a toolbar mode as a tinted block.
---
---Modes are told apart by their *background*, not their glyph colour: the mode
---block reads as a small badge, while the status stays a bare glyph on the bar.
---The text colour is resolved against the tinted block so it stays readable.
---@param target string
---@param accent string theme group supplying the tint
---@param amount number|nil how strongly to tint (default 0.55)
local function set_toolbar_mode(target, accent, amount)
  local bar = vim.api.nvim_get_hl(0, { name = "AcpToolbar", link = false })
  local bar_bg = bar and bar.bg
  local ok, spec = pcall(vim.api.nvim_get_hl, 0, { name = accent, link = false })
  if not ok or type(spec) ~= "table" then
    return
  end
  local accent_hex = spec.bg or spec.fg
  if type(accent_hex) == "number" then
    accent_hex = string.format("#%06x", accent_hex)
  end
  if type(bar_bg) == "number" then
    bar_bg = string.format("#%06x", bar_bg)
  end
  if type(accent_hex) ~= "string" or type(bar_bg) ~= "string" then
    return
  end

  -- A strong tint on the badge, so it stands out from the bar it sits on.
  local bg = tint(bar_bg, accent_hex, amount or 0.85)
  if not bg then
    return
  end
  -- The glyph sits *on* the badge, so its contrast is measured against the
  -- badge, not against the bar. Starting from the bar colour and pushing away
  -- from the badge gives a dark glyph on a bright badge (and vice versa).
  local fg = ensure_contrast(bar_bg, bg, 4.5)
  set_hl(target, { fg = fg, bg = bg })
end

---Give `target` the foreground of `source` and the toolbar's background.
---
---Used for toolbar regions: they must all share one background, so a link to a
---group that carries its own (DiagnosticInfo, Visual, ...) would paint a block
---inside the bar instead of just colouring the glyph. The foreground is nudged
---until it is readable on that background.
---@param target string
---@param source string
---@param min_contrast number|nil defaults to 4.5 (WCAG AA for normal text)
local function set_toolbar_fg(target, source, min_contrast)
  local ok, spec = pcall(vim.api.nvim_get_hl, 0, { name = source, link = false })
  if not ok or type(spec) ~= "table" or spec.fg == nil then
    return
  end
  local fg = spec.fg
  if type(fg) == "number" then
    fg = string.format("#%06x", fg)
  end
  local bar = vim.api.nvim_get_hl(0, { name = "AcpToolbar", link = false })
  local bg = bar and bar.bg
  if type(bg) == "number" then
    bg = string.format("#%06x", bg)
  end
  if type(fg) == "string" and type(bg) == "string" then
    fg = ensure_contrast(fg, bg, min_contrast)
  end
  set_hl(target, { fg = fg, bg = bg })
end

---Define every group. Safe to call again after a colorscheme change.
local function apply()
  -- Order matters with `default = true`: a group is only defined once per pass,
  -- so anything a later step reads has to be written first. The bar is defined
  -- up front because the toolbar regions derive their background from it.
  set_hl("AcpToolbar", M.groups.AcpToolbar)

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

  -- Toolbar regions: one shared background, a distinct foreground each, so
  -- state and mode are told apart by colour rather than by a coloured block.
  --
  -- Colours come from the theme's semantic groups, which keeps them readable on
  -- light and dark schemes alike. Only the foreground is set; the background
  -- stays whatever `AcpToolbar` (StatusLine) provides.
  --
  -- Every foreground is picked to stand out from the bar itself. `Comment` is
  -- deliberately not used: it sits at ~2.9:1 against a typical statusline
  -- background, which reads as almost invisible for a small glyph.
  --
  -- Modes read as tinted badges; statuses stay plain glyphs on the bar.
  set_toolbar_mode("AcpToolbarModePlan", "DiagnosticInfo")
  set_toolbar_mode("AcpToolbarModeBuild", "DiagnosticOk")
  set_toolbar_fg("AcpToolbarIdle", "Comment")
  set_toolbar_fg("AcpToolbarRunning", "DiagnosticInfo")
  set_toolbar_fg("AcpToolbarWaiting", "DiagnosticWarn")
  set_toolbar_fg("AcpToolbarCancelling", "DiagnosticError")
  set_toolbar_fg("AcpToolbarAccent", "Normal")

  -- Everything else comes from the static table.
  for name, spec in pairs(M.groups) do
    set_hl(name, spec)
  end
end

M.apply = apply

---Apply highlights.
---
---A colorscheme load clears every user group, so the definitions are re-applied
---on ColorScheme. Without this the whole panel loses its colours when the user
---switches theme after setup.
function M.setup()
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
