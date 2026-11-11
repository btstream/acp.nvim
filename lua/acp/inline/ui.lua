-- One scoped prompt float. Closing it by any route notifies the owner; all
-- autocmds/buffers are destroyed together. No global redraw hooks accumulate.
local M = {}
local state
local function geometry(s)
  if not vim.api.nvim_win_is_valid(s.source) then
    return nil
  end
  local p = vim.api.nvim_win_get_position(s.source)
  local screen = vim.fn.screenpos(s.source, s.row + 1, 1)
  local height = math.max(1, math.min(3, vim.o.lines - 5))
  local width = math.max(1, math.min(72, vim.api.nvim_win_get_width(s.source) - 2, vim.o.columns - 4))
  local anchor = screen.row > 0 and screen.row - 1 or p[1]
  local row = anchor >= height + 2 and anchor - height - 2 or anchor + 1
  row = math.max(0, math.min(row, vim.o.lines - height - 3))
  local col = math.max(0, math.min(p[2], vim.o.columns - width - 2))
  return { relative = "editor", row = row, col = col, width = width, height = height }
end
function M.text()
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end
function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end
function M.close(reason)
  if not state then
    return
  end
  local s = state
  local text = M.text()
  state = nil
  pcall(vim.api.nvim_del_augroup_by_id, s.group)
  local focused = vim.api.nvim_get_current_win() == s.win
  if vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if vim.api.nvim_buf_is_valid(s.buf) then
    pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  end
  if focused and vim.api.nvim_win_is_valid(s.source) then
    vim.api.nvim_set_current_win(s.source)
  end
  if reason ~= "submit" and s.on_close then
    s.on_close(text)
  end
end
function M.reposition()
  if not state then
    return
  end
  local g = geometry(state)
  if not g or not vim.api.nvim_win_is_valid(state.win) then
    return M.close()
  end
  pcall(vim.api.nvim_win_set_config, state.win, g)
end
function M.set_status(text)
  if M.is_open() then
    vim.api.nvim_win_set_config(state.win, { title = " ACP Inline · " .. text .. " ", title_pos = "left" })
  end
end
function M.open(opts)
  if not vim.api.nvim_win_is_valid(opts.source) then
    return false
  end
  M.close()
  local s = { source = opts.source, row = opts.row, on_close = opts.on_close }
  local g = geometry(s)
  if not g then
    return false
  end
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = "wipe"
  vim.bo[s.buf].buftype = "nofile"
  vim.bo[s.buf].swapfile = false
  vim.bo[s.buf].filetype = "acp_inline"
  if opts.text then
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, vim.split(opts.text, "\n", { plain = true }))
  end
  g.style = "minimal"
  g.border = "rounded"
  g.title = " ACP Inline · " .. opts.title .. " "
  g.title_pos = "left"
  local ok, win = pcall(vim.api.nvim_open_win, s.buf, true, g)
  if not ok then
    vim.api.nvim_buf_delete(s.buf, { force = true })
    return false
  end
  s.win = win
  s.group = vim.api.nvim_create_augroup("AcpInlineUI" .. s.buf, { clear = true })
  state = s
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight = "Normal:AcpInlinePrompt,FloatBorder:AcpInlineBorder"
  local function send()
    local text = M.text()
    if vim.trim(text) ~= "" then
      opts.on_submit(text)
    end
  end
  vim.keymap.set({ "n", "i" }, "<CR>", send, { buffer = s.buf, desc = "Submit inline" })
  vim.keymap.set({ "n", "i" }, "<C-s>", send, { buffer = s.buf, desc = "Submit inline" })
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    M.close()
  end, { buffer = s.buf })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = s.buf })
  vim.keymap.set({ "n", "i" }, "<C-d>", function()
    if opts.on_toggle_review then
      M.set_status(opts.on_toggle_review())
    end
  end, { buffer = s.buf })
  vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized" }, { group = s.group, callback = M.reposition })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.group,
    callback = function(e)
      if state == s and (tonumber(e.match) == s.win or tonumber(e.match) == s.source) then
        M.close()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = s.group,
    buffer = s.buf,
    callback = function()
      if state == s then
        M.close()
      end
    end,
  })
  vim.cmd("startinsert")
  return true
end
return M
