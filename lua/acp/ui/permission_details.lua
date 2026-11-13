-- Detail lines for a pending permission request.
--
-- The picker backend is whatever the user configured (telescope, fzf, snacks,
-- or the built-in float), so details cannot live inside it. They are rendered
-- in a separate read-only float that is opened next to the picker and closed
-- when the interaction settles.
local diff = require("acp.ui.diff")

local M = {}

---@param text string
---@return string[]
local function split_lines(text)
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    out[#out + 1] = (line:gsub("\r", ""))
  end
  return out
end

---@param input any
---@return string[]
local function input_lines(input)
  if type(input) == "string" then
    return split_lines(input)
  end
  if type(input) ~= "table" then
    return {}
  end
  -- Prefer the field that actually ran, then the whole structured input.
  for _, key in ipairs({ "command", "cmd" }) do
    if type(input[key]) == "string" and vim.trim(input[key]) ~= "" then
      return split_lines(input[key])
    end
  end
  local ok, encoded = pcall(vim.json.encode, input)
  if ok and type(encoded) == "string" then
    return { encoded }
  end
  return {}
end

---Build the detail rows for one permission request.
---@param request table
---@param opts {cwd?: string, max_rows?: integer}
---@return string[] lines
function M.render(request, opts)
  opts = opts or {}
  local tool = request.toolCall or request.tool_call or {}
  local kind = tool.kind
  local out = {}
  local max_rows = opts.max_rows or 40

  local function push(lines)
    for _, line in ipairs(lines) do
      if #out >= max_rows then
        out[#out + 1] = "…"
        return
      end
      out[#out + 1] = line
    end
  end

  if kind == "execute" then
    push(input_lines(tool.rawInput))
    if opts.cwd and opts.cwd ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = "cwd: " .. opts.cwd
    end
    if #out == 0 then
      push({ tool.title or "" })
    end
    return out
  end

  if kind == "edit" or kind == "write" then
    local entries = diff.from_block(tool)
    if #entries > 0 then
      for _, row in ipairs(diff.lines(entries, { cwd = opts.cwd, max_rows = max_rows, syntax = false })) do
        push({ row.text })
      end
      return out
    end
  end

  local content = {}
  for _, item in ipairs(tool.content or {}) do
    if item.type == "content" and item.content and item.content.type == "text" then
      content[#content + 1] = item.content.text
    elseif item.type == "diff" and item.path then
      content[#content + 1] = "diff: " .. item.path
    elseif item.type == "resource_link" then
      content[#content + 1] = item.name or item.uri or ""
    end
  end
  if #content > 0 then
    push(split_lines(table.concat(content, "\n")))
    return out
  end

  push(input_lines(tool.rawInput))
  if #out == 0 and tool.title then
    out[1] = tool.title
  end
  return out
end

local current

---Close the detail float, if open.
function M.close()
  local win = current
  current = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---Open a read-only detail float. It never takes focus.
---@param request table
---@param opts {cwd?: string, title?: string, max_rows?: integer}
---@return boolean opened
function M.open(request, opts)
  opts = opts or {}
  local lines = M.render(request, opts)
  if #lines == 0 then
    return false
  end
  M.close()
  local max_width = math.max(30, math.min(100, vim.o.columns - 12))
  local width = max_width
  for _, line in ipairs(lines) do
    width = math.max(width, math.min(max_width, vim.api.nvim_strwidth(line) + 2))
  end
  width = math.min(width, max_width)
  local height = math.min(#lines, opts.max_rows or 40)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "Request details") .. " ",
    title_pos = "center",
    width = width,
    height = math.max(1, height),
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  if not ok then
    return false
  end
  vim.wo[win].winhighlight = "Normal:AcpPickerNormal,FloatBorder:AcpPickerBorder"
  current = win
  return true
end

return M
