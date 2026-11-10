-- Selectors for models, modes, sessions and permissions.
--
-- By default every choice goes through `vim.ui.select`, so whatever the user
-- already uses for that (telescope, fzf-lua, snacks.nvim, dressing, the plain
-- built-in prompt) applies here too. The built-in floating picker stays
-- available as an explicit opt-in.
local highlights = require("acp.ui.highlights")

-- Highlight groups of the plugin's own pickers, resolved once. Everything the
-- pickers draw uses these through `AcpPicker*`, so a user can restyle the
-- dialogs without touching the panel's groups.
local HL = highlights.picker

local M = {}

---@class AcpPickerItem
---@field label string
---@field description string|nil
---@field value any

---Case-insensitive subsequence match, returning the byte ranges it covered.
---
---Ranges are 0-based and half-open, ready to hand to `nvim_buf_set_extmark`.
---Adjacent characters are merged into one range so a multi-character match is a
---single highlight instead of one mark per letter.
---@param needle string
---@param haystack string
---@return {s: integer, e: integer}[]|nil ranges, or nil when there is no match
function M.fuzzy_ranges(needle, haystack)
  local ranges = {}
  if needle == "" then
    return ranges
  end
  local hay = haystack:lower()
  local pos = 1
  for i = 1, #needle do
    local found = hay:find(needle:sub(i, i), pos, true)
    if not found then
      return nil
    end
    local last = ranges[#ranges]
    if last and last.e == found - 1 then
      last.e = found
    else
      ranges[#ranges + 1] = { s = found - 1, e = found }
    end
    pos = found + 1
  end
  return ranges
end

---Case-insensitive subsequence match, the same idea as a fuzzy finder.
---@param needle string
---@param haystack string
---@return boolean
local function fuzzy(needle, haystack)
  return M.fuzzy_ranges(needle, haystack) ~= nil
end

---Format one item into a single line, keeping the description readable.
---@param item AcpPickerItem
---@param width integer|nil
---@return string
local function format_item(item, width)
  local label = item.label or tostring(item.value)
  if not item.description or item.description == "" then
    return label
  end
  local desc = item.description:gsub("%s*\n%s*", " ")
  if width and #desc > width then
    desc = desc:sub(1, math.max(1, width - 1)) .. "…"
  end
  return string.format("%s  %s", label, desc)
end

---Build the `format_item` callback handed to `vim.ui.select`.
---@param items AcpPickerItem[]
---@param opts {format?: fun(item: AcpPickerItem): string}
---@return fun(item: AcpPickerItem): string
local function make_formatter(items, opts)
  local columns = vim.o.columns
  local max_label = 0
  for _, item in ipairs(items) do
    local len = vim.fn.strdisplaywidth(item.label or "")
    if len > max_label then
      max_label = len
    end
  end
  max_label = math.min(max_label, math.max(20, columns - 30))
  return function(item)
    if opts.format then
      return opts.format(item)
    end
    return format_item(item, max_label)
  end
end

---Add the current-value marker used by the config option pickers.
---@param items AcpPickerItem[]
---@param current any
---@return AcpPickerItem[]
function M.mark_current(items, current)
  return items
end

---------------------------------------------------------------------------
-- Built-in floating picker (opt-in)
---------------------------------------------------------------------------

---@param opts {title: string, items: AcpPickerItem[], on_choice: fun(value: any), on_cancel?: fun(), width?: integer, height?: integer, format?: fun(item: AcpPickerItem): string, filter?: boolean}
local function internal_select(opts)
  local all_items = opts.items or {}
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
  -- `style = "minimal"` installs its own Normal/FloatBorder mapping, so the
  -- picker groups have to be applied after the window exists.
  vim.wo[win].winhighlight = highlights.picker_winhl()

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
      -- A buffer line cannot contain a newline; agent supplied labels may.
      lines[#lines + 1] = (format(item) or ""):gsub("[\r\n]", " ")
    end
    local empty = #lines == 0
    if empty then
      lines[1] = "  no match"
    end
    local prompt_line
    if filter_enabled then
      lines[#lines + 1] = "> " .. query
      prompt_line = #lines
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    ---Paint one row: the item's own group first, then the selection over it,
    ---then the filter matches on top. Neovim merges extmarks by priority, so a
    ---foreground-only override still combines with the row's background.
    ---@param row integer zero-based
    ---@param text string
    ---@param selected boolean
    local function paint_row(row, text, selected)
      if #text == 0 then
        return
      end
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_row = row,
        end_col = #text,
        hl_group = HL.item,
        priority = 5,
      })
      if selected then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          end_row = row,
          end_col = #text,
          hl_group = HL.selection,
          priority = 10,
        })
      end
      local ranges = query ~= "" and M.fuzzy_ranges(query, text) or nil
      for _, range in ipairs(ranges or {}) do
        vim.api.nvim_buf_set_extmark(buf, ns, row, range.s, {
          end_col = range.e,
          hl_group = HL.match,
          priority = 30,
        })
      end
    end

    if empty then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
        end_col = #lines[1],
        hl_group = HL.empty,
      })
    end

    local cursor = math.min(vim.api.nvim_win_get_cursor(win)[1], math.max(1, #visible))
    if #visible > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { cursor, 0 })
      for i = 1, #visible do
        paint_row(i - 1, lines[i] or "", i == cursor)
      end
      local line = visible[cursor]
      if line and line.description and line.description ~= "" then
        local desc = line.description:gsub("\n", " ")
        if #desc > width - 6 then
          desc = desc:sub(1, width - 8) .. "…"
        end
        vim.api.nvim_buf_set_extmark(buf, ns, cursor - 1, 0, {
          virt_text = { { desc, HL.description } },
          virt_text_pos = "eol",
        })
      end
    end
    if prompt_line then
      vim.api.nvim_buf_set_extmark(buf, ns, prompt_line - 1, 0, {
        end_row = prompt_line - 1,
        end_col = #(lines[prompt_line] or ""),
        hl_group = HL.prompt,
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
  local function move(delta)
    local row = vim.api.nvim_win_get_cursor(win)[1] + delta
    if row >= 1 and row <= #visible then
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      render()
    end
  end
  map("<CR>", choose)
  map("<Esc>", cancel)
  map("<C-c>", cancel)
  map("<C-n>", function()
    move(1)
  end)
  map("<C-p>", function()
    move(-1)
  end)
  map("j", function()
    move(1)
  end)
  map("k", function()
    move(-1)
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

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

---@return "vim"|"internal"
local function backend()
  local ok, config = pcall(require, "acp.config")
  if not ok then
    return "vim"
  end
  local ui = config and config.defaults and config.defaults.ui
  -- Prefer the live controller configuration when available.
  local ok_state, controller = pcall(require, "acp.controller")
  if ok_state then
    local cfg = controller.state().config
    if cfg and cfg.ui and cfg.ui.picker then
      return cfg.ui.picker
    end
  end
  if ui and ui.picker then
    return ui.picker
  end
  return "vim"
end

---Show a selector.
---
---With the default `ui.picker = "vim"` this delegates to `vim.ui.select`, so
---the user's own picker plugin is used. Choosing nothing (or dismissing the
---prompt) invokes `on_cancel`, which is what permission handling relies on.
---@param opts {title: string, items: AcpPickerItem[], on_choice: fun(value: any), on_cancel?: fun(), width?: integer, height?: integer, format?: fun(item: AcpPickerItem): string, filter?: boolean}
function M.select(opts)
  local items = opts.items or {}
  if #items == 0 then
    vim.notify("acp.nvim: nothing to select", vim.log.levels.WARN)
    return
  end

  if backend() == "internal" then
    internal_select(opts)
    return
  end

  local format_item = make_formatter(items, opts)
  local settled = false

  local function settle()
    if settled then
      return false
    end
    settled = true
    return true
  end

  vim.ui.select(items, {
    prompt = opts.title,
    format_item = format_item,
    kind = "acp_select",
  }, function(item)
    if not settle() then
      return
    end
    if item == nil then
      -- Dismissing the prompt is a cancellation, not a silent no-op: callers
      -- such as permission handling depend on being told.
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end
    if opts.on_choice then
      opts.on_choice(item.value, item)
    end
  end)
end

---Yes/no confirmation, also routed through `vim.ui.select`.
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
    filter = false,
  })
end

-- Exposed for tests.
M._internal_select = internal_select
M._format_item = format_item

return M
