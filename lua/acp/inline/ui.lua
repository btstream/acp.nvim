-- One scoped prompt float. Closing it by any route notifies the owner; all
-- autocmds/buffers are destroyed together. No global redraw hooks accumulate.
local M = {}
local anchor = require("acp.inline.anchor")
local state

local function window_opts(cfg)
  return (cfg and cfg.inline and cfg.inline.window) or {}
end

---Float geometry for the current state. With `follow_cursor` the source cursor is
---sampled on every call; otherwise the cell captured at open time is reused so
---scrolling does not drag the prompt along.
---@param s table
---@return table|nil
local function geometry(s)
  local opts = window_opts(s.config)
  local prompt = opts.prompt or {}
  s.prompt = prompt
  local g = anchor.place({
    source = s.source,
    cursor = s.cursor,
    anchor_cell = (prompt.follow_cursor == false) and s.anchor_cell or nil,
    placement = prompt.placement or "cursor",
    width = prompt.width or 72,
    height = prompt.height or 3,
    offset = prompt.offset,
  })
  if not g then
    return nil
  end
  g.style = (opts.style == "default") and nil or "minimal"
  g.border = opts.border or "rounded"
  g.title_pos = opts.title_pos or "left"
  return g
end

---`winhighlight` mapping for the chrome. `style = "minimal"` installs its own
---Normal/FloatBorder mapping, so this must be assigned after the window exists.
---@param cfg table|nil
---@return string
local function winhighlight(cfg)
  local groups = window_opts(cfg).highlights or {}
  local normal = groups.normal or "AcpInlinePrompt"
  local border = groups.border or "AcpInlineBorder"
  local title = groups.title or "AcpInlineTitle"
  return table.concat({
    "Normal:" .. normal,
    "NormalNC:" .. normal,
    "FloatBorder:" .. border,
    "FloatTitle:" .. title,
  }, ",")
end

local function title_text(s, status)
  return " ACP Inline · " .. (status or s.status or "") .. " "
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
  g.title = title_text(state)
  -- Avoid a `set_config` (and its redraw work) when nothing moved.
  local last = state.geometry
  if last and last.row == g.row and last.col == g.col and last.width == g.width and last.height == g.height then
    return
  end
  state.geometry = g
  pcall(vim.api.nvim_win_set_config, state.win, g)
end
function M.set_status(text)
  if not M.is_open() then
    return
  end
  state.status = text
  local opts = window_opts(state.config)
  pcall(vim.api.nvim_win_set_config, state.win, { title = title_text(state), title_pos = opts.title_pos or "left" })
end
function M.open(opts)
  if not vim.api.nvim_win_is_valid(opts.source) then
    return false
  end
  M.close()
  local s = { source = opts.source, config = opts.config, status = opts.title, on_close = opts.on_close }
  s.anchor_cell = anchor.anchor(opts.source)
  local g = geometry(s)
  if not g then
    return false
  end
  s.geometry = g
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = "wipe"
  vim.bo[s.buf].buftype = "nofile"
  vim.bo[s.buf].swapfile = false
  vim.bo[s.buf].filetype = "acp_inline"
  if opts.text then
    vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, vim.split(opts.text, "\n", { plain = true }))
  end
  g.title = title_text(s)
  local ok, win = pcall(vim.api.nvim_open_win, s.buf, true, g)
  if not ok then
    vim.api.nvim_buf_delete(s.buf, { force = true })
    return false
  end
  s.win = win
  s.group = vim.api.nvim_create_augroup("AcpInlineUI" .. s.buf, { clear = true })
  state = s
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight = winhighlight(s.config)
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
  -- Re-anchor when the source scrolls or the layout changes. `WinScrolled`
  -- fires for the float too, so only the source window is honoured.
  vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized" }, {
    group = s.group,
    callback = function(event)
      if event.match == nil or event.match == "" or tonumber(event.match) == s.source then
        M.reposition()
      end
    end,
  })
  if s.prompt.follow_cursor ~= false then
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = s.group,
      callback = function()
        if vim.api.nvim_get_current_win() == s.source then
          M.reposition()
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.group,
    callback = function(event)
      if state == s and (tonumber(event.match) == s.win or tonumber(event.match) == s.source) then
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
