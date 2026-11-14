-- Lock the source buffer for the duration of an inline turn.
--
-- An inline result is computed against a snapshot of the buffer and the disk.
-- Editing or saving the source meanwhile makes `result.verify` refuse the
-- result, even though nothing is wrong. The turn therefore makes the buffer
-- read-only and intercepts writes until it finishes; a write would otherwise
-- put content on disk that the reviewed result does not know about.
local M = {}

local locks = {}

local function group_for(bufnr)
  return "AcpInlineLock" .. bufnr
end

---Whether `bufnr` is currently locked by an inline turn.
---@param bufnr integer
---@return boolean
function M.locked(bufnr)
  return locks[bufnr] ~= nil
end

---Make `bufnr` read-only and drop writes, remembering the previous state.
---
---Safe to call twice: a second call keeps the first saved state.
---@param bufnr integer
---@return boolean locked
function M.lock(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if locks[bufnr] then
    return true
  end
  locks[bufnr] = { modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr }) }
  local group = vim.api.nvim_create_augroup(group_for(bufnr), { clear = true })
  locks[bufnr].group = group
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.notify(
        "acp.nvim: inline edit in progress; the file is locked until it finishes (:Acp inline-stop to cancel)",
        vim.log.levels.WARN
      )
    end,
  })
  -- A wiped buffer takes its local autocmds with it; forget the record so a
  -- later unlock does not try to restore options on a dead buffer.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      locks[bufnr] = nil
    end,
  })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  return true
end

---Restore the remembered state and remove the write interception.
---
---Safe to call repeatedly, on a wiped buffer, or when never locked.
---@param bufnr integer
function M.unlock(bufnr)
  local saved = locks[bufnr]
  if not saved then
    return
  end
  locks[bufnr] = nil
  if saved.group then
    pcall(vim.api.nvim_del_augroup_by_id, saved.group)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_set_option_value, "modifiable", saved.modifiable, { buf = bufnr })
  end
end

return M
