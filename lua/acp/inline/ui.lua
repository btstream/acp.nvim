-- The inline prompt float.
--
-- It sits above the selection, never in a split, so opening it does not move
-- code. The float follows the source window while open and is closed before the
-- result is reviewed.
local M = {}

local state
local group = vim.api.nvim_create_augroup("AcpInlineUI", { clear = true })

---@return integer|nil
local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win) and win or nil
end

---@param win integer
---@param row integer 0-based row in `win`
---@return integer row_offset, integer col_offset
local function anchor(win, row)
  local pos = vim.api.nvim_win_get_position(win)
  local height = vim.api.nvim_win_get_height(win)
  local width = vim.api.nvim_win_get_width(win)
  local screen_row = pos[1] + math.max(0, math.min(row, height - 1))
  local float_height = 3
  local top = math.max(0, screen_row - float_height)
  return top, pos[2] + math.min(4, math.max(0, width - 20))
end

function M.reposition()
  if not state or not valid_win(state.win) or not valid_win(state.source) then
    return
  end
  local row, col = anchor(state.source, state.row)
  pcall(vim.api.nvim_win_set_config, state.win, {
    relative = "editor",
    row = row,
    col = col,
    width = state.width,
    height = 3,
  })
end

---@param text string
function M.set_status(text)
  if not state or not valid_win(state.win) then
    return
  end
  local title = " ACP Inline · " .. text .. " "
  pcall(vim.api.nvim_win_set_config, state.win, {
    relative = "editor",
    row = vim.api.nvim_win_get_config(state.win).row,
    col = vim.api.nvim_win_get_config(state.win).col,
    width = state.width,
    height = 3,
    title = title,
    title_pos = "left",
  })
end

---@return boolean
function M.is_open()
  return state ~= nil and valid_win(state.win) ~= nil
end

---@return string
function M.text()
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return ""
  end
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n"))
end

function M.close()
  if not state then
    return
  end
  local source = valid_win(state.source)
  local buf = state.buf
  local win = state.win
  state = nil
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if source then
    pcall(vim.api.nvim_set_current_win, source)
  end
end

---Open the prompt above `row` in `source`.
---@param opts {source: integer, row: integer, on_submit: fun(text: string), on_close: fun(), title: string,
---  on_toggle_review: fun(): string}
---@return boolean
function M.open(opts)
  if not valid_win(opts.source) then
    return false
  end
  M.close()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "acp_inline"
  vim.bo[buf].textwidth = 0

  local width = math.max(30, math.min(72, vim.api.nvim_win_get_width(opts.source) - 6))
  local row, col = anchor(opts.source, opts.row)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 3,
    style = "minimal",
    border = "rounded",
    title = " ACP Inline · " .. opts.title .. " ",
    title_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight = "Normal:AcpInlinePrompt,FloatBorder:AcpInlineBorder,FloatTitle:AcpInlineBorder"

  state = { buf = buf, win = win, source = opts.source, row = opts.row, width = width }
  vim.cmd("startinsert")

  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local text = M.text()
    if text ~= "" then
      opts.on_submit(text)
    end
  end, { buffer = buf, nowait = true, desc = "Send inline prompt" })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    local text = M.text()
    if text ~= "" then
      opts.on_submit(text)
    end
  end, { buffer = buf, nowait = true, desc = "Send inline prompt" })
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    M.close()
    if opts.on_close then
      opts.on_close()
    end
  end, { buffer = buf, nowait = true, desc = "Close inline prompt" })
  vim.keymap.set("n", "q", function()
    M.close()
    if opts.on_close then
      opts.on_close()
    end
  end, { buffer = buf, nowait = true })
  vim.keymap.set({ "n", "i" }, "<C-d>", function()
    if opts.on_toggle_review then
      M.set_status(opts.on_toggle_review())
    end
  end, { buffer = buf, nowait = true, desc = "Toggle review mode" })

  vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized" }, {
    group = group,
    callback = M.reposition,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if state and tonumber(event.match) == state.win then
        M.close()
      end
    end,
  })
  return true
end

return M
