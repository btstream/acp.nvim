-- Build the prompt sent for an inline edit.
--
-- Visual selections are described as a byte range the agent must stay inside.
-- Normal mode has no selection: the request itself decides what to change, so
-- no "insert only here" instruction is emitted and the result is not filtered
-- down to a point (see `result.plan`).
local M = {}

---Expand the context excerpt around the focus lines without exceeding the
---configured byte budget.
---@param lines string[]
---@param first integer 1-based
---@param last integer 1-based
---@param budget integer
---@return integer start, integer finish
local function excerpt_range(lines, first, last, budget)
  local start, finish = first, last
  local used = 0
  while start > 1 and used + #lines[start - 1] + 1 <= budget do
    start = start - 1
    used = used + #lines[start] + 1
  end
  used = 0
  while finish < #lines and used + #lines[finish + 1] + 1 <= budget do
    finish = finish + 1
    used = used + #lines[finish] + 1
  end
  return start, finish
end

---@param inv {selection: table, config: table, copy: string, prompt: string}
---@return string
function M.build(inv)
  local sel = inv.selection
  local lines = sel.original
  local start, finish = excerpt_range(lines, sel.first, sel.last, inv.config.inline.context_bytes / 2)
  local excerpt = {}
  for i = start, finish do
    excerpt[#excerpt + 1] = string.format("%d\t%s", i, lines[i])
  end

  local kind, scope_text
  if sel.free then
    -- Normal mode: no preselected range. The cursor is a hint, not a limit.
    kind = "No selection: apply the request to the copy, changing only what it needs"
    scope_text = string.format("The cursor is at line %d, byte column %d.", sel.first, sel.ranges[1].start_col)
  else
    local scope = {}
    for _, r in ipairs(sel.ranges) do
      scope[#scope + 1] = string.format(
        "line %d byte column %d through line %d byte column %d (zero-based columns, end exclusive)",
        r.start_row + 1,
        r.start_col,
        r.end_row + 1,
        r.end_col
      )
    end
    kind = sel.linewise and "Rewrite only these whole lines"
      or "Rewrite only the exact selected bytes; preserve every other byte"
    scope_text = table.concat(scope, "\n")
  end

  local request = { "User request:\n" .. inv.prompt }
  if not sel.free then
    table.insert(request, 1, "Selected text:\n<selection>\n" .. sel.text .. "\n</selection>")
  end

  return table.concat({
    "INLINE_BUFFER_EDIT: This is an inline edit in our current conversation, not a new session.",
    "Edit only the private buffer copy at `" .. inv.copy .. "`. Do not edit the original file or run commands.",
    "The copy contains the current UNSAVED editor contents. Read that copy, not a stale file from earlier turns.",
    kind .. ":\n" .. scope_text,
    sel.free and "Do not change the final-newline convention. Leave unrelated code untouched."
      or "Do not change the final-newline convention or the indentation of untouched text. Out-of-range changes will be discarded.",
    "Source filetype: " .. sel.filetype,
    "Nearby context (line numbers are annotations, never copy them into the file):\n<document>\n"
      .. table.concat(excerpt, "\n")
      .. "\n</document>",
    table.concat(request, "\n\n"),
  }, "\n\n")
end

return M
