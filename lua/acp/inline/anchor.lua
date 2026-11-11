-- Placement for the inline prompt float.
--
-- Geometry only: this module never opens a window, so the flip/clamp rules can
-- be tested without a real UI. Positions are 0-based screen cells, the same
-- shape `nvim_open_win({ relative = "editor" })` expects.
local M = {}

---Usable rows below the last window line.
---@return integer
local function usable_rows()
  -- The last screen line is the message area; `cmdheight` rows belong to the
  -- command line. Both would make the float unreachable if we ignored them.
  return math.max(1, vim.o.lines - vim.o.cmdheight - 1)
end

---Screen cell of a buffer position, or a window-relative fallback when the
---position is scrolled out of view (screenpos then reports row 0).
---@param win integer
---@param cursor integer[]|nil
---@return {row: integer, col: integer}
function M.anchor(win, cursor)
  if not vim.api.nvim_win_is_valid(win) then
    return { row = 0, col = 0 }
  end
  local pos = cursor or vim.api.nvim_win_get_cursor(win)
  local line, col = pos[1] or 1, pos[2] or 0
  local ok, screen = pcall(vim.fn.screenpos, win, line, col + 1)
  if ok and type(screen) == "table" and (screen.row or 0) > 0 and (screen.col or 0) > 0 then
    return { row = screen.row - 1, col = screen.col - 1 }
  end
  local base = vim.api.nvim_win_get_position(win)
  return { row = base[1], col = base[2] }
end

---Clamp a float config to the screen. Width and height are content sizes; the
---border adds one cell on every side.
---@param row integer
---@param col integer
---@param width integer
---@param height integer
---@return table
function M.config(row, col, width, height)
  local rows, columns = usable_rows(), math.max(1, vim.o.columns)
  width = math.max(1, math.min(math.floor(width or 1), columns - 2))
  height = math.max(1, math.min(math.floor(height or 1), rows - 2))
  row = math.max(0, math.min(math.floor(row or 0), rows - height - 2))
  col = math.max(0, math.min(math.floor(col or 0), columns - width - 2))
  return { relative = "editor", row = row, col = col, width = width, height = height }
end

---Place a prompt float near the cursor.
---
---`cursor` prefers the space below the cursor and flips above when the float
---would not fit, so a prompt opened on the last visible line stays usable.
---`window` keeps the historical top-left anchor. `anchor_cell` pins an explicit
---screen cell, used when the prompt should not follow the cursor.
---@param opts {
---  source: integer,
---  cursor: integer[]|nil,
---  anchor_cell: {row: integer, col: integer}|nil,
---  placement: "cursor"|"window",
---  width: integer,
---  height: integer,
---  offset: {row?: integer, col?: integer}|nil
---}
---@return table|nil
function M.place(opts)
  if not vim.api.nvim_win_is_valid(opts.source) then
    return nil
  end
  local rows = usable_rows()
  local height = math.max(1, math.min(opts.height or 1, rows - 2))
  local offset = opts.offset or {}
  local row, col
  if opts.placement == "cursor" then
    local anchor = opts.anchor_cell or M.anchor(opts.source, opts.cursor)
    -- Total rows include a border on each side. Prefer a blank row between the
    -- cursor line and the float's top border.
    local below = anchor.row + 2
    local above = anchor.row - height - 1
    row = (below + height + 1 <= rows) and below or above
    col = anchor.col
  else
    local pos = vim.api.nvim_win_get_position(opts.source)
    row, col = pos[1], pos[2]
  end
  row = row + (offset.row or 0)
  col = col + (offset.col or 0)
  return M.config(row, col, opts.width or 1, height)
end

return M
