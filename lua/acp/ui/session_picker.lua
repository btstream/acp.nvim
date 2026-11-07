-- Interactive session browser.
--
-- This uses its own buffer instead of `vim.ui.select` because `vim.ui.select`
-- has no per-item keybinding hook, and deleting a row with <C-d> is a core part
-- of this dialog. Other selectors (models, modes, permissions) keep using
-- `vim.ui.select`.
local icons = require("acp.ui.icons")
local M = {}

---Case-insensitive subsequence match.
---@param needle string
---@param haystack string
---@return boolean
local function fuzzy(needle, haystack)
  if needle == "" then
    return true
  end
  local hay = haystack:lower()
  local pos = 1
  for i = 1, #needle do
    local found = hay:find(needle:sub(i, i), pos, true)
    if not found then
      return false
    end
    pos = found + 1
  end
  return true
end

---Format an ISO-ish timestamp for display.
---@param value any
---@return string
local function short_time(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  -- "2026-11-07T10:49:33.899Z" -> "2026-11-07 10:49"
  local date, time = value:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if date and time then
    return date .. " " .. time
  end
  return value:sub(1, 16)
end

---@class AcpSessionPickerOpts
---@field sessions table[] entries from session/list
---@field current_id string|nil
---@field can_delete boolean
---@field on_open fun(session_id: string)
---@field on_delete fun(session_id: string, done: fun(ok: boolean))
---@field refresh fun(cb: fun(sessions: table[])) fetch the latest list

---Open the session browser.
---@param opts AcpSessionPickerOpts
function M.open(opts)
  local icon_set = icons.get(opts.use_icons)
  local sessions = vim.deepcopy(opts.sessions or {})
  local query = ""
  local visible = sessions
  local ns = vim.api.nvim_create_namespace("acp_sessions")
  local settled = false
  local prev_win = vim.api.nvim_get_current_win()
  local busy = false
  local status_message = ""

  local max_height = math.min(math.max(#sessions, 3), 18)
  local width = math.max(46, math.min(100, vim.o.columns - 12))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "acp_sessions"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Sessions ",
    title_pos = "center",
    width = width,
    height = max_height + 2,
    row = math.max(0, math.floor((vim.o.lines - max_height - 2) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if prev_win and vim.api.nvim_win_is_valid(prev_win) and prev_win ~= win then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  local function finish(fn, ...)
    if settled then
      return
    end
    settled = true
    close()
    if fn then
      fn(...)
    end
  end

  local function reset_filter()
    query = ""
    visible = sessions
  end

  local function label_of(item)
    return type(item.title) == "string" and item.title ~= "" and item.title or item.sessionId
  end

  local function render()
    local lines = {}
    local marks = {}
    for _, item in ipairs(visible) do
      local is_current = item.sessionId == opts.current_id
      local marker = is_current and (icon_set.arrow_right .. " ") or "  "
      -- A buffer line cannot contain a newline; agent supplied titles may.
      local title = label_of(item):gsub("[\r\n]", " ")
      lines[#lines + 1] = marker .. title
      marks[#marks + 1] = { item = item, current = is_current, title = title }
    end
    if #lines == 0 then
      lines[1] = "  no matching sessions"
      marks[1] = nil
    end
    lines[#lines + 1] = string.rep("─", math.max(1, width - 2))
    lines[#lines + 1] = (query ~= "" and ("Search: " .. query) or "Type to filter") .. "   " .. status_message

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local cursor = math.min(vim.api.nvim_win_get_cursor(win)[1], math.max(1, #visible))
    if #visible > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { cursor, 0 })
      local line_no = cursor
      local text = lines[line_no] or ""
      vim.api.nvim_buf_set_extmark(buf, ns, line_no - 1, 0, {
        end_row = line_no - 1,
        end_col = #text,
        hl_group = "AcpSelection",
      })
      local meta = marks[line_no]
      if meta then
        local when_text = short_time(meta.item.updatedAt or meta.item.createdAt)
        local desc = when_text
        if meta.current then
          desc = desc .. "  " .. icon_set.check_circle .. " current"
        end
        if desc ~= "" then
          vim.api.nvim_buf_set_extmark(buf, ns, line_no - 1, 0, {
            virt_text = { { desc, "AcpMuted" } },
            virt_text_pos = "eol",
          })
        end
      end
    end
    local warn_line = #lines - 1
    vim.api.nvim_buf_set_extmark(buf, ns, warn_line, 0, {
      end_row = warn_line,
      end_col = #(lines[#lines] or ""),
      hl_group = query ~= "" and "AcpToolbarAccent" or "AcpMuted",
    })
    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, {
      end_row = #lines - 1,
      end_col = #(lines[#lines] or ""),
      hl_group = "AcpMuted",
    })

    local target = math.max(1, math.min(max_height, math.max(1, #visible))) + 2
    pcall(vim.api.nvim_win_set_height, win, target)
  end

  local function refilter()
    if query == "" then
      visible = sessions
    else
      local matched = {}
      for _, item in ipairs(sessions) do
        if fuzzy(query, label_of(item) .. " " .. item.sessionId) then
          matched[#matched + 1] = item
        end
      end
      visible = matched
    end
    render()
  end

  local function current_item()
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    return visible[cursor]
  end

  local function move(delta)
    if busy or #visible == 0 then
      return
    end
    local row = vim.api.nvim_win_get_cursor(win)[1] + delta
    if row >= 1 and row <= #visible then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      render()
    end
  end

  ---Delete the session under the cursor, asking for confirmation first.
  ---
  ---`vim.ui.select` may resolve asynchronously (telescope, snacks, ...), so the
  ---work continues in its callback rather than blocking here.
  local function delete_current()
    if busy then
      return
    end
    local item = current_item()
    if not item then
      return
    end
    if not opts.can_delete then
      status_message = "this agent cannot delete sessions"
      render()
      return
    end

    local target_id = item.sessionId
    local target_title = label_of(item)

    vim.ui.select({ "Delete", "Cancel" }, {
      prompt = string.format('Delete "%s"?', target_title),
      kind = "acp_confirm_delete",
    }, function(choice)
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        pcall(vim.api.nvim_set_current_win, win)
        if choice ~= "Delete" then
          status_message = ""
          render()
          return
        end

        busy = true
        status_message = "deleting..."
        render()
        opts.on_delete(target_id, function(ok)
          if not vim.api.nvim_win_is_valid(win) then
            return
          end
          busy = false
          if not ok then
            status_message = "delete failed"
            render()
            return
          end
          local kept = {}
          for _, existing in ipairs(opts.sessions or {}) do
            if existing.sessionId ~= target_id then
              kept[#kept + 1] = existing
            end
          end
          opts.sessions = kept
          sessions = kept
          status_message = "deleted"
          refilter()
        end)
      end)
    end)
  end

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map("<CR>", function()
    if busy then
      return
    end
    local item = current_item()
    if item then
      finish(opts.on_open, item.sessionId)
    end
  end, "open session")
  map("<C-d>", delete_current, "delete session")
  map("<Esc>", function()
    finish(nil)
  end, "close")
  map("q", function()
    finish(nil)
  end, "close")
  map("<C-c>", function()
    finish(nil)
  end, "close")
  map("j", function()
    move(1)
  end, "next")
  map("k", function()
    move(-1)
  end, "previous")
  map("<C-n>", function()
    move(1)
  end, "next")
  map("<C-p>", function()
    move(-1)
  end, "previous")
  map("G", function()
    if #visible > 0 then
      vim.api.nvim_win_set_cursor(win, { #visible, 0 })
      render()
    end
  end, "last")
  map("gg", function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    render()
  end, "first")
  map("<BS>", function()
    if query ~= "" then
      query = query:sub(1, -2)
      refilter()
    end
  end, "erase filter")
  map("<C-u>", function()
    reset_filter()
    refilter()
  end, "clear filter")

  for _, char in ipairs(vim.fn.split("abcdefghijklmnopqrstuvwxyz0123456789/-_.@", "\\zs")) do
    vim.keymap.set("n", char, function()
      query = query .. char
      refilter()
    end, { buffer = buf, nowait = true, silent = true })
  end

  render()

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  return {
    win = win,
    buf = buf,
    delete_current = delete_current,
    symbols = function()
      return vim.tbl_map(function(l)
        return l
      end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end,
  }
end

return M
