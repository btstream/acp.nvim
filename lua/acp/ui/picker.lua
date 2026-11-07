-- Floating picker used for models, modes, sessions and permissions.
--
-- Typing filters the list (fuzzy substring match), `j`/`k`/`<C-n>`/`<C-p>`
-- move, `<CR>` selects, `<Esc>` cancels. Keeping a filter is essential for
-- providers that expose a hundred or more models.
local M = {}

---@class AcpPickerItem
---@field label string
---@field description string|nil
---@field value any

---Case-insensitive subsequence match, the same idea as a fuzzy finder.
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
    local char = needle:sub(i, i)
    local found = hay:find(char, pos, true)
    if not found then
      return false
    end
    pos = found + 1
  end
  return true
end

---@param opts {title: string, items: AcpPickerItem[], on_choice: fun(value: any), on_cancel?: fun(), width?: integer, height?: integer, format?: fun(item: AcpPickerItem): string, filter?: boolean}
function M.select(opts)
  local all_items = opts.items or {}
  if #all_items == 0 then
    vim.notify("acp.nvim: nothing to select", vim.log.levels.WARN)
    return
  end

  local filter_enabled = opts.filter ~= false and #all_items > 8
  local max_width = math.max(40, math.min(96, vim.o.columns - 12))
  local width = opts.width or max_width
  local max_height = opts.height or math.min(#all_items, 14)
  local height = math.max(1, max_height)
  -- One extra line holds the filter prompt when filtering is on.
  local prompt_rows = filter_enabled and 1 or 0

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local format = opts.format or function(item)
    return item.label
  end

  local query = ""
  local visible = all_items
  local ns = vim.api.nvim_create_namespace("acp_picker")
  local settled = false
  local prev_win = vim.api.nvim_get_current_win()

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    width = width,
    height = height + prompt_rows,
    row = math.max(0, math.floor((vim.o.lines - height - prompt_rows) / 2) - 1),
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

  local function cancel()
    if settled then
      return
    end
    settled = true
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function choose()
    if settled then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(win)[1]
    local item = visible[cursor]
    if not item then
      return
    end
    settled = true
    close()
    if opts.on_choice then
      opts.on_choice(item.value, item)
    end
  end

  local function render()
    local lines = {}
    for _, item in ipairs(visible) do
      lines[#lines + 1] = format(item)
    end
    if #lines == 0 then
      lines[1] = "  no match"
    end
    if filter_enabled then
      lines[#lines + 1] = "❯ " .. query
    end
    local prompt_line = #lines
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local cursor = math.min(vim.api.nvim_win_get_cursor(win)[1], math.max(1, #visible))
    if #visible > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { cursor, 0 })
      local line = visible[cursor]
      local text = lines[cursor] or ""
      vim.api.nvim_buf_set_extmark(buf, ns, cursor - 1, 0, {
        end_row = cursor - 1,
        end_col = #text,
        hl_group = "AcpSelection",
      })
      if line and line.description and line.description ~= "" then
        local desc = line.description:gsub("\n", " ")
        if #desc > width - 6 then
          desc = desc:sub(1, width - 8) .. "…"
        end
        vim.api.nvim_buf_set_extmark(buf, ns, cursor - 1, 0, {
          virt_text = { { desc, "AcpMuted" } },
          virt_text_pos = "eol",
        })
      end
    end
    if filter_enabled then
      vim.api.nvim_buf_set_extmark(buf, ns, prompt_line - 1, 0, {
        end_row = prompt_line - 1,
        end_col = #(lines[prompt_line] or ""),
        hl_group = "AcpToolbarAccent",
      })
    end
    -- Keep the window height in sync with the filtered list.
    local target = math.max(1, math.min(max_height, math.max(1, #visible))) + prompt_rows
    pcall(vim.api.nvim_win_set_height, win, target)
  end

  local function refilter()
    if query == "" then
      visible = all_items
    else
      local matched = {}
      for _, item in ipairs(all_items) do
        local haystack = (item.label or "") .. " " .. (item.description or "")
        if fuzzy(query, haystack) then
          matched[#matched + 1] = item
        end
      end
      visible = matched
    end
    render()
  end

  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map("<CR>", choose)
  map("<Esc>", cancel)
  map("<C-c>", cancel)
  map("<C-n>", function()
    if vim.api.nvim_win_get_cursor(win)[1] < #visible then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_win_get_cursor(win)[1] + 1, 0 })
      render()
    end
  end)
  map("<C-p>", function()
    if vim.api.nvim_win_get_cursor(win)[1] > 1 then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_win_get_cursor(win)[1] - 1, 0 })
      render()
    end
  end)
  map("j", function()
    if vim.api.nvim_win_get_cursor(win)[1] < #visible then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_win_get_cursor(win)[1] + 1, 0 })
      render()
    end
  end)
  map("k", function()
    if vim.api.nvim_win_get_cursor(win)[1] > 1 then
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_win_get_cursor(win)[1] - 1, 0 })
      render()
    end
  end)
  map("G", function()
    if #visible > 0 then
      vim.api.nvim_win_set_cursor(win, { #visible, 0 })
      render()
    end
  end)
  map("gg", function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    render()
  end)
  map("<BS>", function()
    if query ~= "" then
      query = query:sub(1, -2)
      refilter()
    end
  end)

  if filter_enabled then
    -- Single character keys act as the filter query.
    for _, char in ipairs(vim.fn.split("abcdefghijklmnopqrstuvwxyz0123456789/-_.@", "\\zs")) do
      vim.keymap.set("n", char, function()
        query = query .. char
        refilter()
      end, { buffer = buf, nowait = true, silent = true })
    end
  end

  render()

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      cancel()
    end,
  })
end

---Yes/no confirmation.
---@param title string
---@param on_choice fun(choice: string)
function M.confirm(title, on_choice)
  M.select({
    title = title,
    items = {
      { label = "Yes", value = "yes" },
      { label = "No", value = "no" },
    },
    on_choice = on_choice,
    width = 40,
    filter = false,
  })
end

return M
