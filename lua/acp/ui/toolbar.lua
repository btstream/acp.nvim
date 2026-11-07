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

---Escape agent supplied text for use inside a winbar.
---@param s string
---@return string
function M.escape(s)
  return (tostring(s):gsub("%%", "%%%%"))
end

local function dw(s)
  return vim.fn.strdisplaywidth(s)
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
  local out = {}
  local used = 0
  for _, char in ipairs(vim.fn.split(s, "\\zs")) do
    local w = vim.fn.strdisplaywidth(char)
    if used + w > max - 1 then
      break
    end
    out[#out + 1] = char
    used = used + w
  end
  return table.concat(out) .. "…"
end

---Wrap text in a highlight group.
---@param text string
---@param hl string|nil
---@return string
local function hl(text, hl_group)
  local escaped = M.escape(text)
  if not hl_group then
    return escaped
  end
  return "%#" .. hl_group .. "#" .. escaped .. "%#AcpToolbar#"
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

---Build the composer toolbar.
---@param info {mode: string|nil, model: string|nil, status: string, waiting: boolean|nil, queued: integer|nil, usage: table|nil, spinner: string|nil, show_usage: boolean|nil}
---@param width integer available cells (the whole window width)
---@return string
function M.render(info, width)
  local ic = Icons.get(info.icons)
  local width_ok = math.max(1, width - 1)

  local left_plain = {}
  local left_parts = {}
  local function push_left(text, hl_group, action)
    if #left_parts > 0 then
      left_plain[#left_plain + 1] = " · "
      left_parts[#left_parts + 1] = " · "
    end
    left_plain[#left_plain + 1] = text
    left_parts[#left_parts + 1] = clickable(text, hl_group, action)
  end

  if info.mode and info.mode ~= "" then
    push_left(info.mode .. " " .. ic.chevron_down, nil, "AcpPickMode")
  end
  if info.model and info.model ~= "" then
    push_left(info.model .. " " .. ic.chevron_down, "AcpToolbarAccent", "AcpPickModel")
  end
  if info.show_usage and info.usage and info.usage.size and info.usage.size > 0 then
    local pct = math.floor((info.usage.used or 0) / info.usage.size * 100 + 0.5)
    push_left("Context" .. " " .. pct .. "%", "AcpMuted")
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

  if info.waiting then
    push_right("! " .. "Waiting", "AcpPermission")
  elseif info.status == "running" then
    local spinner = info.spinner and (info.spinner .. " ") or ""
    push_right(spinner .. "Running", "AcpStreaming")
  elseif info.status == "cancelling" then
    push_right("… " .. "Session stopped", "AcpMuted")
  else
    push_right("Idle", "AcpMuted")
  end
  if info.queued and info.queued > 0 then
    push_right(string.format("+%d %s", info.queued, "queued"), "AcpMuted")
  end

  local left_text = table.concat(left_plain)
  local right_text = table.concat(right_plain)
  local right_w = dw(right_text)

  -- The status side always wins: drop the left side entirely when needed.
  if right_w >= width_ok then
    return "%#AcpToolbar# " .. hl(M.truncate(right_text, width_ok - 1), nil) .. " "
  end

  local budget = width_ok - right_w - 2
  local trimmed = M.truncate(left_text, budget)

  local body
  if trimmed == "" then
    body = table.concat(right_parts)
  else
    -- Rebuild the clickable segments against the truncated text only when the
    -- text actually had to be shortened; otherwise keep the click targets.
    local left_rendered
    if trimmed == left_text then
      left_rendered = table.concat(left_parts)
    else
      left_rendered = hl(trimmed, nil)
    end
    body = left_rendered .. "%=" .. table.concat(right_parts)
  end

  return "%#AcpToolbar# " .. body .. " "
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
  return "%#AcpTitle# "
    .. M.escape(opts.agent)
    .. "%* %#AcpMuted#·%* "
    .. M.escape(M.truncate(title, available))
    .. (opts.pending_new and ("  %#AcpStreaming#" .. M.escape(suffix .. "") .. "%*") or "")
end

return M
