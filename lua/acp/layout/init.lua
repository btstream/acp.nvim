-- Window placement. Native mode owns the layout; external mode defers to a manager (edgy).
local log = require("acp.log")

local M = {}

local state = {
  backend = "native",
  position = "right",
  config = nil,
  saved_win = nil,
  augroup = nil,
  -- Windows owned by the panel; only these may stay locked to an ACP buffer.
  views = {},
}

function M.setup(config)
  state.config = config
  state.backend = config.layout.backend
  state.position = config.layout.position
  M.install_lock_guard()
end

---Whether a buffer belongs to the ACP panel.
---@param buf integer
---@return boolean
function M.is_panel_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ft = vim.bo[buf].filetype
  return ft == "acp_chat" or ft == "acp_input"
end

---Guard against the ways a locked ACP window could still be repurposed.
---
---`winfixbuf` blocks `:edit`/`:bnext`/`nvim_win_set_buf`, but `:split` from an
---ACP window creates a *new* window that inherits the ACP buffer while
----`winfixbuf` is off. Without this guard the user would end up with a second,
---fully editable window pointing at the transcript.
function M.install_lock_guard()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("AcpWindowLock", { clear = true })

  vim.api.nvim_create_autocmd({ "WinEnter", "WinNew" }, {
    group = state.augroup,
    callback = function()
      if not state.config or state.config.layout.lock_buffer == false then
        return
      end
      if vim.fn.exists("+winfixbuf") ~= 1 then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if not win or not vim.api.nvim_win_is_valid(win) then
        return
      end
      -- Only windows actually showing an ACP buffer are relevant.
      if not M.is_panel_buffer(vim.api.nvim_win_get_buf(win)) then
        return
      end
      if vim.api.nvim_get_option_value("winfixbuf", { win = win }) then
        return
      end
      -- WinEnter/WinNew fire for a window created by `:split` too. Such a
      -- window inherits the ACP buffer, which would leave the user with a
      -- locked and unusable duplicate. Hand it a fresh scratch buffer instead
      -- so splitting away from the panel behaves like a normal split.
      local is_managed = false
      for _, view in ipairs({ "chat", "input" }) do
        local current = state.views and state.views[view]
        if current and current == win then
          is_managed = true
        end
      end
      if not is_managed then
        local scratch = vim.api.nvim_create_buf(false, true)
        vim.bo[scratch].bufhidden = "wipe"
        vim.bo[scratch].buftype = "nofile"
        vim.api.nvim_win_set_buf(win, scratch)
        return
      end
      M.lock_window(win)
    end,
  })
end

---Window options applied to ACP windows in native mode.
---@param win integer
---@param kind "chat"|"input"
function M.apply_window_options(win, kind)
  local ok = pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    -- A single space keeps the text column aligned with a normal buffer while
    -- hiding signs, numbers and folds entirely.
    vim.wo[win].statuscolumn = " "
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].spell = false
    vim.wo[win].list = false
    vim.wo[win].wrap = state.config.ui.wrap
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
    -- The transcript title bar shares the window's own background, so `WinBar`
    -- maps to `AcpNormal` rather than to the statusline group. The composer
    -- keeps `AcpToolbar`: its bar is a toolbar, not a header.
    if kind == "chat" then
      vim.wo[win].winhighlight = "Normal:AcpNormal,NormalNC:AcpNormal,WinBar:AcpNormal,WinBarNC:AcpNormal"
    else
      vim.wo[win].winhighlight = "Normal:AcpNormal,NormalNC:AcpNormal,WinBar:AcpToolbar,WinBarNC:AcpToolbar"
    end
    if kind == "chat" then
      vim.wo[win].winfixwidth = state.backend == "native"
      vim.wo[win].winfixheight = false
      vim.wo[win].cursorline = false
      vim.wo[win].scrolloff = 2
      -- Inline Markdown delimiters are hidden through `conceal` extmarks. The
      -- cursor must not reveal them, otherwise the transcript jumps whenever it
      -- is focused.
      vim.wo[win].conceallevel = 2
      vim.wo[win].concealcursor = "nvic"
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

---Lock a window to its current buffer.
---
---`winfixbuf` makes `:edit`, `:bnext`, plugin "open in this window" helpers and
---`nvim_win_set_buf` fail instead of silently replacing the transcript or the
---composer with an unrelated file. Closing the window is still allowed.
---@param win integer
---@return boolean applied
function M.lock_window(win)
  if not state.config or state.config.layout.lock_buffer == false then
    return false
  end
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if vim.fn.exists("+winfixbuf") ~= 1 then
    log.debug("winfixbuf is unavailable; ACP windows cannot be locked")
    return false
  end
  local ok = pcall(vim.api.nvim_set_option_value, "winfixbuf", true, { win = win })
  return ok
end

---Temporarily unlock a window so acp.nvim itself can set its buffer.
---@param win integer
---@param fn fun()
function M.with_window_unlocked(win, fn)
  local locked = false
  if win and vim.api.nvim_win_is_valid(win) and vim.fn.exists("+winfixbuf") == 1 then
    locked = vim.api.nvim_get_option_value("winfixbuf", { win = win })
    if locked then
      pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { win = win })
    end
  end
  local ok, err = pcall(fn)
  if locked and win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_option_value, "winfixbuf", true, { win = win })
  end
  if not ok then
    error(err, 0)
  end
end

---Set a window's buffer even when it is locked.
---@param win integer
---@param buf integer
---@return boolean ok
function M.set_window_buffer(win, buf)
  local ok = pcall(M.with_window_unlocked, win, function()
    vim.api.nvim_win_set_buf(win, buf)
  end)
  return ok
end

---Create both panel windows and apply the configured sizes.
---
---The two windows have to be created before either is resized. Splitting while
---'equalalways' is on rebalances every window, so the panel width requested at
---creation time is discarded as soon as the second split appears. 'equalalways'
---is therefore turned off for the duration of the setup and restored right
---after, and the final sizes are applied once both windows exist.
---@param chat_buf integer
---@param input_buf integer
---@return integer|nil chat_win
---@return integer|nil input_win
function M.create_panel(chat_buf, input_buf)
  local total = vim.o.columns
  local width = require("acp.config").panel_width(state.config, total)
  local horizontal = state.position == "left" and "topleft " or "botright "
  local cmd
  if state.backend == "native" then
    cmd = horizontal .. width .. "vsplit"
  else
    cmd = horizontal .. "vsplit"
  end

  -- Keep the split sizes stable while the panel is built.
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false

  local ok_chat = pcall(vim.cmd, cmd)
  if not ok_chat then
    vim.o.equalalways = equalalways
    return nil, nil
  end
  local chat = vim.api.nvim_get_current_win()

  local ok_input = pcall(vim.cmd, "belowright split")
  if not ok_input then
    vim.o.equalalways = equalalways
    return nil, nil
  end
  local input = vim.api.nvim_get_current_win()

  -- Buffers and window options first, sizes last, and 'equalalways' restored
  -- only after the sizes are in place: turning it back on rebalances every
  -- window, which would discard the width we just set.
  M.set_window_buffer(chat, chat_buf)
  M.set_window_buffer(input, input_buf)
  state.views.chat = chat
  state.views.input = input
  M.apply_window_options(chat, "chat")
  M.apply_window_options(input, "input")
  M.lock_window(chat)
  M.lock_window(input)

  if state.backend == "native" then
    pcall(vim.api.nvim_win_set_width, chat, width)
    local height = math.max(state.config.layout.min_input_height, state.config.layout.input_height)
    height = math.min(height, state.config.layout.max_input_height)
    pcall(vim.api.nvim_win_set_height, input, height)
  end

  vim.o.equalalways = equalalways

  return chat, input
end

---Create the chat window on its own.
---
---Only the transcript window is created; the composer is left alone so
---restoring one view cannot leave a stray window (and buffer) behind.
---@param buf integer
---@return integer|nil win
function M.create_chat_win(buf)
  local total = vim.o.columns
  local width = require("acp.config").panel_width(state.config, total)
  local horizontal = state.position == "left" and "topleft " or "botright "
  local cmd = state.backend == "native" and (horizontal .. width .. "vsplit") or (horizontal .. "vsplit")

  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  local ok = pcall(vim.cmd, cmd)
  vim.o.equalalways = equalalways
  if not ok then
    return nil
  end

  local win = vim.api.nvim_get_current_win()
  M.set_window_buffer(win, buf)
  state.views.chat = win
  M.apply_window_options(win, "chat")
  M.lock_window(win)
  if state.backend == "native" then
    pcall(vim.api.nvim_win_set_width, win, width)
  end
  return win
end

---Create the composer window below the chat window.
---@param buf integer
---@param chat_win integer|nil
---@return integer|nil win
function M.create_input_win(buf, chat_win)
  -- Used when only the composer needs restoring; reuse the existing chat window.
  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    vim.api.nvim_set_current_win(chat_win)
  end
  local ok = pcall(vim.cmd, "belowright split")
  if not ok then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  M.set_window_buffer(win, buf)
  state.views.input = win
  M.apply_window_options(win, "input")
  M.lock_window(win)
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

---Forget a panel window (called when it is closed).
---@param win integer
function M.forget_window(win)
  for name, current in pairs(state.views) do
    if current == win then
      state.views[name] = nil
    end
  end
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
