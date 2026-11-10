-- Small standalone windows: the help sheet and log viewing.
local layout = require("acp.layout")
local log = require("acp.log")

local M = {}

local HELP_LINES = {
  "# acp.nvim",
  "",
  "Composer",
  "  <C-s>     send",
  "  <C-c>     cancel the current turn",
  "",
  "Transcript",
  "  i / <C-s> focus the composer",
  "  <Tab>     expand or collapse a tool block",
  "  <CR>      open the file location under the cursor",
  "  [b / ]b   previous / next block",
  "  G / gg    newest / oldest message",
  "  S         attach the current selection",
  "  F         attach the current file",
  "  R         attach diagnostics",
  "  M / m     pick model / mode",
  "  <C-n>     new session",
  "  L         pick a stored session",
  "  q         hide the panel",
  "",
  "The panel hides without stopping the agent.",
}

---Open the keymap cheat sheet in a floating window.
function M.show_help()
  local lines = HELP_LINES
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  -- Closing the window must not leave the buffer behind; repeated `:Acp help`
  -- used to accumulate one hidden buffer per invocation.
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(70, vim.o.columns - 8)
  local height = math.min(#lines, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " acp.nvim ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
end

---Open the log file in the last non-ACP window.
---@param notify fun(message: string, level: integer|nil)
function M.show_log(notify)
  local path = log.path()
  if vim.fn.filereadable(path) ~= 1 then
    notify("no log file yet at " .. path, vim.log.levels.INFO)
    return
  end
  local target = layout.saved_focus()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

return M
