-- Small standalone windows: the help sheet and log viewing.
local layout = require("acp.layout")
local log = require("acp.log")
local keymaps = require("acp.ui.keymaps")

local M = {}

---Header and footer of the help sheet. The key list in between is generated
---from the live `keymaps` configuration, so a rebound action never leaves the
---sheet describing the default.
local HELP_INTRO = { "# acp.nvim", "" }
local HELP_OUTRO = { "", "The panel hides without stopping the agent." }

---Width of the key column, so the descriptions line up whatever the keys are.
local HELP_KEY_COLUMN = 20

---Render the cheat sheet for a resolved `keymaps` table.
---@param keymaps_config table|nil
---@return string[]
function M.help_lines(keymaps_config)
  local lines = {}
  vim.list_extend(lines, HELP_INTRO)

  for _, view in ipairs({ "input", "chat" }) do
    local title = view == "input" and "Composer" or "Transcript"
    lines[#lines + 1] = title
    local entries = keymaps.help_entries(view, (keymaps_config or {})[view])
    for _, entry in ipairs(entries) do
      local keys = entry.keys
      if #keys < HELP_KEY_COLUMN then
        keys = keys .. string.rep(" ", HELP_KEY_COLUMN - #keys)
      end
      lines[#lines + 1] = "  " .. keys .. entry.desc
    end
    lines[#lines + 1] = ""
  end

  -- Drop the blank line the last view added before the footer.
  lines[#lines] = nil
  vim.list_extend(lines, HELP_OUTRO)
  return lines
end

---Open the keymap cheat sheet in a floating window.
---@param keymaps_config table|nil resolved `keymaps` configuration
function M.show_help(keymaps_config)
  local lines = M.help_lines(keymaps_config)
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
