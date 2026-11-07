-- Window placement. Native mode owns the layout; external mode defers to a manager (edgy).
local log = require("acp.log")

local M = {}

local state = {
  backend = "native",
  position = "right",
  config = nil,
  saved_win = nil,
}

function M.setup(config)
  state.config = config
  state.backend = config.layout.backend
  state.position = config.layout.position
end

---Window options applied to ACP windows in native mode.
---@param win integer
---@param kind "chat"|"input"
function M.apply_window_options(win, kind)
  local ok = pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].spell = false
    vim.wo[win].list = false
    vim.wo[win].wrap = state.config.ui.wrap
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    vim.wo[win].winhighlight = "Normal:AcpNormal,NormalNC:AcpNormal"
    if kind == "chat" then
      vim.wo[win].winfixwidth = state.backend == "native"
      vim.wo[win].winfixheight = false
      vim.wo[win].cursorline = false
      vim.wo[win].scrolloff = 2
    else
      vim.wo[win].winfixheight = state.backend == "native"
      vim.wo[win].winfixwidth = state.backend == "native"
      vim.wo[win].cursorline = false
      vim.wo[win].scrolloff = 1
      vim.wo[win].conceallevel = 0
    end
  end)
  if not ok then
    log.debug("failed to apply window options to %d", win)
  end
end

---Create the chat window.
---@param buf integer
---@return integer|nil win
function M.create_chat_win(buf)
  local total = vim.o.columns
  local width = require("acp.config").panel_width(state.config, total)
  local cmd
  if state.backend == "native" then
    cmd = (state.position == "left" and "topleft " or "botright ") .. width .. "vsplit"
  else
    cmd = (state.position == "left" and "topleft vsplit" or "botright vsplit")
  end
  local ok = pcall(vim.cmd, cmd)
  if not ok then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  M.apply_window_options(win, "chat")
  return win
end

---Create the composer window below the chat window.
---@param buf integer
---@param chat_win integer|nil
---@return integer|nil win
function M.create_input_win(buf, chat_win)
  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    vim.api.nvim_set_current_win(chat_win)
  end
  local ok = pcall(vim.cmd, "belowright split")
  if not ok then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  M.apply_window_options(win, "input")
  if state.backend == "native" then
    local height = math.max(state.config.layout.min_input_height, state.config.layout.input_height)
    height = math.min(height, state.config.layout.max_input_height)
    pcall(vim.api.nvim_win_set_height, win, height)
  end
  return win
end

---Remember the window to return focus to when the panel closes.
---ACP windows are never recorded, otherwise closing the panel could try to
---focus a window that is being closed.
function M.remember_focus()
  local win = vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  if ft == "acp_chat" or ft == "acp_input" then
    return
  end
  state.saved_win = win
end

---@return integer|nil
function M.saved_focus()
  if state.saved_win and vim.api.nvim_win_is_valid(state.saved_win) then
    return state.saved_win
  end
  return nil
end

function M.clear_saved_focus()
  state.saved_win = nil
end

---@return "native"|"external"
function M.backend()
  return state.backend
end

---@return table
function M.config()
  return state.config
end

return M
