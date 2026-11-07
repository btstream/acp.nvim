-- Turning session blocks into display lines.
local i18n = require("acp.i18n")

local M = {}

---@class AcpRenderedLine
---@field text string
---@field segments {s: integer, e: integer, group: string}[]|nil

local function icons()
  return {
    tool = "⚙",
    tool_ok = "✓",
    tool_fail = "✗",
    tool_run = "◌",
    tool_pending = "○",
    user = "❯",
    assistant = "⏺",
    thought = "✻",
    plan = "▤",
    notice = "!",
    compaction = "▣",
    child = "↳",
    more = "…",
  }
end

local function ascii()
  return {
    tool = "*",
    tool_ok = "v",
    tool_fail = "x",
    tool_run = "o",
    tool_pending = ".",
    user = ">",
    assistant = "#",
    thought = "+",
    plan = "#",
    notice = "!",
    compaction = "=",
    child = ">",
    more = "...",
  }
end

---@param use_icons boolean
---@return table<string,string>
function M.icon_set(use_icons)
  return use_icons and icons() or ascii()
end

local function tool_status_label(status)
  if status == "completed" then
    return i18n.t("tool_completed")
  elseif status == "failed" then
    return i18n.t("tool_failed")
  elseif status == "cancelled" then
    return i18n.t("tool_cancelled")
  elseif status == "in_progress" then
    return i18n.t("tool_running")
  elseif status == "pending" then
    return i18n.t("tool_pending")
  end
  return ""
end

---Render markdown-ish text into lines with simple inline highlighting.
---@param text string
---@param base_hl string
---@param width integer
---@return AcpRenderedLine[]
function M.render_text(text, base_hl, width)
  local lines = {}
  local in_fence = false
  local fence_lang = nil
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    local line = raw:gsub("\r$", "")
    local fence = line:match("^```(%S*)")
    if fence then
      in_fence = not in_fence
      fence_lang = in_fence and fence or nil
      local label = in_fence and (fence_lang ~= "" and fence_lang or "code") or ""
      lines[#lines + 1] = {
        text = in_fence and ("╭─ " .. label) or "╰─",
        segments = { { s = 0, e = -1, group = "AcpCodeFence" } },
      }
    elseif in_fence then
      lines[#lines + 1] = {
        text = "│ " .. line,
        segments = { { s = 0, e = 1, group = "AcpCodeFence" } },
      }
    else
      local segments = { { s = 0, e = -1, group = base_hl } }
      local heading = line:match("^(#+)%s+(.*)")
      if heading then
        line = heading
        segments[1].group = "AcpHeading"
      elseif line:match("^>%s?") then
        line = line:gsub("^>%s?", "")
        segments[1].group = "AcpQuote"
      elseif line:match("^[%-%*]%s+") or line:match("^%d+[%.%)]%s+") then
        line = line:gsub("^([%-%*])%s+", "• "):gsub("^(%d+[%.%)])%s+", "%1 ")
      end
      -- inline code
      local pos = 1
      while true do
        local s, e = line:find("`[^`]+`", pos)
        if not s then
          break
        end
        segments[#segments + 1] = { s = s - 1, e = e, group = "AcpInlineCode" }
        pos = e + 1
      end
      lines[#lines + 1] = { text = line, segments = segments }
    end
  end
  -- Drop the trailing empty line introduced by the appended newline.
  if #lines > 0 and lines[#lines].text == "" then
    lines[#lines] = nil
  end
  return lines
end

local function render_user(block, ctx)
  local ic = ctx.icons
  local chips = {}
  if block.attachments then
    for _, att in ipairs(block.attachments) do
      chips[#chips + 1] = "[" .. (att.label or att.path or "?") .. "]"
    end
  end
  local header = ic.user .. " " .. i18n.t("you")
  if #chips > 0 then
    header = header .. "  " .. table.concat(chips, " ")
  end
  local out = {
    { text = header, segments = { { s = 0, e = -1, group = "AcpUser" } } },
  }
  local body = M.render_text(block.text or "", "AcpUser", ctx.width)
  for _, line in ipairs(body) do
    line.text = "  " .. line.text
    for _, seg in ipairs(line.segments or {}) do
      seg.s = seg.s + 2
      if seg.e >= 0 then
        seg.e = seg.e + 2
      end
    end
    out[#out + 1] = line
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_assistant(block, ctx)
  local ic = ctx.icons
  local prefix = block.child and (ic.child .. " ") or ""
  local body = M.render_text(block.text or "", "AcpAssistant", ctx.width)
  local out = {}
  for i, line in ipairs(body) do
    if i == 1 then
      out[#out + 1] = {
        text = prefix .. ic.assistant .. " " .. line.text,
        segments = line.segments,
      }
    else
      local shift = #prefix + 2
      line.text = string.rep(" ", shift) .. line.text
      for _, seg in ipairs(line.segments or {}) do
        seg.s = seg.s + shift
        if seg.e >= 0 then
          seg.e = seg.e + shift
        end
      end
      out[#out + 1] = line
    end
  end
  if #out == 0 then
    out[1] = { text = prefix .. ic.assistant, segments = { { s = 0, e = -1, group = "AcpAssistant" } } }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_thought(block, ctx)
  local lines = M.render_text(block.text or "", "AcpThought", ctx.width)
  local out = {}
  for i, line in ipairs(lines) do
    local text = i == 1 and (ctx.icons.thought .. " " .. line.text) or ("  " .. line.text)
    out[#out + 1] = { text = text, segments = { { s = 0, e = -1, group = "AcpThought" } } }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function tool_icon(block, ic)
  if block.status == "completed" then
    return ic.tool_ok, "AcpToolSuccess"
  elseif block.status == "failed" then
    return ic.tool_fail, "AcpToolError"
  elseif block.status == "cancelled" then
    return ic.tool_fail, "AcpToolCancelled"
  elseif block.status == "in_progress" then
    return ic.tool_run, "AcpToolRunning"
  end
  return ic.tool_pending, "AcpToolRunning"
end

local function render_tool(block, ctx)
  local ic = ctx.icons
  local glyph, glyph_hl = tool_icon(block, ic)
  local caret = block.expanded and "▾" or "▸"
  local title = block.title ~= nil and block.title ~= "" and block.title or (block.name or "tool")
  local status = tool_status_label(block.status)
  local label = string.format("%s %s %s", caret, glyph, title)
  local caret_end = #caret
  local glyph_start = caret_end + 1
  local glyph_end = glyph_start + #glyph
  local title_start = glyph_end + 1
  local segments = {
    { s = 0, e = caret_end, group = "AcpSeparator" },
    { s = glyph_start, e = glyph_end, group = glyph_hl },
    { s = title_start, e = -1, group = "AcpToolTitle" },
  }
  local meta = {}
  if block.child and block.child.title then
    meta[#meta + 1] = i18n.t("child") .. ": " .. block.child.title
  end
  if status ~= "" then
    meta[#meta + 1] = status
  end
  local suffix = #meta > 0 and ("  " .. table.concat(meta, " · ")) or ""
  if suffix ~= "" then
    segments[#segments + 1] = { s = string.len(label), e = -1, group = glyph_hl }
  end
  local out = {
    {
      text = label .. suffix,
      segments = segments,
    },
  }

  if block.expanded then
    if block.detail and block.detail ~= "" then
      local lines = M.render_text(block.detail, "AcpMuted", ctx.width)
      for _, line in ipairs(lines) do
        line.text = "    " .. line.text
        for _, seg in ipairs(line.segments or {}) do
          seg.s = seg.s + 4
          if seg.e >= 0 then
            seg.e = seg.e + 4
          end
        end
        out[#out + 1] = line
      end
    end
    if block.locations and #block.locations > 0 then
      for _, loc in ipairs(block.locations) do
        local rel = loc.path or ""
        if ctx.cwd and vim.startswith(rel, ctx.cwd .. "/") then
          rel = rel:sub(#ctx.cwd + 2)
        end
        local text = string.format("    %s%s", rel, loc.line and (":" .. loc.line) or "")
        out[#out + 1] = {
          text = text,
          segments = { { s = 4, e = -1, group = "AcpLink" } },
          location = loc,
        }
      end
    end
    if block.status == "failed" and block.raw_output then
      local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
      for _, line in ipairs(M.render_text(dump, "AcpToolError", ctx.width)) do
        line.text = "    " .. line.text
        out[#out + 1] = line
      end
    end
  elseif block.detail and block.detail ~= "" then
    local first = vim.split(block.detail, "\n", { plain = true })[1] or ""
    if first ~= "" then
      local maxw = math.max(10, ctx.width - 8)
      if vim.fn.strdisplaywidth(first) > maxw then
        first = vim.fn.strcharpart(first, 0, maxw) .. ic.more
      end
      out[#out + 1] = {
        text = "    " .. first,
        segments = { { s = 4, e = -1, group = "AcpMuted" } },
      }
    end
  end

  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_plan(block, ctx)
  local ic = ctx.icons
  local out = {
    { text = ic.plan .. " " .. i18n.t("plan"), segments = { { s = 0, e = -1, group = "AcpPlan" } } },
  }
  for _, entry in ipairs(block.entries or {}) do
    local mark, hl
    if entry.status == "completed" then
      mark, hl = "✓", "AcpPlanDone"
    elseif entry.status == "in_progress" then
      mark, hl = "◌", "AcpPlan"
    else
      mark, hl = "○", "AcpPlanPending"
    end
    out[#out + 1] = {
      text = "  " .. mark .. " " .. (entry.content or ""),
      segments = { { s = 2, e = 2 + #mark, group = hl } },
    }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_notice(block, ctx)
  local hl = "AcpNotice"
  if block.severity == "warning" then
    hl = "AcpNoticeWarn"
  elseif block.severity == "error" then
    hl = "AcpNoticeError"
  end
  local text = string.format("%s %s%s", ctx.icons.notice, block.title and (block.title .. ": ") or "", block.text or "")
  return { { text = text, segments = { { s = 0, e = -1, group = hl } } }, { text = "", segments = nil } }
end

local function render_compaction(block, ctx)
  local label
  if block.status == "in_progress" then
    label = i18n.t("compaction") .. " …"
  elseif block.status == "failed" then
    label = i18n.t("compaction") .. " (" .. i18n.t("tool_failed") .. ")"
  elseif block.status == "cancelled" then
    label = i18n.t("compaction") .. " (" .. i18n.t("tool_cancelled") .. ")"
  else
    label = i18n.t("compaction")
  end
  local out = {
    { text = "── " .. label .. " ──", segments = { { s = 0, e = -1, group = "AcpSeparator" } } },
  }
  if block.expanded and block.text and block.text ~= "" then
    for _, line in ipairs(M.render_text(block.text, "AcpMuted", ctx.width)) do
      line.text = "  " .. line.text
      out[#out + 1] = line
    end
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

local function render_error(block, ctx)
  local lines = M.render_text(block.text or "", "AcpToolError", ctx.width)
  local out = {}
  for i, line in ipairs(lines) do
    out[#out + 1] = {
      text = i == 1 and ("✗ " .. line.text) or ("  " .. line.text),
      segments = { { s = 0, e = -1, group = "AcpToolError" } },
    }
  end
  out[#out + 1] = { text = "", segments = nil }
  return out
end

---Render a single block.
---@param block AcpBlock
---@param ctx {icons: table, width: integer, cwd: string|nil, show_thoughts: boolean}
---@return AcpRenderedLine[]
function M.render_block(block, ctx)
  local kind = block.kind
  if kind == "user" then
    return render_user(block, ctx)
  elseif kind == "agent" then
    return render_assistant(block, ctx)
  elseif kind == "thought" then
    if not ctx.show_thoughts then
      return {}
    end
    return render_thought(block, ctx)
  elseif kind == "tool" then
    return render_tool(block, ctx)
  elseif kind == "plan" then
    return render_plan(block, ctx)
  elseif kind == "notice" then
    return render_notice(block, ctx)
  elseif kind == "compaction" then
    return render_compaction(block, ctx)
  elseif kind == "error" then
    return render_error(block, ctx)
  elseif kind == "system" then
    return {
      { text = block.text or "", segments = { { s = 0, e = -1, group = "AcpMuted" } } },
      { text = "", segments = nil },
    }
  end
  return {}
end

return M
