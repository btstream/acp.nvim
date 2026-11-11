-- Apply only changed ranges. Never redraw a preview into the source buffer or
-- rewind user undo history. Every accepted batch is a new, single undo entry.
local M = {}
local result = require("acp.inline.result")

function M.begin(buf)
  return vim.api.nvim_buf_call(buf, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
    return vim.fn.undotree().seq_cur
  end)
end

function M.hunks(buf, original, hunks)
  local valid, reason = result.verify({ bufnr = buf, original = original })
  if not valid then
    return false, reason
  end
  if #hunks == 0 then
    return true
  end
  local seq = M.begin(buf)
  local ordered = vim.deepcopy(hunks)
  table.sort(ordered, function(a, b)
    return a.start > b.start
  end)
  local wrote = false
  local ok, err = pcall(function()
    vim.api.nvim_buf_call(buf, function()
      for _, h in ipairs(ordered) do
        if wrote then
          vim.cmd("undojoin")
        end
        -- Refine equal-row replacements to byte columns, preserving marks
        -- outside the actual changed text even on the same source line.
        if #h.old_lines == 1 and #h.new_lines == 1 then
          local a, b = h.old_lines[1], h.new_lines[1]
          local prefix = 0
          while prefix < math.min(#a, #b) and a:byte(prefix + 1) == b:byte(prefix + 1) do
            prefix = prefix + 1
          end
          while prefix > 0 and a:byte(prefix + 1) and a:byte(prefix + 1) >= 128 and a:byte(prefix + 1) < 192 do
            prefix = prefix - 1
          end
          local suffix = 0
          while suffix < math.min(#a, #b) - prefix and a:byte(#a - suffix) == b:byte(#b - suffix) do
            suffix = suffix + 1
          end
          while suffix > 0 and a:byte(#a - suffix + 1) >= 128 and a:byte(#a - suffix + 1) < 192 do
            suffix = suffix - 1
          end
          vim.api.nvim_buf_set_text(buf, h.start, prefix, h.start, #a - suffix, { b:sub(prefix + 1, #b - suffix) })
        else
          vim.api.nvim_buf_set_lines(buf, h.start, h.start + #h.old_lines, false, h.new_lines)
        end
        wrote = true
      end
    end)
  end)
  if not ok then
    if wrote and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_call(buf, function()
        pcall(vim.cmd, "silent undo " .. seq)
      end)
    end
    return false, tostring(err)
  end
  return true
end

function M.write(buf, lines, row)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false, "buffer was closed"
  end
  local original = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ok, err = M.hunks(buf, original, result.hunks(original, lines))
  if not ok then
    return false, err
  end
  -- Do not change focus, cursor, or scroll in a window the user left.
  if vim.api.nvim_get_current_buf() == buf then
    row = math.max(0, math.min(row or 0, vim.api.nvim_buf_line_count(buf) - 1))
    vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  end
  return true
end
return M
