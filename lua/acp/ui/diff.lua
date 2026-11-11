-- Diff rendering for file-modifying tool calls.
--
-- Agents report edits two ways: an authoritative `diff` content item (with the
-- old and new file text) in the completed update, and the tool's own input
-- while it is still running. The second form is what makes a card show the
-- change while the turn is streaming instead of only after it finishes.
local M = {}

local diff_hl = require("acp.ui.diff_hl")
local CodeHL = require("acp.ui.code_hl")

-- Byte ceiling before xdiff runs. Past this a "too large" notice is cheaper and
-- clearer than turning a multi-megabyte rewrite into transcript rows.
local DEFAULT_MAX_BYTES = 512 * 1024
local DEFAULT_MAX_LINES = 800
local DEFAULT_CONTEXT = 3

---@class AcpDiffEntry
---@field path string
---@field oldText string
---@field newText string
---@field synthetic boolean|nil derived from rawInput, not an authoritative diff
---@field patch string|nil raw unified patch text (patch tool)

---@param value any
---@return string|nil
local function as_string(value)
  return type(value) == "string" and value or nil
end

---First string among `keys` in `t`.
---@param t table
---@param keys string[]
---@return string|nil
local function pick(t, keys)
  for _, key in ipairs(keys) do
    local value = as_string(t[key])
    if value ~= nil then
      return value
    end
  end
  return nil
end

local PATH_KEYS = { "path", "filePath", "file_path", "filename" }
local OLD_KEYS = { "oldString", "old_string", "oldText", "old_text", "before" }
local NEW_KEYS = { "newString", "new_string", "newText", "new_text", "content", "after" }

---Authoritative diffs from the update's content.
---@param block AcpBlock
---@return AcpDiffEntry[]
local function from_content(block)
  local out = {}
  for _, item in ipairs(block.content or {}) do
    if type(item) == "table" and item.type == "diff" then
      local new = as_string(item.newText)
      if new ~= nil then
        out[#out + 1] = {
          path = as_string(item.path) or "",
          oldText = as_string(item.oldText) or "",
          newText = new,
        }
      end
    end
  end
  return out
end

---A live diff derived from the tool input, so the card can render while the
---call is still in progress.
---
---The ACP kind is not a reliable discriminator here: OpenCode reports its
---`write` tool as `edit` and distinguishes the two only by the input shape. A
---missing `oldString` therefore means the whole file is new content.
---@param block AcpBlock
---@return AcpDiffEntry[]
local function from_raw_input(block)
  local input = block.raw_input
  if type(input) ~= "table" then
    return {}
  end
  local kind = block.tool_kind
  local path = pick(input, PATH_KEYS) or ""

  if kind == "patch" and as_string(input.patchText) then
    return { { path = path, oldText = "", newText = "", patch = input.patchText, synthetic = true } }
  end

  if kind == "write" or kind == "edit" then
    local new = pick(input, NEW_KEYS)
    if new == nil then
      return {}
    end
    local old = pick(input, OLD_KEYS)
    -- Without the previous content a write can only be shown as all additions;
    -- it is labelled as such so the missing removals are not read as "nothing
    -- was deleted".
    return { { path = path, oldText = old or "", newText = new, synthetic = true } }
  end

  return {}
end

---Diff entries for a tool block.
---
---The authoritative content wins; only when it is missing does the live input
---stand in for it. Returns an empty list when there is nothing to show.
---@param block AcpBlock
---@return AcpDiffEntry[]
function M.from_block(block)
  local entries = from_content(block)
  if #entries > 0 then
    return entries
  end
  return from_raw_input(block)
end

---Split unified diff output into rows.
---@param text string
---@return {kind: string, text: string}[]
local function parse_unified(text)
  local rows = {}
  local lines = vim.split(text, "\n", { plain = true })
  -- A trailing newline produces a final empty element that is not a row.
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  for _, line in ipairs(lines) do
    local head = line:sub(1, 1)
    if line:sub(1, 2) == "@@" then
      rows[#rows + 1] = { kind = "hunk", text = line }
    elseif head == "\\" then
      -- `\ No newline at end of file`
      rows[#rows + 1] = { kind = "meta", text = line }
    elseif head == "+" and line:sub(1, 3) ~= "+++" then
      rows[#rows + 1] = { kind = "add", text = line:sub(2) }
    elseif head == "-" and line:sub(1, 3) ~= "---" then
      rows[#rows + 1] = { kind = "remove", text = line:sub(2) }
    elseif head == " " then
      rows[#rows + 1] = { kind = "context", text = line:sub(2) }
    else
      rows[#rows + 1] = { kind = "meta", text = line }
    end
  end
  return rows
end

---Rows for one entry, before the display cap is applied.
---@param entry AcpDiffEntry
---@param context integer
---@return {kind: string, text: string}[]
local function entry_rows(entry, context)
  if entry.patch then
    return parse_unified(entry.patch)
  end
  local ok, unified = pcall(vim.diff, entry.oldText, entry.newText, {
    result_type = "unified",
    ctxlen = context,
  })
  if not ok or type(unified) ~= "string" then
    return { { kind = "meta", text = "unable to compute diff" } }
  end
  local rows = parse_unified(unified)
  if entry.synthetic then
    -- A live preview is not the file's final text, so "no newline at end of
    -- file" says nothing useful and only adds noise to a fresh write.
    local kept = {}
    for _, row in ipairs(rows) do
      if row.kind ~= "meta" then
        kept[#kept + 1] = row
      end
    end
    rows = kept
  end
  return rows
end

---Whether an entry has a visible change, so an unchanged write still shows its
---content but an identical edit does not open an empty card.
---@param entry AcpDiffEntry
---@param context integer
---@return boolean
local function has_changes(entry, context)
  for _, row in ipairs(entry_rows(entry, context)) do
    if row.kind == "add" or row.kind == "remove" then
      return true
    end
  end
  return false
end

---Path shown in a file header, relative to the session directory when possible.
---@param path string
---@param cwd string|nil
---@return string
local function display_path(path, cwd)
  if path == "" then
    return "file"
  end
  if cwd and cwd ~= "" and vim.startswith(path, cwd .. "/") then
    return path:sub(#cwd + 2)
  end
  return path
end

---Display lines for a list of diffs.
---
---Rows are card-body rows: the caller prepends the card margin, exactly like
---the other body lines. `bg` is the line-wide highlight group; text rows keep
---it `nil` so the card's own background shows through.
---@param entries AcpDiffEntry[]
---@param opts {context?: integer, max_lines?: integer, max_bytes?: integer, summary?: string, cwd?: string, syntax?: boolean, max_rows?: integer, width?: integer}|nil
---@return AcpRenderedLine[]
function M.lines(entries, opts)
  opts = opts or {}
  local context = opts.context or DEFAULT_CONTEXT
  local max_lines = opts.max_lines or DEFAULT_MAX_LINES
  local max_bytes = opts.max_bytes or DEFAULT_MAX_BYTES

  local parsed = {}
  local hunks = 0
  for _, entry in ipairs(entries) do
    local bytes = (type(entry.oldText) == "string" and #entry.oldText or 0)
      + (type(entry.newText) == "string" and #entry.newText or 0)
    if type(entry.patch) == "string" then
      bytes = #entry.patch
    end
    if bytes > max_bytes then
      parsed[#parsed + 1] = {
        entry = entry,
        rows = {
          { kind = "meta", text = string.format("diff too large to display (%d KiB)", math.floor(bytes / 1024)) },
        },
      }
    else
      local rows = entry_rows(entry, context)
      -- An edit whose two sides are identical has nothing to show; drawing only
      -- context lines would look like a change that does not exist.
      if entry.patch or has_changes(entry, context) then
        for _, row in ipairs(rows) do
          if row.kind == "hunk" then
            hunks = hunks + 1
          end
        end
        parsed[#parsed + 1] = { entry = entry, rows = rows }
      end
    end
  end

  if #parsed == 0 then
    return {}
  end

  -- A single hunk reads better without a `@@` row: the summary above it already
  -- says what changed. The header is only needed to separate several hunks.
  local show_hunks = hunks > 1
  local show_files = #parsed > 1

  local out = {}
  local emitted = 0
  local skipped = 0
  local width = math.max(1, opts.width or 40)
  local first_file = true

  -- Each file is rendered as its own section so syntax highlighting can parse
  -- one language at a time. A multi-file patch is the only case with more than
  -- one section.
  local function flush(section)
    if section then
      diff_hl.attach(section.lines, section.file, {
        enabled = opts.syntax,
        max_rows = opts.max_rows,
      })
    end
  end

  local section
  for _, item in ipairs(parsed) do
    flush(section)
    section = { file = item.entry.path, lines = {} }

    local entry = item.entry
    local label = display_path(entry.path, opts.cwd)
    -- The old text is the discriminator, not the source: an edit reported only
    -- through `rawInput` still has both sides and is a real diff.
    if entry.oldText == "" and entry.newText ~= "" and not entry.patch then
      label = label .. " (new content)"
    end
    -- The header is needed to tell several files apart, and it is the only
    -- place the path appears when the agent's summary does not mention it.
    local shown = show_files
      or entry.synthetic
      or not opts.summary
      or not opts.summary:find(vim.fn.fnamemodify(entry.path, ":t"), 1, true)

    ---@param text string
    ---@param bg string|nil
    ---@param segments table[]|nil
    local function push(text, bg, segments)
      if emitted >= max_lines then
        skipped = skipped + 1
        return
      end
      emitted = emitted + 1
      local line = { text = text, bg = bg, segments = segments }
      out[#out + 1] = line
      section.lines[#section.lines + 1] = line
    end

    if shown then
      -- Several files in one patch need a visible boundary, otherwise the last
      -- row of one file reads as context for the next header.
      if not first_file then
        push(string.rep("─", width), nil, { { s = 0, e = -1, group = "AcpDiffMeta" } })
      end
      first_file = false
      push(label, nil, { { s = 0, e = -1, group = "AcpDiffFile" } })
    end
    for _, row in ipairs(item.rows) do
      if row.kind == "add" then
        push("+ " .. row.text, "AcpDiffAdd", { { s = 0, e = 2, group = "AcpDiffAddSign" } })
      elseif row.kind == "remove" then
        push("- " .. row.text, "AcpDiffDelete", { { s = 0, e = 2, group = "AcpDiffRemoveSign" } })
      elseif row.kind == "hunk" then
        if show_hunks then
          push(row.text, nil, { { s = 0, e = -1, group = "AcpDiffHunk" } })
        end
      elseif row.kind == "context" then
        push("  " .. row.text, nil, nil)
      else
        push(row.text, nil, { { s = 0, e = -1, group = "AcpDiffMeta" } })
      end
    end
  end
  flush(section)

  if skipped > 0 then
    out[#out + 1] = {
      text = string.format("… (%d more lines)", skipped),
      segments = { { s = 0, e = -1, group = "AcpDiffMeta" } },
    }
  end

  return out
end

---Whether there is a rendering-relevant change between two snapshots.
---
---Used as the cache key: the rendered rows only depend on the file texts, the
---context width and the display caps, not on the panel geometry. The texts are
---hashed because two edits of the same length are still different edits, and a
---length-only key would keep showing the first one.
---@param block AcpBlock
---@param opts {context?: integer, max_lines?: integer, max_bytes?: integer}|nil
---@return string
function M.signature(block, opts)
  opts = opts or {}
  local parts = {
    tostring(opts.context or DEFAULT_CONTEXT),
    tostring(opts.max_lines or DEFAULT_MAX_LINES),
    tostring(opts.max_bytes or DEFAULT_MAX_BYTES),
    -- Syntax colouring is part of the rendered output and its cache generation
    -- advances on `ColorScheme`, so toggling or re-theming invalidates the rows.
    tostring(opts.syntax ~= false),
    tostring(opts.max_rows or 0),
    tostring(CodeHL.generation),
    -- Both decide whether the file header is printed, so the cache has to see
    -- them too.
    opts.summary or "",
    opts.cwd or "",
    tostring(opts.width or 0),
  }
  for _, entry in ipairs(M.from_block(block)) do
    parts[#parts + 1] = table.concat({
      entry.path or "",
      vim.fn.sha256(entry.oldText),
      vim.fn.sha256(entry.newText),
      entry.patch and vim.fn.sha256(entry.patch) or "-",
      entry.synthetic and "s" or "a",
    }, ":")
  end
  return table.concat(parts, "|")
end

return M
