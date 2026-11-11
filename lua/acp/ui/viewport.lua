-- Preserve reading position across width-dependent transcript reflow. Anchors
-- refer to a block plus a rendered-row offset, not an absolute buffer row that
-- may move when an earlier table wraps differently.
local M = {}
local tail_ns = vim.api.nvim_create_namespace("acp_tail_padding")

function M.clear_tail(chat)
  if chat.buf and vim.api.nvim_buf_is_valid(chat.buf) then
    vim.api.nvim_buf_clear_namespace(chat.buf, tail_ns, 0, -1)
  end
  chat.tail_padding, chat.tail_aligned = nil, nil
end

local function prepare_tail(chat)
  local win, buf = chat.win, chat.buf
  -- Without partial wrapped-line scrolling, zb may put just the trailing blank
  -- rows at the top when the preceding logical line is taller than the window.
  vim.wo[win].smoothscroll = true
  vim.api.nvim_buf_clear_namespace(buf, tail_ns, 0, -1)
  -- Clear any padding left by an older view. Short transcripts start naturally
  -- at buffer row 1; unused window space belongs below, never above the text.
  chat.tail_padding = 0
end

function M.refresh_tail(chat)
  if chat.tail_aligned and chat:is_visible() and vim.api.nvim_win_get_buf(chat.win) == chat.buf then
    prepare_tail(chat)
  end
end

local function align_tail(chat)
  local win = chat.win
  local count = vim.api.nvim_buf_line_count(chat.buf)
  vim.api.nvim_win_set_cursor(win, { count, 0 })
  vim.cmd("normal! zb")
  if vim.wo[win].wrap and vim.api.nvim_win_text_height then
    -- For a non-current window Neovim may defer the wrapped topline's skipcol
    -- until cursor redraw, which never happens while typing in the composer.
    -- Supply that screen-row offset explicitly instead of moving input focus.
    local view = vim.fn.winsaveview()
    local info = vim.fn.getwininfo(win)[1]
    local height = vim.api.nvim_win_text_height(win, { start_row = view.topline - 1, end_row = count - 1 }).all
    local skip = math.max(0, height - info.height)
    if skip > 0 then
      view.skipcol = skip * math.max(1, info.width - info.textoff)
      vim.fn.winrestview(view)
    end
  end
end

-- Moving the cursor alone leaves Neovim free to keep a shrink-induced topline
-- near EOF. Explicitly align the final *display* row, including the existing
-- trailing blank line, without changing focus, mode, jumplist or scrolloff.
function M.follow_tail(chat)
  if not chat:is_visible() or vim.api.nvim_win_get_buf(chat.win) ~= chat.buf then
    return false
  end
  chat.tail_aligned = true
  prepare_tail(chat)
  vim.api.nvim_win_call(chat.win, function()
    align_tail(chat)
  end)
  return true
end

-- Following is determined by the visible tail, not by the reading cursor.
function M.at_tail(chat)
  if not chat:is_visible() or vim.api.nvim_win_get_buf(chat.win) ~= chat.buf then
    return false
  end
  if chat.page and chat.session and chat.page.last ~= #chat.session.blocks then
    return false
  end
  return vim.api.nvim_win_call(chat.win, function()
    local count = vim.api.nvim_buf_line_count(chat.buf)
    if vim.fn.line("w$") < count then
      return false
    end
    local text = vim.api.nvim_buf_get_lines(chat.buf, count - 1, count, false)[1] or ""
    local row = vim.fn.screenpos(chat.win, count, math.max(1, #text)).row
    local info = vim.fn.getwininfo(chat.win)[1]
    return row >= info.winrow + info.winbar and row < info.winrow + info.winbar + info.height
  end)
end

-- Clamp wheel/touchpad overscroll while preserving the user's cursor and
-- reading mode. The canonical EOF view accounts for wrapping and virtual rows.
function M.clamp_tail(chat)
  if not chat:is_visible() or vim.api.nvim_win_get_buf(chat.win) ~= chat.buf then
    return false
  end
  return vim.api.nvim_win_call(chat.win, function()
    local count = vim.api.nvim_buf_line_count(chat.buf)
    if vim.fn.line("w$") < count then
      return false
    end
    local info = vim.fn.getwininfo(chat.win)[1]
    if count <= info.height and vim.api.nvim_win_text_height then
      local height = vim.api.nvim_win_text_height(chat.win, { start_row = 0, end_row = count - 1 }).all
      if height <= info.height then
        local saved = vim.fn.winsaveview()
        local beyond = saved.topline ~= 1 or saved.skipcol ~= 0 or saved.topfill ~= 0
        if beyond then
          saved.topline, saved.skipcol, saved.topfill = 1, 0, 0
          vim.fn.winrestview(saved)
        end
        return beyond
      end
    end
    local text = vim.api.nvim_buf_get_lines(chat.buf, count - 1, count, false)[1] or ""
    local row = vim.fn.screenpos(chat.win, count, math.max(1, #text)).row
    -- Do not disturb a correctly aligned view. In particular, zb's wrapped-line
    -- skipcol is resolved during redraw; saving/restoring it prematurely can
    -- discard that pending adjustment and hide EOF again.
    if row == 0 or row >= info.winrow + info.winbar + info.height - 1 then
      return false
    end
    local saved = vim.fn.winsaveview()
    chat.tail_aligned = true
    prepare_tail(chat)
    align_tail(chat)
    local bottom = vim.fn.winsaveview()
    if saved.topline == bottom.topline and saved.skipcol == bottom.skipcol and saved.topfill == bottom.topfill then
      -- Some wrapped/status-column combinations round zb one screen row too
      -- far. Correct the measured screen gap with native smooth scrolling.
      local gap = info.winrow + info.winbar + info.height - 1 - row
      vim.cmd("normal! " .. gap .. string.char(25)) -- <C-y>: scroll up by screen rows
      bottom = vim.fn.winsaveview()
    end
    local beyond = saved.topline > bottom.topline
      or (saved.topline == bottom.topline and saved.skipcol > bottom.skipcol)
      or (saved.topline == bottom.topline and saved.skipcol == bottom.skipcol and saved.topfill < bottom.topfill)
    if beyond then
      saved.topline, saved.skipcol, saved.topfill = bottom.topline, bottom.skipcol, bottom.topfill
    end
    vim.fn.winrestview(saved)
    return beyond
  end)
end

local function anchor(chat, row)
  local entry = chat.meta[row]
  if entry and entry.block_id then
    local within = 0
    if entry.source then
      local previous = row - 1
      while
        previous > 0
        and chat.meta[previous].block_id == entry.block_id
        and chat.meta[previous].source == entry.source
      do
        within, previous = within + 1, previous - 1
      end
    end
    return {
      id = entry.block_id,
      source = entry.source,
      within = within,
      offset = row - chat.line_starts[entry.block_id],
      row = row,
    }
  end
  -- Turn separators are not blocks: anchor them relative to the next block.
  for i = row + 1, #chat.meta do
    entry = chat.meta[i]
    if entry and entry.block_id then
      return { id = entry.block_id, offset = row - chat.line_starts[entry.block_id], row = row }
    end
  end
  return { row = row }
end

function M.capture(chat)
  if not chat:is_visible() then
    return nil
  end
  local view = vim.api.nvim_win_call(chat.win, vim.fn.winsaveview)
  return { view = view, cursor = anchor(chat, view.lnum), top = anchor(chat, view.topline) }
end

local function resolve(chat, saved)
  local start = saved.id and chat.line_starts[saved.id]
  if not start then
    return math.min(saved.row, #chat.lines_cache)
  end
  local entry = chat.cache[saved.id]
  local last = entry and #entry.lines - 1 or 0
  if saved.source and entry then
    local best, distance
    for i, line in ipairs(entry.lines) do
      if line.source then
        local delta = math.abs(line.source - saved.source)
        if not distance or delta < distance then
          best, distance = i, delta
        end
      end
    end
    if best then
      local stop = best
      while stop < #entry.lines and entry.lines[stop + 1].source == entry.lines[best].source do
        stop = stop + 1
      end
      return start + best - 1 + math.min(saved.within or 0, stop - best)
    end
  end
  return math.max(1, start + math.min(saved.offset, math.max(0, last)))
end

function M.restore(chat, saved)
  if not saved or not chat:is_visible() then
    return
  end
  local view = saved.view
  view.lnum = math.max(1, resolve(chat, saved.cursor))
  view.topline = math.max(1, resolve(chat, saved.top))
  view.col = math.min(view.col, #(chat.lines_cache[view.lnum] or ""))
  -- skipcol is a screen-row offset into a wrapped line; the old value is no
  -- longer meaningful after changing width.
  view.skipcol = 0
  vim.api.nvim_win_call(chat.win, function()
    vim.fn.winrestview(view)
  end)
end

return M
