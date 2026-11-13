-- Tool-call cards: header, status, expanded detail and file locations.
local text_layout = require("acp.ui.text")
local diff_layout = require("acp.ui.diff")
local decoration = require("acp.ui.decoration")

local M = {}

local one_line = text_layout.one_line
local render_text = text_layout.render_text
local truncate_width = text_layout.truncate_width

local function tool_status_label(status, awaiting)
  if awaiting == "approval" then
    return "waiting for approval"
  elseif awaiting == "answer" then
    return "waiting for an answer"
  end
  if status == "completed" then
    return "done"
  elseif status == "failed" then
    return "failed"
  elseif status == "cancelled" then
    return "cancelled"
  elseif status == "in_progress" then
    return "running"
  elseif status == "pending" then
    return "pending"
  end
  return ""
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

-- Human-readable label for a tool call, derived from the ACP tool kind. Falls
-- back to the tool name so unknown kinds still say something useful.
--
-- ACP has no `write` kind: an agent that creates or overwrites a file reports
-- it as `edit` and distinguishes the two only through its input. `tool_label`
-- therefore looks at the input as well, otherwise every file write would be
-- labelled "Edit" and the two operations would be indistinguishable.
local TOOL_LABELS = {
  execute = "Run Command",
  read = "Read",
  search = "Search",
  fetch = "Fetch",
  think = "Thinking",
  delete = "Delete",
  move = "Move",
  switch_mode = "Switch Mode",
}

local OLD_TEXT_KEYS = { "oldString", "old_string", "oldText", "old_text", "before" }
local NEW_TEXT_KEYS = { "newString", "new_string", "newText", "new_text", "content", "after" }
local PATCH_KEYS = { "patchText", "patch" }

---@param input any
---@param keys string[]
---@return boolean
local function has_key(input, keys)
  if type(input) ~= "table" then
    return false
  end
  for _, key in ipairs(keys) do
    if input[key] ~= nil then
      return true
    end
  end
  return false
end

---Whether an `edit` call replaces the whole file instead of part of it.
---
---The presence of the old text is the discriminator: a patch or a partial edit
---always carries it, while a write only carries the new content. Until the
---input arrives the agent's title is the only hint, so the generic tool names
---are recognised there.
---@param block AcpBlock
---@return boolean
local function is_write(block)
  local kind = block.tool_kind
  if kind == "write" then
    return true
  end
  if kind ~= "edit" then
    return false
  end
  if has_key(block.raw_input, PATCH_KEYS) or has_key(block.raw_input, OLD_TEXT_KEYS) then
    return false
  end
  if has_key(block.raw_input, NEW_TEXT_KEYS) then
    return true
  end
  local title = type(block.title) == "string" and block.title:lower() or ""
  return title == "write" or title == "create" or title == "write file" or title == "create file"
end

---@param block AcpBlock
---@return string
local function tool_label(block)
  local kind = block.tool_kind
  if kind == "edit" or kind == "write" then
    return is_write(block) and "Write" or "Edit"
  end
  if type(kind) == "string" and TOOL_LABELS[kind] then
    return TOOL_LABELS[kind]
  end
  if type(kind) == "string" and kind ~= "" then
    -- Unknown kind: present it like the known ones.
    return (kind:gsub("_", " "):gsub("^%l", string.upper))
  end
  -- No kind at all: the agent's own title is the best label available.
  return "Tool"
end

---Whether `rawOutput` is the only thing the card can show.
---
---A content item can carry no text at all (a `terminal` the client renders
---itself, or a diff). Counting items therefore said "there is content" while
---the body stayed empty. The rendered summary and the terminal buffer are the
---real signals.
---@param block AcpBlock
---@return boolean
local function can_show_raw_output(block)
  if block.terminal_output and block.terminal_output ~= "" then
    return false
  end
  local detail = block.detail
  return detail == nil or detail == ""
end

---Secondary descriptor shown after the label: the agent's own summary of what
---the call does, which is usually more specific than the kind.
---@param block AcpBlock
---@return string
local function tool_title(block)
  local title = block.title
  if type(title) == "string" and title ~= "" then
    -- Agents often wrap the title in backticks (`Edit `src/a.lua``); the card
    -- already renders it as a label, so the delimiters are noise.
    return one_line((title:gsub("^`+", ""):gsub("`+$", "")))
  end
  -- The agent's own tool name (Claude's `MultiEdit`, for example) is more
  -- specific than the protocol `name`, which may only say "Edit".
  if type(block.tool_name) == "string" and block.tool_name ~= "" then
    return one_line(block.tool_name)
  end
  if block.name and block.name ~= "" then
    return one_line(block.name)
  end
  return ""
end

---The full command an `execute` call ran, when the agent supplied one.
---
---The header carries the title as a one-line summary and truncates it to the
---panel width, which is exactly what makes a long shell command unreadable.
---`rawInput.command` is preferred over the title because it is the text that
---actually ran, not a rewritten summary; the title is the fallback for agents
---that do not send structured input.
---@param block AcpBlock
---@return string|nil
local function shell_command(block)
  if block.tool_kind ~= "execute" then
    return nil
  end
  local input = block.raw_input
  if type(input) == "table" then
    for _, key in ipairs({ "command", "cmd" }) do
      local value = input[key]
      if type(value) == "string" and vim.trim(value) ~= "" then
        return value
      end
    end
  elseif type(input) == "string" and vim.trim(input) ~= "" then
    return input
  end
  local title = block.title
  if type(title) == "string" and title ~= "" and one_line(title) ~= tool_label(block) then
    return one_line(title)
  end
  return nil
end

---Number of text lines a collapsed card is hiding.
---
---A collapsed card that hides output looks exactly like one with no output at
---all, so the header says how much is inside. Shell commands in particular are
---never auto-expanded (`execute` is not a file edit), which used to make their
---output completely invisible until the user thought to open them.
---@param block AcpBlock
---@return integer|nil lines
local function hidden_lines(block)
  if block.expanded then
    return nil
  end
  local text
  if type(block.terminal_output) == "string" and block.terminal_output ~= "" then
    text = block.terminal_output
  elseif type(block.detail) == "string" and block.detail ~= "" then
    text = block.detail
  elseif type(block.raw_output) == "string" and can_show_raw_output(block) then
    text = block.raw_output
  end
  if not text then
    return nil
  end
  return select(2, text:gsub("\n", "")) + 1
end

function M.render_tool(block, ctx)
  local ic = ctx.icons
  local glyph, glyph_hl = tool_icon(block, ic)
  local caret = block.expanded and ic.chevron_down or ic.chevron_right
  local tag = tool_label(block)
  local title = tool_title(block)
  local status = tool_status_label(block.status, block.awaiting)
  local hidden = hidden_lines(block)
  -- `Run Command · grep ... · done`. A title that merely repeats the label is
  -- dropped, and a title that starts with it keeps only the remainder, so
  -- `Read` + `Read src/auth.lua` reads as `Read · src/auth.lua` rather than
  -- losing the filename.
  local parts = { tag }
  if title ~= "" then
    local lower_tag = tag:lower()
    local lower_title = title:lower()
    if lower_title == lower_tag then
      -- Identical: keep just the label.
    elseif lower_title:sub(1, #lower_tag + 1) == lower_tag .. " " then
      parts[#parts + 1] = title:sub(#tag + 2)
    else
      parts[#parts + 1] = title
    end
  end

  local label = string.format("%s %s %s", caret, glyph, table.concat(parts, " · "))

  -- The suffix is built before the label is truncated, so the label leaves room
  -- for what is actually there rather than for a guess: a fixed reserve either
  -- overflows on a long subagent title or truncates the label for space that
  -- was never used.
  --
  -- The title is agent supplied and unbounded, so it is fitted to what the row
  -- leaves over and shrinks instead of pushing the header past the panel.
  local function build_suffix(child_title_)
    local meta = {}
    if child_title_ then
      meta[#meta + 1] = "subagent: " .. child_title_
    end
    if status ~= "" then
      meta[#meta + 1] = status
    end
    -- Tell the user there is something inside, and whether it succeeded. A
    -- collapsed card with hidden output otherwise reads as an empty call.
    if hidden then
      meta[#meta + 1] = string.format("%d line%s", hidden, hidden == 1 and "" or "s")
      if block.terminal_exit ~= nil and block.terminal_exit ~= 0 then
        meta[#meta + 1] = string.format("exit %d", block.terminal_exit)
      end
    end
    return #meta > 0 and ("  " .. table.concat(meta, " · ")) or ""
  end

  local child_title = block.child and block.child.title and one_line(block.child.title) or nil
  local suffix = build_suffix(child_title)
  if child_title then
    -- Shrink the title until the whole row fits. Measuring the assembled row
    -- rather than predicting its width keeps this correct for any combination
    -- of icon widths, separators and status text.
    local function row_width()
      return vim.api.nvim_strwidth(label) + vim.api.nvim_strwidth(suffix)
    end
    for _ = 1, 8 do
      if row_width() <= ctx.width then
        break
      end
      local current = vim.api.nvim_strwidth(child_title)
      if current <= 4 then
        break
      end
      local excess = row_width() - ctx.width
      child_title = truncate_width(child_title, math.max(3, current - excess - 1)) .. ic.more
      suffix = build_suffix(child_title)
    end
  end

  -- A shell command can be hundreds of columns long. The header is a summary;
  -- the full text is in the card body, so truncate to exactly what the panel
  -- leaves once the suffix is accounted for. Clamping to a fixed floor here
  -- would let a narrow panel be overflowed by the floor itself.
  local max_label = ctx.width - vim.api.nvim_strwidth(suffix)
  if vim.api.nvim_strwidth(label) > max_label then
    label = truncate_width(label, math.max(1, max_label - 1)) .. ic.more
  end

  local caret_end = #caret
  local glyph_start = caret_end + 1
  local glyph_end = glyph_start + #glyph
  local tag_start = glyph_end + 1
  local segments = {
    { s = 0, e = caret_end, group = "AcpSeparator" },
    { s = glyph_start, e = glyph_end, group = glyph_hl },
    -- Quiet by default: the header names the call, it is not the important part
    -- of the transcript. `AcpToolTitle` is a muted tone rather than a link to
    -- `Function`, which used to make long commands glare.
    { s = tag_start, e = -1, group = "AcpToolTag" },
  }
  if #parts > 1 then
    local shown_title = parts[2]
    local title_offset = #caret + 1 + #glyph + 1 + #tag + 3
    local available = #label - title_offset
    if available > 0 then
      local end_col = title_offset + math.min(#shown_title, available)
      segments[#segments + 1] = { s = title_offset, e = end_col, group = "AcpToolTitle" }
    end
  end

  if suffix ~= "" then
    segments[#segments + 1] = { s = #label, e = -1, group = "AcpMuted" }
  end
  local out = {
    { text = label .. suffix, segments = segments },
  }

  -- Card body: only when expanded and there is something to show.
  local body_lines = {}
  if block.expanded then
    -- A shell command is only ever visible in the header, where it is fitted to
    -- the panel and truncated. The expanded card repeats it in full, so a long
    -- command can actually be read and copied.
    local command = shell_command(block)
    if command then
      local command_lines = vim.split(command:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", {
        plain = true,
        trimempty = true,
      })
      for index, line in ipairs(command_lines) do
        local prompt = index == 1 and "$ " or "  "
        body_lines[#body_lines + 1] = {
          text = prompt .. line,
          segments = {
            { s = 0, e = #prompt, group = "AcpMuted" },
            { s = #prompt, e = -1, group = "AcpMdCode" },
          },
        }
      end
      if block.detail and block.detail ~= "" then
        -- Separate the command from its output; without the gap the first
        -- output line reads as part of the command.
        body_lines[#body_lines + 1] = { text = "", segments = nil }
      end
    end
  end
  if block.detail and block.detail ~= "" then
    block._md_detail = block._md_detail or {}
    -- No base highlight group: card body text must inherit the card's own
    -- background. Any group carrying a background would repaint over it.
    for _, line in ipairs(render_text(block.detail, nil, ctx.width - 4, block._md_detail)) do
      body_lines[#body_lines + 1] = line
    end
  end
  -- Terminal output that only travelled in `_meta` (pi, and Claude once it
  -- advertises `_meta.terminal_output`). Without this the card showed nothing
  -- for a shell command that plainly ran.
  if block.expanded and block.terminal_output and block.terminal_output ~= "" then
    if #body_lines > 0 then
      body_lines[#body_lines + 1] = { text = "", segments = nil }
    end
    local output = block.terminal_output:gsub("\r\n", "\n"):gsub("\r", "\n")
    for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
      body_lines[#body_lines + 1] = {
        text = line,
        segments = { { s = 0, e = -1, group = "AcpMdCode" } },
      }
    end
  end
  if block.expanded and block.terminal_exit ~= nil then
    local signal = block.terminal_signal
    local text = signal and string.format("exited with signal %s", tostring(signal))
      or string.format("exited with %d", block.terminal_exit)
    body_lines[#body_lines + 1] = {
      text = text,
      segments = { { s = 0, e = -1, group = block.terminal_exit == 0 and "AcpMuted" or "AcpToolError" } },
    }
  end
  if block.status == "failed" and block.raw_output then
    local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
    for _, line in ipairs(render_text(dump, "AcpToolError", ctx.width - 4)) do
      body_lines[#body_lines + 1] = line
    end
  elseif block.raw_output and can_show_raw_output(block) then
    -- An agent that reports only structured output (no renderable text) would
    -- otherwise show an empty card. Checking the rendered text rather than the
    -- number of content items matters: a `terminal` item carries no text, and
    -- counting it used to hide the output that was actually there.
    local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
    if dump ~= "" then
      for _, line in ipairs(render_text("```\n" .. dump .. "\n```", nil, ctx.width - 4)) do
        body_lines[#body_lines + 1] = line
      end
    end
  end

  -- The change itself, for the tools that edit files. It sits after the
  -- agent's own summary so the card reads "what happened, then what changed".
  local diffed = false
  if block.expanded then
    local opts = vim.tbl_extend("force", {}, ctx.diff or {})
    opts.summary = block.detail
    opts.cwd = ctx.cwd
    opts.width = math.max(1, ctx.width - 4)
    opts.lazy_syntax = ctx.lazy_syntax
    opts.max_rows = (ctx.diff or {}).max_syntax_rows
    local entries = diff_layout.from_block(block)
    if #entries > 0 then
      -- Computing a diff is O(lines) in xdiff, so the result is cached on the
      -- block and only recomputed when the payload or the context changes. A
      -- streaming tick that touches unrelated fields reuses it.
      local sig = diff_layout.signature(block, opts)
      local cached = block._diff_cache
      if not cached or cached.sig ~= sig then
        local lines = diff_layout.lines(entries, opts)
        -- Rows are static for a given payload: freeze them so a later render
        -- cannot mutate shared tables.
        cached = { sig = sig, lines = lines }
        block._diff_cache = cached
      end
      if #cached.lines > 0 then
        diffed = true
        if #body_lines > 0 then
          -- A rule keeps the summary from reading as part of the diff.
          local rule_width = math.max(1, ctx.width - 4)
          body_lines[#body_lines + 1] = {
            text = string.rep("─", rule_width),
            segments = { { s = 0, e = -1, group = "AcpDiffMeta" } },
          }
        end
        for _, line in ipairs(cached.lines) do
          body_lines[#body_lines + 1] = line
        end
      end
    end
  end

  -- Locations are already shown as the diff's file header, so they are only
  -- listed when no diff was drawn.
  local locations = diffed and {} or (block.locations or {})
  if block.expanded and (#body_lines > 0 or #locations > 0) then
    -- The card is padded so the background forms a solid block rather than
    -- hugging the text. Width is the panel width minus nothing: `hl_eol` fills
    -- the remaining cells, so the padding only needs to exist.
    out[#out + 1] = { text = "  ", bg = "AcpCardBg", segments = {} }
    for _, line in ipairs(body_lines) do
      out[#out + 1] = {
        text = "  " .. line.text,
        segments = vim.tbl_map(function(seg)
          return { s = seg.s + 2, e = seg.e >= 0 and seg.e + 2 or seg.e, group = seg.group, conceal = seg.conceal }
        end, line.segments or {}),
        -- A diff row brings its own line-wide background; the card's surface
        -- would otherwise paint over it.
        bg = line.bg or "AcpCardBg",
        source = line.source,
        decorations = decoration.shift(line.decorations, 2),
      }
    end
    for _, loc in ipairs(locations) do
      local rel = one_line(loc.path or "")
      if ctx.cwd and vim.startswith(rel, ctx.cwd .. "/") then
        rel = rel:sub(#ctx.cwd + 2)
      end
      out[#out + 1] = {
        text = string.format("  %s%s", rel, loc.line and (":" .. loc.line) or ""),
        segments = { { s = 2, e = -1, group = "AcpLink" } },
        location = loc,
        bg = "AcpCardBg",
      }
    end
    out[#out + 1] = { text = "  ", bg = "AcpCardBg", segments = {} }
  elseif block.detail and block.detail ~= "" then
    -- Collapsed: one muted preview line, as before.
    local first = block.detail:match("([^\r\n]*)") or ""
    if first ~= "" then
      local maxw = math.max(10, ctx.width - 8)
      if vim.api.nvim_strwidth(first) > maxw then
        first = truncate_width(first, maxw - vim.api.nvim_strwidth(ic.more)) .. ic.more
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

return M
