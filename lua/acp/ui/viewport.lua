-- Preserve reading position across width-dependent transcript reflow. Anchors
-- refer to a block plus a rendered-row offset, not an absolute buffer row that
-- may move when an earlier table wraps differently.
local M = {}

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
