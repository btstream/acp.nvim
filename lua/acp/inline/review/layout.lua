-- Real windows in a dedicated tabpage, one per review column.
--
-- The columns are *not* in Vim's diff mode: Vim diffs every diff window of a
-- tab against each other, which cannot express "original vs result" and
-- "result vs proposal" as two separate comparisons. Instead each buffer is
-- padded with filler rows from `review.align`, so every column has the same
-- number of rows and `scrollbind`, `cursorbind` and folds line up natively.
-- Real line numbers come from `statuscolumn`, and filler rows have none.
-- Nothing this module does writes to the source file.
local M = {}

local result = require("acp.inline.result")

---Per-buffer gutter data, read by `statuscolumn`, `foldexpr` and `foldtext`.
---@type table<integer, {lnums: table<integer, integer>, bars: table<integer, string>, folds: table<integer, integer>, relative?: boolean, width: integer}>
local gutters = {}

local STATUSCOLUMN = "%!v:lua.require'acp.inline.review.layout'.statuscolumn()"

local WINDOW_OPTS = {
  diff = false,
  foldmethod = "expr",
  foldexpr = "v:lua.require'acp.inline.review.layout'.foldexpr()",
  foldtext = "v:lua.require'acp.inline.review.layout'.foldtext()",
  scrollbind = true,
  cursorbind = true,
  cursorline = true,
  foldcolumn = "0",
  signcolumn = "no",
  -- The number column itself is replaced by `statuscolumn`; `number` only
  -- makes sure the column is drawn.
  number = true,
  relativenumber = false,
  wrap = false,
  fillchars = "eob: ,fold: ,vert:│",
}

---Window options whose *global* value is what new windows inherit.
---
---`nvim_set_option_value(name, value, { win = win })` writes both the window's
---local value and that inheritance value. Left alone, every window opened while
---a review runs (completion popups, pickers, notifications) would come up with
---the review gutter, folds and `winhighlight`.
local INHERIT_OPTS = {
  "diff",
  "winhighlight",
  "scrollbind",
  "cursorbind",
  "cursorline",
  "wrap",
  "number",
  "relativenumber",
  "numberwidth",
  "statuscolumn",
  "foldmethod",
  "foldexpr",
  "foldtext",
  "foldcolumn",
  "foldlevel",
  "signcolumn",
  "fillchars",
}

---@return table<string, any>
local function capture_inherit()
  local saved = {}
  for _, name in ipairs(INHERIT_OPTS) do
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { scope = "global" })
    if ok then
      saved[name] = value
    end
  end
  return saved
end

---@param saved table<string, any>
local function restore_inherit(saved)
  if not saved then
    return
  end
  for name, value in pairs(saved) do
    pcall(vim.api.nvim_set_option_value, name, value, { scope = "global" })
  end
end

---`winhighlight` string for a pane.
---@return string
local function pane_winhl()
  return table.concat({
    "Normal:AcpReviewNormal",
    "NormalNC:AcpReviewNormal",
    -- The theme's `CursorLine` often carries an underline; with `cursorbind`
    -- it would be drawn across every column.
    "CursorLine:AcpReviewCursorLine",
    "LineNr:AcpReviewGutter",
    "CursorLineNr:AcpReviewGutterCur",
    "Folded:AcpReviewFold",
    "FoldColumn:AcpReviewFoldCol",
    "EndOfBuffer:AcpReviewEob",
    "WinSeparator:AcpReviewSep",
    "NonText:AcpReviewFoldCol",
  }, ",")
end

---Gutter data for a review buffer.
---@param buf integer
---@param data {lnums: table<integer, integer>, bars?: table<integer, {group: string, glyph: string}>, folds?: table<integer, integer>, width?: integer, relative?: boolean}
function M.set_gutter(buf, data)
  local previous = gutters[buf] or {}
  gutters[buf] = {
    lnums = data.lnums or previous.lnums or {},
    bars = data.bars or previous.bars or {},
    folds = data.folds or previous.folds or {},
    width = data.width or previous.width or 3,
    relative = data.relative == nil and previous.relative or data.relative,
  }
end

---Gutter data for a buffer (tests and decorations).
---@param buf integer
---@return table|nil
function M.gutter(buf)
  return gutters[buf == 0 and vim.api.nvim_get_current_buf() or buf]
end

---Real line number shown on a display row, honouring `relative`.
---@param data table
---@param win integer
---@param row integer
---@return string
local function number_text(data, win, row)
  local lnum = data.lnums[row]
  if not lnum then
    return ""
  end
  if not data.relative then
    return tostring(lnum)
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  local crow = ok and cursor[1] or row
  if crow == row then
    return tostring(lnum)
  end
  -- Relative distance counts real lines, not filler rows.
  local current
  for r = crow, 1, -1 do
    if data.lnums[r] then
      current = data.lnums[r]
      break
    end
  end
  return tostring(math.abs(lnum - (current or 0)))
end

---`statuscolumn` for a review pane: a one-cell state bar, then the real line
---number. Filler rows show only the bar.
---@return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  local data = ok and gutters[buf] or nil
  if not data then
    return ""
  end
  local row = vim.v.lnum
  local bar = data.bars[row]
  local cell = bar and ("%#" .. bar.group .. "#" .. bar.glyph .. "%*") or " "
  local fold = vim.wo[win].foldcolumn ~= "0" and "%C" or ""
  if vim.v.virtnum ~= 0 then
    return fold .. cell .. string.rep(" ", data.width + 1)
  end
  local text = number_text(data, win, row)
  local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
  local group = cursor_row == row and "AcpReviewGutterCur" or "AcpReviewGutter"
  return fold .. cell .. "%#" .. group .. "#" .. string.rep(" ", data.width - #text) .. text .. " %*"
end

---`foldexpr`: context further than `inline.window.review.context` from every
---hunk folds away.
---@return integer
function M.foldexpr()
  local data = gutters[vim.api.nvim_get_current_buf()]
  return data and data.folds[vim.v.lnum] or 0
end

---`foldtext` for folded context.
---@return string
function M.foldtext()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return string.format("  ⋯ %d unchanged line%s", count, count == 1 and "" or "s")
end

---Start highlighting for a scratch buffer holding the file's own language.
---
---Neovim only ships Tree-sitter ftplugins for a few languages (`lua`,
---`markdown`, `query`, `help`). A `nofile` scratch buffer for, say, Python or
---Go therefore gets legacy `syntax` at best, and often nothing at all. Starting
---the parser explicitly makes every language consistent, and falls back to the
---legacy syntax file silently when no parser or query is installed.
---@param buf integer
---@param filetype string
local function start_highlighting(buf, filetype)
  if filetype == "" then
    return
  end
  local ok, CodeHL = pcall(require, "acp.ui.code_hl")
  local resolved = ok and CodeHL.resolve_language(filetype) or filetype
  -- A compound filetype such as `typescript.tsx` maps to its first component
  -- when the full name is not a parser name.
  local candidates = { resolved }
  local head = filetype:match("^([^.]+)")
  if head and head ~= resolved then
    candidates[#candidates + 1] = head
  end
  for _, language in ipairs(candidates) do
    if pcall(vim.treesitter.start, buf, language) then
      return
    end
  end
  -- Silent fallback: the legacy syntax file still colours the language when the
  -- parser is missing. `syntax` is set explicitly because `ftplugin` files do
  -- not always run for a `nofile` scratch buffer.
  pcall(function()
    vim.bo[buf].syntax = candidates[#candidates]
  end)
end

---Create a scratch buffer holding `lines`, with the file's real filetype so
---Neovim starts its own syntax highlighting.
---@param lines string[]
---@param filetype string
---@param modifiable boolean
---@return integer
local function scratch(lines, filetype, modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  -- `hide`, not `wipe`: `winfixbuf` is meant to make a buffer switch impossible,
  -- but if some plugin still manages one, the review must keep its buffers and
  -- stay recoverable instead of losing them mid-review. `M.close` deletes them.
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  if filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
  start_highlighting(buf, filetype)
  return buf
end

---Apply the review window options.
---@param win integer
---@param opts {fold?: boolean, sync_scroll?: boolean, pane?: string, relative_number?: boolean, foldcolumn?: integer}
local function window_options(win, opts)
  for name, value in pairs(WINDOW_OPTS) do
    if name == "scrollbind" or name == "cursorbind" then
      value = opts.sync_scroll ~= false and value or false
    elseif name == "foldmethod" then
      value = opts.fold ~= false and value or "manual"
    end
    -- Local only: the inheritance value is restored separately once every pane
    -- exists, so unrelated windows keep the user's options.
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
  -- Relative numbers are computed by `statuscolumn` from real line numbers,
  -- so the window option itself stays off.
  if opts.fold ~= false and opts.foldcolumn ~= nil then
    pcall(vim.api.nvim_set_option_value, "foldcolumn", tostring(opts.foldcolumn), { win = win, scope = "local" })
  end
  pcall(vim.api.nvim_set_option_value, "statuscolumn", STATUSCOLUMN, { win = win, scope = "local" })
  -- `fillchars` is global-local: assigning through the window scope keeps the
  -- user's global value untouched.
  pcall(vim.api.nvim_set_option_value, "fillchars", WINDOW_OPTS.fillchars, { win = win, scope = "local" })
  pcall(vim.api.nvim_set_option_value, "winhighlight", pane_winhl(), { win = win, scope = "local" })
  pcall(vim.api.nvim_set_option_value, "foldlevel", opts.fold ~= false and 0 or 99, { win = win, scope = "local" })
  -- Pin the window to the buffer the review built for it. Without this, `:edit`,
  -- `:enew`, `:bnext` and plugin "open here" helpers would replace the result
  -- column with a real file, and its buffer is where decisions are written.
  -- Closing the window is still allowed.
  pcall(vim.api.nvim_set_option_value, "winfixbuf", true, { win = win, scope = "local" })
end

---Re-apply a pane's window options, e.g. after the window lost them.
---@param win integer
---@param opts table
function M.refresh_window(win, opts)
  window_options(win, opts)
end

---Open the layout.
---
---Windows are created left to right with an explicit direction, so the column
---order does not depend on the user's 'splitright'.
---@param opts {
---  buffers: integer[],
---  panes?: string[],
---  fold?: boolean,
---  sync_scroll?: boolean,
---  relative_number?: boolean,
---  foldcolumn?: integer,
---  labels?: {badge: string, path: string, version: string}[]
---}
---@return table
local function open_layout(opts, state)
  local previous_tab = vim.api.nvim_get_current_tabpage()
  state.inherit = capture_inherit()

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  state.tabpage = tabpage
  -- `tabnew` leaves an empty placeholder buffer behind; it would outlive the
  -- review, so remember it and delete it once its window has a real buffer.
  local placeholder = vim.api.nvim_get_current_buf()
  state.buffers = { placeholder }
  local windows = {}
  for index = 1, #opts.buffers do
    if index > 1 then
      -- `rightbelow` ignores 'splitright', so the new column is always created
      -- to the right of the previous one.
      vim.cmd("rightbelow vsplit")
    end
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, opts.buffers[index])
    windows[index] = win
  end
  if vim.api.nvim_buf_is_valid(placeholder) then
    local keep = false
    for _, buf in ipairs(opts.buffers) do
      if buf == placeholder then
        keep = true
      end
    end
    if not keep then
      pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
    end
  end
  for index, win in ipairs(windows) do
    local pane = opts.panes and opts.panes[index] or nil
    window_options(win, {
      fold = opts.fold,
      sync_scroll = opts.sync_scroll,
      relative_number = opts.relative_number,
      foldcolumn = opts.foldcolumn,
      pane = pane,
    })
  end
  -- Panes have their options; hand the inheritance values back to the user so
  -- popups and splits opened from now on look normal and stay out of the diff.
  restore_inherit(state.inherit)
  vim.cmd("wincmd =")

  -- The result column owns the cursor: that is where decisions are made.
  local focus = #opts.buffers == 3 and 2 or 1
  vim.api.nvim_set_current_win(windows[focus])
  return {
    tabpage = tabpage,
    previous_tab = previous_tab,
    inherit = state.inherit,
    windows = windows,
    focus = focus,
  }
end

---Build a layout transactionally, rolling back partial windows on failure.
---@param opts table
---@return table
function M.open(opts)
  local state = {
    previous_tab = vim.api.nvim_get_current_tabpage(),
  }
  local ok, opened = pcall(open_layout, opts, state)
  if not ok then
    M.close(state)
    error(opened, 0)
  end
  return opened
end

---Close the tab and drop the scratch buffers.
---@param session table
function M.close(session)
  -- Close the tab first: its windows are the only ones displaying these
  -- buffers, and deleting a buffer that is still shown would make Neovim swap
  -- the window to an unrelated buffer first.
  if session.tabpage and vim.api.nvim_tabpage_is_valid(session.tabpage) then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(session.tabpage))
  end
  for _, buf in ipairs(session.buffers or {}) do
    gutters[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  restore_inherit(session.inherit)
  if session.previous_tab and vim.api.nvim_tabpage_is_valid(session.previous_tab) then
    pcall(vim.api.nvim_set_current_tabpage, session.previous_tab)
  end
end

---Replace the result buffer's contents without leaving undo entries behind.
---
---Only the lines that actually changed are written, bottom-up, so Neovim keeps
---the cursor and scroll position stable when a decision touches a hunk above
---or below it. Rewriting the whole buffer would move both to an arbitrary row.
---
---The buffer is `nomodifiable` while the user has it: it only *shows* the
---outcome of the decisions, and a manual edit would be silently overwritten by
---the next accept/reject. `modifiable` is toggled for the duration of this
---write and restored even if the write fails.
---@param buf integer
---@param lines string[]
function M.write(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local target = #lines > 0 and lines or { "" }
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunks = result.hunks(current, target)
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(function()
    if #hunks == 0 then
      return
    end
    -- Bottom-up: an earlier edit must not invalidate the row numbers of a
    -- later one.
    table.sort(hunks, function(a, b)
      return a.start > b.start
    end)
    for _, hunk in ipairs(hunks) do
      vim.api.nvim_buf_set_lines(buf, hunk.start, hunk.start + #hunk.old_lines, false, hunk.new_lines)
    end
  end)
  vim.bo[buf].modifiable = was
  vim.bo[buf].modified = false
  return ok, err
end

M.scratch = scratch
return M
