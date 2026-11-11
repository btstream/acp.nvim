-- Writing transcript layouts into the chat buffer.
--
-- Owns the two namespaces, the line diff, inline highlights and line-wide
-- background extmarks. It does not know where the lines came from.
local M = {}

local ns = vim.api.nvim_create_namespace("acp_chat")
-- Line-wide backgrounds (code blocks, tool cards) live in their own namespace
-- so they can be repainted per rewritten range without touching the many
-- inline highlight extmarks.
local ns_bg = vim.api.nvim_create_namespace("acp_chat_bg")

local function set_lines(buf, first, last, lines)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, first, last, false, lines)
  vim.bo[buf].modifiable = false
  if not ok then
    error(err, 0)
  end
end

M.ns = ns
M.ns_bg = ns_bg

---Collect contiguous runs of lines sharing the same background group.
---
---Comparing these runs is how the chat view decides whether the painted
---backgrounds need repainting at all: streaming text inside a card changes
---lines but not the layout, so the common tick does no extmark work.
---@param meta table[]
---@return {s: integer, e: integer, group: string}[] runs, using 0-based rows
function M.background_runs(meta)
  local runs = {}
  local row = 0
  while row < #meta do
    local bg = meta[row + 1] and meta[row + 1].bg
    if bg then
      local stop = row
      while
        stop + 1 < #meta
        and meta[stop + 2]
        and meta[stop + 2].bg == bg
        and meta[stop + 2].block_id == meta[row + 1].block_id
      do
        stop = stop + 1
      end
      runs[#runs + 1] = { s = row, e = stop + 1, group = bg }
      row = stop + 1
    else
      row = row + 1
    end
  end
  return runs
end

---Paint (or repaint) every line background.
---
---`nvim_buf_clear_namespace` only drops extmarks whose *start* falls inside the
---given range, so a mark spanning several rows survives a partial clear and
---would paint stale rows. Backgrounds are therefore always cleared and redrawn
---as a whole; callers avoid the work when the runs did not change.
---@param buf integer
---@param runs {s: integer, e: integer, group: string}[]
function M.paint_backgrounds(buf, runs)
  vim.api.nvim_buf_clear_namespace(buf, ns_bg, 0, -1)
  for _, run in ipairs(runs) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_bg, run.s, 0, {
      end_row = run.e,
      end_col = 0,
      hl_group = run.group,
      hl_eol = true,
      hl_mode = "combine",
      priority = 50,
      end_right_gravity = false,
    })
  end
end

---@param a {s: integer, e: integer, group: string}[]|nil
---@param b {s: integer, e: integer, group: string}[]
---@return boolean
function M.runs_equal(a, b)
  if not a or #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.s ~= y.s or x.e ~= y.e or x.group ~= y.group then
      return false
    end
  end
  return true
end

---Apply inline highlight segments to one buffer row (1-based).
---@param buf integer
---@param index integer
---@param segments table[]
---@param text string
function M.highlight_line(buf, index, segments, text)
  local byte_len = #text
  for _, seg in ipairs(segments) do
    local s = math.max(0, math.min(seg.s or 0, byte_len))
    local e = seg.e
    if e == nil or e < 0 or e > byte_len then
      e = byte_len
    end
    if e > s then
      if seg.conceal then
        -- Markup delimiters stay in the text so byte offsets remain stable;
        -- conceal hides them instead. Requires 'conceallevel' >= 2.
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, index - 1, s, {
          end_col = e,
          conceal = "",
        })
      elseif seg.group then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, index - 1, s, {
          end_col = e,
          hl_group = seg.group,
          priority = 100,
        })
      end
      -- A segment without a group is intentionally left unhighlighted so it
      -- inherits whatever background is behind it (e.g. a card).
    end
  end
end

---Replace the whole buffer and repaint everything.
---@param buf integer
---@param lines string[]
---@param meta table[]
---@param full boolean
function M.replace(buf, lines, meta, full)
  set_lines(buf, 0, full and -1 or nil, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, entry in ipairs(meta) do
    if entry.segments then
      M.highlight_line(buf, i, entry.segments, lines[i])
    end
  end
end

---Write a layout, touching only the changed range.
---
---`old` mirrors the buffer, so it is only a valid diff base while it matches.
---When `full` is set the buffer is replaced outright.
---@param buf integer
---@param lines string[]
---@param meta table[]
---@param old string[]
---@param full boolean
---@return boolean changed
function M.write(buf, lines, meta, old, full)
  if full then
    old = {}
  end
  local prefix = 0
  local max_prefix = math.min(#old, #lines)
  while prefix < max_prefix and old[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  local max_suffix = math.min(#old, #lines) - prefix
  while suffix < max_suffix and old[#old - suffix] == lines[#lines - suffix] do
    suffix = suffix + 1
  end

  local first = prefix + 1
  local last = #lines - suffix -- inclusive, in new coordinates
  local changed = first <= last or #old ~= #lines

  if changed then
    -- `#old - suffix` is the exclusive end in the *cache's* coordinates. With
    -- an empty cache that is 0, and `set_lines(buf, 0, 0, ...)` inserts instead
    -- of replacing, leaving the previous transcript in place. Use -1 ("end of
    -- buffer") for a full rewrite.
    local end_line = full and -1 or (#old - suffix)
    set_lines(buf, prefix, end_line, vim.list_slice(lines, first, last))

    if full then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    else
      -- Clear the rewritten range in *new* buffer coordinates. Using the old
      -- end here was a bug: when a block changes height the buffer gets shorter
      -- or longer, so the old offset reaches past the rewritten region and
      -- wipes the extmarks of every line that shifted into it.
      vim.api.nvim_buf_clear_namespace(buf, ns, prefix, last)
    end
    for i = first, last do
      local entry = meta[i]
      if entry and entry.segments then
        M.highlight_line(buf, i, entry.segments, lines[i])
      end
    end
  end
  return changed
end

function M.write_sliced(buf, lines, meta, old, full, chunk_rows)
  return coroutine.create(function()
    -- Buffer writes can be refused while text is locked (for example a scheduled
    -- slice that happens to run during a redraw). Retry on the next slice
    -- instead of abandoning a half-written transcript.
    local function guarded(fn)
      local attempts = 0
      while true do
        local ok, err = pcall(fn)
        if ok then
          return
        end
        attempts = attempts + 1
        if attempts > 20 or not tostring(err):find("E565", 1, true) then
          error(err, 0)
        end
        coroutine.yield()
      end
    end
    if full then
      old = {}
    end
    local prefix = 0
    local max_prefix = math.min(#old, #lines)
    while prefix < max_prefix and old[prefix + 1] == lines[prefix + 1] do
      prefix = prefix + 1
    end
    local suffix = 0
    local max_suffix = math.min(#old, #lines) - prefix
    while suffix < max_suffix and old[#old - suffix] == lines[#lines - suffix] do
      suffix = suffix + 1
    end
    local first = prefix + 1
    local last = #lines - suffix
    local changed = first <= last or #old ~= #lines
    if not changed then
      return false
    end
    local end_line = full and -1 or (#old - suffix)
    local stop = math.min(last, first + chunk_rows - 1)
    guarded(function()
      set_lines(buf, prefix, end_line, vim.list_slice(lines, first, stop))
    end)
    coroutine.yield()
    for start = stop + 1, last, chunk_rows do
      guarded(function()
        set_lines(buf, start - 1, start - 1, vim.list_slice(lines, start, math.min(last, start + chunk_rows - 1)))
      end)
      coroutine.yield()
    end
    guarded(function()
      vim.api.nvim_buf_clear_namespace(buf, ns, full and 0 or prefix, full and -1 or last)
    end)
    for i = first, last, chunk_rows do
      local stop = math.min(last, i + chunk_rows - 1)
      guarded(function()
        for row = i, stop do
          local entry = meta[row]
          if entry and entry.segments then
            M.highlight_line(buf, row, entry.segments, lines[row])
          end
        end
      end)
      coroutine.yield()
    end
    vim.bo[buf].modifiable = false
    return changed
  end)
end

---Write a layout with an explicit row budget between yields.
---@return coroutine
function M.write_chunked(buf, lines, meta, old, full, chunk_rows)
  return M.write_sliced(buf, lines, meta, old, full, math.max(1, chunk_rows or 500))
end

---Repaint backgrounds if their geometry changed.
---@param buf integer
---@param previous table|nil
---@param meta table[]
---@param changed boolean
---@return table|nil runs current runs; nil when nothing was painted
function M.sync_backgrounds(buf, previous, meta, changed)
  local runs = M.background_runs(meta)
  if changed or not M.runs_equal(previous, runs) then
    M.paint_backgrounds(buf, runs)
    return runs
  end
  return previous
end

---Write a suffix layout that starts at `offset` (0-based rows).
---
---The prefix is left untouched. Lines are compared against the existing cache
---so only the changed middle of the suffix is rewritten, and backgrounds are
---reused when the extmarks already moved with the edits.
---@param buf integer
---@param lines string[]
---@param meta table[]
---@param old_lines string[]
---@param old_meta table[]
---@param offset integer
function M.write_suffix(buf, lines, meta, old_lines, old_meta, offset)
  local old_count = #old_lines
  local prefix, suffix = 0, 0
  local old_size = old_count - offset
  local function equal(old_row, new_row)
    return old_lines[old_row] == lines[new_row]
      and vim.deep_equal(old_meta[old_row] and old_meta[old_row].segments, meta[new_row] and meta[new_row].segments)
  end
  while prefix < math.min(old_size, #lines) and equal(offset + prefix + 1, prefix + 1) do
    prefix = prefix + 1
  end
  while suffix < math.min(old_size, #lines) - prefix and equal(old_count - suffix, #lines - suffix) do
    suffix = suffix + 1
  end
  local last = #lines - suffix
  if prefix < last or old_size ~= #lines then
    set_lines(buf, offset + prefix, old_count - suffix, vim.list_slice(lines, prefix + 1, last))
    vim.api.nvim_buf_clear_namespace(buf, ns, offset + prefix, offset + last)
    for i = prefix + 1, last do
      if meta[i] and meta[i].segments then
        M.highlight_line(buf, offset + i, meta[i].segments, lines[i])
      end
    end
  end

  local runs, actual = M.background_runs(meta), {}
  -- Extmarks already move with edits. Reuse them when their actual post-edit
  -- geometry matches the new layout (e.g. prose streaming after a code fence).
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_bg, { offset, 0 }, -1, { details = true })) do
    actual[#actual + 1] = { s = mark[2] - offset, e = mark[4].end_row - offset, group = mark[4].hl_group }
  end
  if not M.runs_equal(actual, runs) then
    vim.api.nvim_buf_clear_namespace(buf, ns_bg, offset, -1)
    for _, run in ipairs(runs) do
      vim.api.nvim_buf_set_extmark(buf, ns_bg, offset + run.s, 0, {
        end_row = offset + run.e,
        end_col = 0,
        hl_group = run.group,
        hl_eol = true,
        hl_mode = "combine",
        priority = 50,
        end_right_gravity = false,
      })
    end
  end
end

return M
