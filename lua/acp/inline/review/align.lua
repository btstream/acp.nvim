-- Row alignment for the side-by-side review.
--
-- Every pane shows the same number of display rows. A side that has no line
-- at a row gets a filler row instead, so `scrollbind`, `cursorbind` and folds
-- line up natively and a display row means the same thing in every column.
--
-- The alignment, the row kinds and the character-level ranges all come from
-- `result.hunk_pairs`, so what is painted can never disagree with how the rows
-- are aligned. Block heights do not depend on review decisions: accepting or
-- rejecting a hunk only swaps the text shown inside the result column's block.
--
-- Pure: no buffers, windows or highlights.
local M = {}

local result = require("acp.inline.result")

---@class AcpReviewRow
---@field old integer|nil   1-based line in the original, nil on filler
---@field new integer|nil   1-based line in the proposal, nil on filler
---@field hunk integer|nil  index of the hunk this row belongs to
---@field kind string|nil   "modify"|"delete"|"add"|"same" inside a hunk
---@field chars table|nil   character ranges for `modify` rows

---@class AcpReviewModel
---@field rows AcpReviewRow[]
---@field spans {first: integer, last: integer}[]  display rows per hunk
---@field original string[]
---@field edited string[]

---Build the alignment.
---@param original string[]
---@param edited string[]
---@param hunks table[] from `result.hunks`, ordered by `start`
---@return AcpReviewModel
function M.build(original, edited, hunks)
  local rows, spans = {}, {}
  -- Next unconsumed line on each side (1-based).
  local oi, ni = 1, 1
  local function context_until(old_stop)
    while oi <= old_stop do
      rows[#rows + 1] = { old = oi, new = ni }
      oi, ni = oi + 1, ni + 1
    end
  end
  for index, hunk in ipairs(hunks) do
    context_until(hunk.start)
    local first = #rows + 1
    local old_base, new_base = hunk.start, hunk.new_start or (ni - 1)
    for _, pair in ipairs(result.hunk_pairs(hunk)) do
      local row = {
        old = pair.old and (old_base + pair.old) or nil,
        new = pair.new and (new_base + pair.new) or nil,
        hunk = index,
        kind = pair.kind,
      }
      if pair.kind == "modify" then
        row.chars = result.char_ranges(hunk.old_lines[pair.old], hunk.new_lines[pair.new])
      end
      rows[#rows + 1] = row
    end
    spans[index] = { first = first, last = math.max(first, #rows) }
    oi, ni = hunk.start + #hunk.old_lines + 1, new_base + #hunk.new_lines + 1
  end
  context_until(#original)
  if #rows == 0 then
    rows[1] = { old = #original > 0 and 1 or nil, new = #edited > 0 and 1 or nil }
  end
  return { rows = rows, spans = spans, original = original, edited = edited }
end

---Which side the result column shows for a hunk.
---@param hunk table|nil
---@return "old"|"new"
local function result_side(hunk)
  return (hunk and hunk.decided and hunk.accepted) and "new" or "old"
end

---Text, real line numbers and filler flags for one pane.
---
---`lnums[row]` is the line number in that pane's own file (nil on filler), so
---the gutter shows real line numbers. The result column counts its own lines,
---which shift as hunks are accepted.
---@param model AcpReviewModel
---@param pane "original"|"result"|"proposal"
---@param hunks table[]
---@return {lines: string[], lnums: table<integer, integer>, filler: table<integer, boolean>}
function M.pane(model, pane, hunks)
  local lines, lnums, filler = {}, {}, {}
  local count = 0
  for r, row in ipairs(model.rows) do
    local side = pane == "original" and "old" or pane == "proposal" and "new" or result_side(hunks[row.hunk])
    local lnum = row[side]
    local text
    if lnum then
      text = (side == "old" and model.original or model.edited)[lnum]
    end
    if text then
      count = count + 1
      lines[r] = text
      -- The result column has its own numbering; the sides keep the file's.
      lnums[r] = pane == "result" and count or lnum
    else
      lines[r] = ""
      filler[r] = true
    end
  end
  return { lines = lines, lnums = lnums, filler = filler }
end

---Display rows a hunk occupies (identical in every pane).
---@param model AcpReviewModel
---@param index integer
---@return integer first, integer last
function M.span(model, index)
  local span = model.spans[index]
  if not span then
    return 1, 1
  end
  return span.first, span.last
end

---Hunk at a display row, if any.
---@param model AcpReviewModel
---@param row integer
---@return integer|nil
function M.hunk_at(model, row)
  local entry = model.rows[row]
  return entry and entry.hunk or nil
end

---Fold level per display row: rows further than `context` from every hunk
---fold away, like `diffopt=context:N`.
---@param model AcpReviewModel
---@param context integer
---@return table<integer, integer>
function M.fold_levels(model, context)
  local levels = {}
  for r = 1, #model.rows do
    levels[r] = 1
  end
  for _, span in ipairs(model.spans) do
    for r = math.max(1, span.first - context), math.min(#model.rows, span.last + context) do
      levels[r] = 0
    end
  end
  return levels
end

---Decision state of a hunk, from the cursor and the decisions.
---@param hunk table
---@param index integer
---@param current integer|nil
---@return "Pending"|"Current"|"Accepted"|"Rejected"
function M.state(hunk, index, current)
  if hunk.decided then
    return hunk.accepted and "Accepted" or "Rejected"
  end
  return index == current and "Current" or "Pending"
end

---Decorations for one pane, as plain data.
---
---Each side shows its change relative to the result:
---
---  | pane     | pending              | accepted          | rejected        |
---  |----------|----------------------|-------------------|-----------------|
---  | original | delete + char marks  | dimmed (replaced) | plain (kept)    |
---  | result   | pending surface      | add + char marks  | plain           |
---  | proposal | add + char marks     | add (taken)       | dimmed (dropped)|
---
---@param model AcpReviewModel
---@param pane "original"|"result"|"proposal"
---@param hunks table[]
---@param filler table<integer, boolean> from `M.pane`
---@return {row: integer, line?: string, chars?: {[1]: integer, [2]: integer, [3]: string}[]}[]
function M.decorations(model, pane, hunks, filler)
  local out = {}
  for r, row in ipairs(model.rows) do
    local hunk = row.hunk and hunks[row.hunk]
    if filler[r] then
      out[#out + 1] = { row = r, line = "AcpReviewFiller", filler = true }
    elseif hunk and row.kind ~= "same" then
      local decided, accepted = hunk.decided, hunk.accepted
      local line, chars, char_group
      if pane == "original" then
        if not decided then
          line, chars, char_group = "AcpReviewDelete", row.chars and row.chars.old, "AcpReviewDeleteText"
        elseif accepted then
          line = "AcpReviewDimmed"
        end
      elseif pane == "proposal" then
        if decided and not accepted then
          line = "AcpReviewDimmed"
        else
          line, chars, char_group = "AcpReviewAdd", row.chars and row.chars.new, "AcpReviewAddText"
        end
      else
        if not decided then
          line = "AcpReviewPending"
        elseif accepted then
          line, chars, char_group = "AcpReviewAdd", row.chars and row.chars.new, "AcpReviewAddText"
        end
      end
      if line then
        local entry = { row = r, line = line }
        if chars and #chars > 0 then
          entry.chars = {}
          for _, range in ipairs(chars) do
            entry.chars[#entry.chars + 1] = { range[1], range[2], char_group }
          end
        end
        out[#out + 1] = entry
      end
    end
  end
  return out
end

return M
