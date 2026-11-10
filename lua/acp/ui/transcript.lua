-- Transcript layout: session blocks -> display lines, metadata and mapping.
--
-- Pure computation over a session projection: no buffers, windows or extmarks.
-- `acp.ui.chat` owns the view and hands the result to `acp.ui.buffer_renderer`.
local blocks = require("acp.ui.blocks")
local session_state = require("acp.session.state")

local M = {}

---Length of a string field, tolerating JSON null (vim.NIL) and other types.
---@param value any
---@return integer
local function len(value)
  return type(value) == "string" and #value or 0
end

local EMPTY_HINT = "Start a conversation with the agent."
local TRIMMED_HINT = "Earlier messages omitted by local memory limits."

---Cheap change detector for a block.
---
---Replaces a signature string built with `table.concat` + `tostring` for every
---block on every render tick. Fields are compared directly instead, which
---avoids the allocations while staying just as precise.
---@param block AcpBlock
---@return table
local function block_signature(block)
  -- `raw_output` is only printed for failed tools; inspecting it on every tick
  -- for every block would cost more than the render itself.
  local raw_len = -1
  if block.raw_output ~= nil and block.status == "failed" then
    local dump = type(block.raw_output) == "string" and block.raw_output or vim.inspect(block.raw_output)
    raw_len = #dump
  end
  -- A shell command is rendered into the card body when expanded, so a later
  -- update that only fills `rawInput` has to invalidate the cached lines.
  local command_len = -1
  if block.tool_kind == "execute" then
    local input = block.raw_input
    if type(input) == "string" then
      command_len = #input
    elseif type(input) == "table" then
      command_len = #(
        type(input.command) == "string" and input.command
        or type(input.cmd) == "string" and input.cmd
        or ""
      )
    end
    -- Diffs come from `content` or, while the call runs, from `rawInput`. The
    -- signature has to cover both or a card would keep showing its first
    -- (empty) state until the block object was replaced.
  end
  local diff_len = -1
  if
    block.kind == "tool" and (block.tool_kind == "edit" or block.tool_kind == "write" or block.tool_kind == "patch")
  then
    diff_len = 0
    for _, item in ipairs(block.content or {}) do
      if type(item) == "table" and item.type == "diff" then
        diff_len = diff_len + len(item.oldText) + len(item.newText)
      end
    end
    local input = block.raw_input
    if type(input) == "table" then
      for _, key in ipairs({ "oldString", "oldText", "newString", "newText", "content", "patchText" }) do
        if type(input[key]) == "string" then
          diff_len = diff_len + #input[key]
        end
      end
    end
  end
  return {
    kind = block.kind,
    status = block.status,
    expanded = block.expanded,
    text_len = len(block.text),
    title_len = len(block.title),
    detail_len = len(block.detail),
    name_len = len(block.name),
    tool_kind = block.tool_kind,
    severity = block.severity,
    entries = type(block.entries) == "table" and #block.entries or 0,
    attachments = type(block.attachments) == "table" and #block.attachments or 0,
    locations = type(block.locations) == "table" and #block.locations or 0,
    child_title = type(block.child) == "table" and block.child.title or nil,
    raw_len = raw_len,
    command_len = command_len,
    diff_len = diff_len,
    -- Plan entries render both their text and their status, so a same-count
    -- update has to be detected.
    plan = type(block.entries) == "table" and vim.inspect(block.entries) or nil,
  }
end

---Whether two signatures describe the same render output.
---@param a table|nil
---@param b table
---@return boolean
local function signature_equal(a, b)
  if not a then
    return false
  end
  for k, v in pairs(b) do
    if a[k] ~= v then
      return false
    end
  end
  return true
end

---Build the render context shared by both paths.
---@param session AcpSessionState
---@param view table
---@return table
local function context(session, view)
  return {
    icons = view.icons,
    width = view.width,
    cwd = session.cwd,
    show_thoughts = view.show_thoughts,
    thoughts = view.thoughts,
    diff = view.diff,
  }
end

---Append one separator row set for a turn boundary.
local function append_separator(lines, meta, ctx, form, turn)
  for _, line in ipairs(blocks.render_separator(ctx, { form = form, turn = turn })) do
    lines[#lines + 1] = line.text or ""
    meta[#meta + 1] = { kind = "separator", segments = line.segments, bg = line.bg }
  end
end

---Render the whole transcript.
---@param session AcpSessionState
---@param view table {icons, width, show_thoughts, thoughts, config, cache}
---@param opts {force: boolean|nil}
---@return table layout
function M.full(session, view, opts)
  local ctx = context(session, view)
  local cache = opts.force and {} or view.cache
  local lines, meta = {}, {}
  if session.trimmed then
    lines[1] = TRIMMED_HINT
    meta[1] = { kind = "notice", segments = { { s = 0, e = -1, group = "AcpMuted" } } }
  end

  local starts = {}
  local seen = {}
  local new_cache = {}
  local separator = view.config.ui.separator or {}
  local show_separator = separator.form ~= "off"
  -- A user block opens a turn, so counting them numbers the turns even for a
  -- replayed session, where no `begin_turn` ran for the replayed messages.
  local turn = 0

  local row_starts, turn_counts, render_order = {}, {}, {}
  for index, block in ipairs(session.blocks) do
    row_starts[index], turn_counts[index], render_order[index] = #lines + 1, turn, block.id
    seen[block.id] = true
    -- The divider belongs to the transcript, not to any block: it is inserted
    -- between two turns rather than appended to one of them, so it never shows
    -- up as a block the cursor can land on.
    if block.kind == "user" then
      turn = turn + 1
      if show_separator and turn > 1 then
        append_separator(lines, meta, ctx, separator.form, turn)
      end
    end
    -- Join buffered stream chunks before measuring the signature.
    session_state.block_text(block)
    local sig = block_signature(block)
    local entry = cache[block.id]
    if
      not entry
      or entry.block ~= block
      or (session.tracked and entry.revision ~= block._revision)
      or not signature_equal(entry.sig, sig)
    then
      entry = { block = block, sig = sig, revision = block._revision, lines = blocks.render_block(block, ctx) }
      -- A buffer line cannot contain a newline. Agent supplied text may, so
      -- fold it once here; cached lines are already clean.
      for _, line in ipairs(entry.lines) do
        local text = line.text
        if type(text) ~= "string" or text:find("[\r\n]") then
          line.text = (type(text) == "string" and text or tostring(text or "")):gsub("[\r\n]", " ")
        end
      end
    end
    new_cache[block.id] = entry
    starts[block.id] = #lines + 1
    for _, line in ipairs(entry.lines) do
      lines[#lines + 1] = line.text or ""
      meta[#meta + 1] = {
        block_id = block.id,
        kind = block.kind,
        status = block.status,
        location = line.location,
        segments = line.segments,
        bg = line.bg,
      }
    end
  end

  -- Drop cache entries for removed blocks.
  for id in pairs(cache) do
    if not seen[id] then
      new_cache[id] = nil
    end
  end

  if #lines == 0 then
    lines = { EMPTY_HINT }
    meta = { { kind = "empty" } }
  end

  return {
    lines = lines,
    meta = meta,
    starts = starts,
    row_starts = row_starts,
    turn_counts = turn_counts,
    render_order = render_order,
    cache = new_cache,
    turns = turn,
    offset = 0,
  }
end

---Render only the suffix starting at `first_block`.
---
---Stable prefixes keep their strings, metadata tables and extmarks unchanged;
---the returned lines begin at `offset` (0-based rows before the suffix).
---@param session AcpSessionState
---@param view table
---@param first_block integer
---@return table layout
function M.dirty(session, view, first_block)
  local ctx = context(session, view)
  local offset = first_block == 1 and 0 or ((view.row_starts[first_block] or (#view.lines_cache + 1)) - 1)
  local lines, meta, present = {}, {}, {}
  local turn = first_block == 1 and 0 or (view.turn_counts[first_block] or view.render_turns or 0)
  if first_block == 1 and session.trimmed then
    lines[1] = TRIMMED_HINT
    meta[1] = { kind = "notice", segments = { { s = 0, e = -1, group = "AcpMuted" } } }
  end

  local separator = view.config.ui.separator or {}
  local removed = {}
  for i = first_block, #view.render_order do
    removed[#removed + 1] = view.render_order[i]
  end
  for i = first_block, #session.blocks do
    local block = session.blocks[i]
    present[block.id] = true
    view.row_starts[i], view.turn_counts[i], view.render_order[i] = offset + #lines + 1, turn, block.id
    if block.kind == "user" then
      turn = turn + 1
      if separator.form ~= "off" and turn > 1 then
        append_separator(lines, meta, ctx, separator.form, turn)
      end
    end
    local entry = view.cache[block.id]
    if not entry or entry.block ~= block or entry.revision ~= block._revision then
      session_state.block_text(block)
      entry = { block = block, revision = block._revision, lines = blocks.render_block(block, ctx) }
      view.cache[block.id] = entry
    end
    view.line_starts[block.id] = offset + #lines + 1
    for _, line in ipairs(entry.lines) do
      lines[#lines + 1] = (line.text or ""):gsub("[\r\n]", " ")
      meta[#meta + 1] = {
        block_id = block.id,
        kind = block.kind,
        status = block.status,
        location = line.location,
        segments = line.segments,
        bg = line.bg,
      }
    end
  end
  for _, id in ipairs(removed) do
    if not present[id] then
      view.cache[id], view.line_starts[id] = nil, nil
    end
  end
  for i = #view.render_order, #session.blocks + 1, -1 do
    view.render_order[i], view.row_starts[i], view.turn_counts[i] = nil, nil, nil
  end
  -- A zero-line thought-only session uses the normal empty hint path.
  if offset == 0 and #lines == 0 then
    lines, meta = { EMPTY_HINT }, { { kind = "empty" } }
  end

  return {
    lines = lines,
    meta = meta,
    offset = offset,
    turns = turn,
  }
end

M.signature = block_signature
M.signature_equal = signature_equal

return M
