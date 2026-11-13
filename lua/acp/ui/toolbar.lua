-- Winbar/statusline rendering.
--
-- Two rules keep this robust across resizes and layout managers:
--
--  * Alignment is delegated to Vim via `%=`. We never pad by hand, so a stale
--    width can never make the string wider than the window.
--  * Text is truncated to the measured budget before markers are added, so
--    escape sequences never get cut in half.

local Icons = require("acp.ui.icons")

local M = {}

---Neovim 0.12 adds inheriting statusline highlights. Older releases only
---understand %#group#; their window-local WinBar mapping supplies the surface.
---@param group string
---@return string
function M.highlight(group)
  if vim.fn.has("nvim-0.12") == 1 then
    return "%$" .. group .. "$"
  end
  return "%#" .. group .. "#"
end

---Escape agent supplied text for use inside a winbar.
---@param s string
---@return string
function M.escape(s)
  return (tostring(s):gsub("%%", "%%%%"))
end

local function dw(s)
  return vim.api.nvim_strwidth(s)
end

---Byte offsets where each UTF-8 codepoint starts (1-based, plus #s+1).
---LuaJIT has no `utf8` library, so this walks continuation bytes directly.
---@param s string
---@return integer[]
local function char_starts(s)
  local starts = { 1 }
  local i = 1
  local len = #s
  while i <= len do
    local byte = s:byte(i)
    local width = 1
    if byte >= 0xF0 then
      width = 4
    elseif byte >= 0xE0 then
      width = 3
    elseif byte >= 0xC0 then
      width = 2
    end
    i = i + width
    starts[#starts + 1] = i
  end
  return starts
end

---Truncate to a display width, appending an ellipsis when shortened.
---@param s string
---@param max integer
---@return string
function M.truncate(s, max)
  if max <= 0 then
    return ""
  end
  if dw(s) <= max then
    return s
  end
  if max <= 1 then
    return ""
  end
  -- Display width grows monotonically with the prefix, so binary search finds
  -- the longest fitting prefix in O(log n) width measurements instead of one
  -- per character (this runs on every winbar redraw).
  local starts = char_starts(s)
  local lo, hi = 1, #starts - 1 -- number of codepoints to keep
  local best = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if dw(s:sub(1, starts[mid + 1] - 1)) <= max - 1 then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  if best == 0 then
    return "…"
  end
  return s:sub(1, starts[best + 1] - 1) .. "…"
end

---Wrap text in a highlight group.
---
---Uses `%$name$` rather than `%#name#`: `$` inherits the attributes already in
---effect (notably the background) instead of restarting from `WinBar`. That
---matters because a layout manager may remap `WinBar` to its own group, which
---would otherwise repaint every region that only sets a foreground.
---@param text string
---@param hl string|nil
---@return string
local function hl(text, hl_group)
  local escaped = M.escape(text)
  if not hl_group then
    return escaped
  end
  return M.highlight(hl_group) .. escaped .. M.highlight("AcpToolbar")
end

---Render a clickable region.
---@param text string
---@param hl_group string|nil
---@param action string|nil global function name, e.g. "AcpPickModel"
---@return string
local function clickable(text, hl_group, action)
  local body = hl(text, hl_group)
  if action then
    -- `%T` terminates the clickable region; any text between it and the next
    -- `%T` is rendered, so no tooltip text may be added here.
    body = "%@v:lua." .. action .. "@" .. body .. "%T"
  end
  return body
end

---Modes that get a dedicated glyph. Anything else falls back to its own text.
local MODE_GLYPHS = { plan = "mode_plan", build = "mode_build" }

---Candidate strings to test, most specific first.
---@param mode string|nil
---@param key string|nil
---@return string[]
local function mode_candidates(mode, key)
  local out = {}
  if type(key) == "string" and key ~= "" then
    out[#out + 1] = key
  end
  if type(mode) == "string" and mode ~= "" then
    out[#out + 1] = mode
  end
  return out
end

---Text for the mode region: a glyph for known modes, the raw label otherwise.
---
---With `ui.icons = false` the label is kept, because a single ASCII letter would
---not tell the user which mode is active.
---@param mode string display label
---@param ic table<string, string>
---@param key string|nil value id, preferred for the glyph decision
---@return string
function M.mode_text(mode, ic, key)
  for _, candidate in ipairs(mode_candidates(mode, key)) do
    local glyph = MODE_GLYPHS[candidate:lower()]
    if glyph and ic[glyph] then
      return ic[glyph]
    end
  end
  return mode
end

---Highlight group for the mode region, so plan and build read differently.
---@param mode string display label
---@param key string|nil value id, preferred for the style decision
---@param plan boolean|nil the agent's own semantic kind, when it reported one
---@return string
function M.mode_hl(mode, key, plan)
  if plan then
    return "AcpToolbarModePlan"
  end
  for _, candidate in ipairs(mode_candidates(mode, key)) do
    local lower = candidate:lower()
    if lower == "plan" or lower == "architect" then
      return "AcpToolbarModePlan"
    elseif lower == "build" then
      return "AcpToolbarModeBuild"
    end
  end
  return "AcpToolbarAccent"
end

---Text for the status region.
---
---`running` shows the animation frame instead of a static glyph so the toolbar
---still reads as "busy"; every other state is a single glyph.
---@param status "waiting"|"running"|"cancelling"|"idle"
---@param ic table<string, string>
---@param spinner string|nil
---@return string
function M.status_text(status, ic, spinner)
  if status == "running" then
    return spinner or ic.tool_run
  end
  local key = "status_" .. status
  return ic[key] or ic.tool_pending
end

---Build the composer toolbar.
---@param info {mode: string|nil, mode_key: string|nil, mode_plan: boolean|nil, model: string|nil, thinking: string|nil, status: string, waiting: boolean|nil, queued: integer|nil, usage: table|nil, spinner: string|nil, show_usage: boolean|nil, chips: string[]|nil}
---@param width integer available cells (the whole window width)
---@return string
function M.render(info, width)
  local ic = Icons.get(info.icons)
  local width_ok = math.max(1, width - 1)

  -- The mode is a badge pinned to the very start of the bar: no leading space,
  -- and the highlight covers the padding around the glyph so it reads as a
  -- solid block rather than a floating icon.
  --
  -- `%#AcpToolbar#` opens the bar explicitly; everything after it uses
  -- `%$...$`, which inherits that background. Relying on the window's `WinBar`
  -- mapping instead would let a layout manager (edgy) remap it and turn every
  -- foreground-only region into a differently coloured block.
  local badge = "%#AcpToolbar#"
  local badge_width = 0
  if info.mode and info.mode ~= "" then
    local glyph = M.mode_text(info.mode, ic, info.mode_key)
    local group = M.mode_hl(info.mode, info.mode_key, info.mode_plan)
    badge = badge .. clickable(" " .. glyph .. " ", group, "AcpPickMode")
    badge_width = dw(glyph) + 2
  end

  -- Attachment chips follow the badge rather than preceding it: they are
  -- variable-width and would otherwise push the mode off the left edge and be
  -- truncated from the front on a narrow composer. Each label is clipped so a
  -- long filename cannot swallow the model name.
  local chip_text, chip_width = "", 0
  local chip_labels = {}
  for _, label in ipairs(info.chips or {}) do
    if label ~= "" then
      chip_labels[#chip_labels + 1] = "[" .. label .. "]"
    end
  end
  if #chip_labels > 0 then
    -- Leave room for the badge and for at least the status glyph on the right.
    local budget = math.max(4, width_ok - badge_width - 6)
    local rendered, used = {}, 0
    for _, label in ipairs(chip_labels) do
      if used >= budget then
        -- Signal the rest without spending cells on them.
        rendered[#rendered + 1] = "…"
        used = used + 1
        break
      end
      local per_label = math.max(3, budget - used - (#rendered > 0 and 1 or 0))
      local piece = M.truncate(label, per_label)
      if piece ~= "" then
        rendered[#rendered + 1] = piece
        used = used + dw(piece) + (#rendered > 1 and 1 or 0)
      end
      if dw(piece) < dw(label) then
        break
      end
    end
    if #rendered > 0 then
      local plain = table.concat(rendered, " ")
      chip_text = M.highlight("AcpUserChip") .. M.escape(plain) .. M.highlight("AcpToolbar") .. " "
      chip_width = dw(plain) + 1
    end
  end

  -- The rest of the left side is kept as structured segments so truncation can
  -- shrink the text while keeping every clickable region intact.
  local left = {}
  ---@param text string
  ---@param hl_group string|nil
  ---@param action string|nil
  local function push_left(text, hl_group, action)
    if #left > 0 then
      left[#left + 1] = { text = " · " }
    end
    left[#left + 1] = { text = text, hl = hl_group, action = action }
  end

  if info.model and info.model ~= "" then
    push_left(info.model, "AcpToolbarAccent", "AcpPickModel")
  end
  -- Thinking level is orthogonal to the work mode, so it gets its own small
  -- marker instead of sharing the mode badge.
  if info.thinking and info.thinking ~= "" then
    push_left(M.truncate(info.thinking, 12), "AcpMuted")
  end
  if info.show_usage and info.usage and info.usage.size and info.usage.size > 0 then
    local pct = math.floor((info.usage.used or 0) / info.usage.size * 100 + 0.5)
    push_left("Context" .. " " .. pct .. "%", "AcpMuted")
  end
  -- Some agents report the monetary cost of the turn; it is small and useful,
  -- so it follows the context marker rather than needing its own command.
  if info.show_usage and info.usage and type(info.usage.cost) == "table" then
    local amount = info.usage.cost.amount
    local currency = info.usage.cost.currency or ""
    if type(amount) == "number" and amount > 0 then
      -- Four decimals reads well for cents but rounds a sub-cent turn to
      -- "0.0000", which looks like "free". Fall back to significant digits.
      local text = amount < 0.0001 and string.format("%.2e", amount) or string.format("%.4f", amount)
      if currency ~= "" then
        text = text .. " " .. currency
      end
      push_left(text, "AcpMuted")
    end
  end

  local right_plain = {}
  local right_parts = {}
  local function push_right(text, hl_group)
    if #right_parts > 0 then
      right_plain[#right_plain + 1] = " · "
      right_parts[#right_parts + 1] = " · "
    end
    right_plain[#right_plain + 1] = text
    right_parts[#right_parts + 1] = hl(text, hl_group)
  end

  -- Status is a glyph: a spinner while running, an alert while a permission is
  -- pending, a cross while cancelling, an outline when idle.
  if info.waiting then
    push_right(M.status_text("waiting", ic, info.spinner), "AcpToolbarWaiting")
  elseif info.status == "running" then
    push_right(M.status_text("running", ic, info.spinner), "AcpToolbarRunning")
  elseif info.status == "cancelling" then
    push_right(M.status_text("cancelling", ic, info.spinner), "AcpToolbarCancelling")
  else
    push_right(M.status_text("idle", ic, info.spinner), "AcpToolbarIdle")
  end
  if info.queued and info.queued > 0 then
    push_right(string.format("+%d %s", info.queued, "queued"), "AcpMuted")
  end

  local left_text = {}
  for i, seg in ipairs(left) do
    left_text[i] = seg.text
  end
  left_text = table.concat(left_text)
  local right_text = table.concat(right_plain)
  local right_w = dw(right_text)

  -- The status side always wins: drop the left side entirely when needed.
  if right_w + badge_width + chip_width >= width_ok then
    return "%#AcpToolbar#" .. hl(M.truncate(right_text, math.max(1, width)), nil)
  end

  local budget = width_ok - right_w - badge_width - chip_width - 2
  local body
  if budget <= 0 or left_text == "" then
    body = table.concat(right_parts)
  else
    -- Truncate segment by segment so every region stays clickable even when
    -- the text has to be shortened.
    local rendered = {}
    local used = 0
    for _, seg in ipairs(left) do
      if used >= budget then
        break
      end
      local piece = M.truncate(seg.text, budget - used)
      local piece_w = dw(piece)
      if piece ~= "" then
        rendered[#rendered + 1] = clickable(piece, seg.hl, seg.action)
        used = used + piece_w
      end
      if piece_w < dw(seg.text) then
        break
      end
    end
    local left_rendered = table.concat(rendered)
    body = left_rendered ~= "" and (left_rendered .. "%=" .. table.concat(right_parts)) or table.concat(right_parts)
  end

  -- The badge is emitted with no surrounding spaces of its own, so its
  -- background starts at column 0 of the window. Chips sit between the badge
  -- and the model so a narrow composer truncates the labels, not the badge.
  return badge .. "%#AcpToolbar# " .. chip_text .. body .. " "
end

---Build the transcript window title.
---@param opts {agent: string, title: string|nil, pending_new: boolean, running: boolean}
---@param width integer
---@return string
function M.chat_title(opts, width)
  local title = opts.title
  if not title or title == "" then
    title = "No session"
  end
  local suffix = opts.pending_new and ("  " .. Icons.get(opts.icons).arrow_down .. " new") or ""
  local available = math.max(10, width - dw(opts.agent) - dw(suffix) - 6)
  -- The title bar sits on the transcript's own background, not the statusline
  -- colour: it is the transcript's header, not a separate strip. `AcpNormal`
  -- opens that background and every region inherits it with `%$...$`, so a
  -- layout manager remapping `WinBar` cannot repaint any of them.
  return "%#AcpNormal#"
    .. M.highlight("AcpTitle")
    .. M.escape(opts.agent)
    .. M.highlight("AcpNormal")
    .. M.highlight("AcpMuted")
    .. "·"
    .. M.highlight("AcpNormal")
    .. " "
    .. M.escape(M.truncate(title, available))
    .. (
      opts.pending_new and ("  " .. M.highlight("AcpStreaming") .. M.escape(suffix) .. M.highlight("AcpNormal")) or ""
    )
end

return M
