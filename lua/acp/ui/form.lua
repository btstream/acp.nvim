-- Elicitation form: a small floating window over a validated field list.
--
-- One choice-only field is simplified to a plain picker; everything else gets
-- the form so constraints and multiple fields remain visible together.
local picker = require("acp.ui.picker")
local schema_parser = require("acp.app.elicitation_schema")

local M = {}
local current

---Close the open form, if any.
function M.dismiss()
  local handle = current
  current = nil
  if handle then
    handle.close()
  end
end

local function label_for(field, values)
  local value = values[field.key]
  if field.kind == "multi" then
    return type(value) == "table" and table.concat(value, ", ") or ""
  end
  if field.kind == "boolean" then
    if value == nil then
      return "unset"
    end
    return value and "yes" or "no"
  end
  if value == nil then
    return ""
  end
  return tostring(value)
end

local function pick_choice(field, values, on_done)
  local items = {}
  for _, option in ipairs(field.options) do
    items[#items + 1] = { label = option.label, description = option.description, value = option.value }
  end
  if field.custom_key then
    items[#items + 1] = { label = field.custom_title or "Other", value = "\0custom" }
  end
  picker.select({
    title = field.title,
    items = items,
    on_choice = function(value)
      if value == "\0custom" then
        vim.ui.input({ prompt = (field.custom_title or "Other") .. ": " }, function(text)
          values[field.custom_key] = text or ""
          if text and text ~= "" then
            values[field.key] = nil
          end
          on_done()
        end)
        return
      end
      values[field.key] = value
      values[field.custom_key] = nil
      on_done()
    end,
    on_cancel = function()
      on_done()
    end,
  })
end

local function pick_multi(field, values, on_done)
  local selected = {}
  for _, value in ipairs(values[field.key] or {}) do
    selected[value] = true
  end
  local items = {}
  for _, option in ipairs(field.options) do
    items[#items + 1] = {
      label = (selected[option.value] and "[x] " or "[ ] ") .. option.label,
      description = option.description,
      value = option.value,
    }
  end
  picker.select({
    title = field.title .. " (toggle, <Esc> done)",
    items = items,
    filter = false,
    on_choice = function(value, _)
      selected[value] = not selected[value] or nil
      local list = {}
      for _, option in ipairs(field.options) do
        if selected[option.value] then
          list[#list + 1] = option.value
        end
      end
      values[field.key] = list
      -- Re-open to keep toggling. Picker callbacks are already settled, so the
      -- next selection replaces this window after a tick.
      vim.schedule(function()
        pick_multi(field, values, on_done)
      end)
    end,
    on_cancel = on_done,
  })
end

local function edit_field(field, values, on_done)
  if field.kind == "choice" then
    pick_choice(field, values, on_done)
  elseif field.kind == "multi" then
    pick_multi(field, values, on_done)
  elseif field.kind == "boolean" then
    values[field.key] = not values[field.key]
    on_done()
  else
    vim.ui.input({ prompt = field.title .. ": ", default = label_for(field, values) }, function(text)
      if text ~= nil then
        values[field.key] = text
      end
      on_done()
    end)
  end
end

---Open a form for an elicitation request.
---@param request table
---@param opts {on_submit: fun(content: table), on_cancel: fun(), on_decline: fun(),
---  notify: fun(message: string, level: integer|nil)}
---@return boolean opened
function M.open(request, opts)
  local parsed = schema_parser.parse(request.requestedSchema)
  if not parsed then
    opts.notify("unsupported elicitation schema", vim.log.levels.WARN)
    opts.on_decline()
    return false
  end
  local fields = parsed.fields
  local values = {}
  for _, field in ipairs(fields) do
    if field.default ~= nil then
      values[field.key] = field.default
    end
  end

  local only = fields[1]
  if #fields == 1 and only.kind == "choice" and not only.custom_key then
    picker.select({
      title = request.message or only.title,
      items = (function()
        local items = {}
        for _, option in ipairs(only.options) do
          items[#items + 1] = { label = option.label, description = option.description, value = option.value }
        end
        return items
      end)(),
      on_choice = function(value)
        opts.on_submit({ [only.key] = value })
      end,
      on_cancel = opts.on_cancel,
    })
    return true
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local ns = vim.api.nvim_create_namespace("acp_elicitation")
  local width = math.min(90, math.max(50, vim.o.columns - 20))
  local message = request.message or (request.requestedSchema and request.requestedSchema.title) or "Agent question"
  local message_lines = vim.split(message, "\n", { plain = true })
  local height = math.min(20, #message_lines + #fields + 3)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Agent question ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if current and current.close == close then
      current = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local rows = {}
  local function render()
    rows = {}
    for _, line in ipairs(message_lines) do
      rows[#rows + 1] = { text = line, kind = "message" }
    end
    rows[#rows + 1] = { text = "", kind = "message" }
    for _, field in ipairs(fields) do
      local value = label_for(field, values)
      local marker = field.required and "* " or "  "
      rows[#rows + 1] = {
        text = string.format("%s%s: %s", marker, field.title, value ~= "" and value or "<CR> to set"),
        kind = "field",
        field = field,
      }
      if field.custom_key and values[field.custom_key] and values[field.custom_key] ~= "" then
        rows[#rows + 1] = { text = "    " .. (field.custom_title or "Other") .. ": " .. values[field.custom_key] }
      end
    end
    rows[#rows + 1] = { text = "", kind = "message" }
    rows[#rows + 1] = { text = "<CR> edit  <C-s> submit  q cancel  d decline", kind = "hint" }
    local lines = {}
    for _, row in ipairs(rows) do
      lines[#lines + 1] = (row.text or ""):gsub("\r", "")
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for index, row in ipairs(rows) do
      if row.kind == "field" and row.field.required then
        vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, { end_col = 1, hl_group = "DiagnosticError" })
      end
    end
    pcall(vim.api.nvim_win_set_height, win, math.min(20, #rows))
  end

  local function row_field()
    local index = vim.api.nvim_win_get_cursor(win)[1]
    local row = rows[index]
    return row and row.field or nil
  end

  local function submit()
    local ok, content = schema_parser.validate(fields, values)
    if not ok then
      opts.notify(content, vim.log.levels.WARN)
      return
    end
    close()
    opts.on_submit(content)
  end

  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map("<CR>", function()
    local field = row_field()
    if field then
      edit_field(field, values, render)
    end
  end)
  map("<C-s>", submit)
  map("q", function()
    close()
    opts.on_cancel()
  end)
  map("d", function()
    close()
    opts.on_decline()
  end)

  render()
  current = { close = close }
  return true
end

M._label_for = label_for
return M
