-- Collect editor context into ACP prompt content blocks.
local log = require("acp.log")

local M = {}

---@param path string
---@return string
local function to_uri(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  -- Encode characters that are invalid in a file URI path segment.
  local encoded = abs:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return "file://" .. encoded
end

M.to_uri = to_uri

---@param bufnr integer
---@return string|nil
local function buffer_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function read_file(path, max_bytes)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text
  if max_bytes then
    -- Read at most one byte more than the limit so an oversized file can be
    -- detected without loading all of it.
    text = fh:read(max_bytes + 1)
  else
    text = fh:read("*a")
  end
  fh:close()
  if text and max_bytes and #text > max_bytes then
    return nil, "too_large"
  end
  return text
end

---Build an attachment for a file path.
---@param path string
---@param config table
---@return table|nil attachment
---@return string|nil err
function M.file(path, config)
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "not a readable file: " .. path
  end
  local limit = config.context.max_file_bytes or 512 * 1024
  local stat = vim.uv.fs_stat(abs)
  if stat and stat.size > limit then
    return nil, "file is too large to attach"
  end

  local bufnr = vim.fn.bufnr(abs)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
    -- Prefer the unsaved buffer contents so the agent sees what the user sees.
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    -- An unsaved buffer can be arbitrarily large; the disk size check above
    -- does not apply to it. Oversized attachments would exceed
    -- `transport.max_line_bytes` and kill the agent connection.
    if #text > limit then
      return nil, "buffer is too large to attach"
    end
    return {
      kind = "file",
      label = vim.fn.fnamemodify(abs, ":t"),
      path = abs,
      uri = to_uri(abs),
      text = text,
      unsaved = true,
      block = {
        type = "resource",
        resource = { uri = to_uri(abs), mimeType = "text/plain", text = text },
      },
    }
  end

  -- Bound the read so a file that grew after `fs_stat` (TOCTOU) still cannot
  -- blow past the limit.
  local text, err = read_file(abs, limit)
  if not text then
    if err == "too_large" then
      return nil, "file is too large to attach"
    end
    return nil, "unable to read file: " .. path
  end
  return {
    kind = "file",
    label = vim.fn.fnamemodify(abs, ":t"),
    path = abs,
    uri = to_uri(abs),
    block = { type = "resource_link", uri = to_uri(abs), name = vim.fn.fnamemodify(abs, ":t") },
  }
end

---Build an attachment for the current visual selection.
---@param config table
---@return table|nil attachment
---@return string|nil err
function M.selection(config)
  local bufnr = vim.api.nvim_get_current_buf()
  local path = buffer_path(bufnr)
  if not path then
    return nil, "current buffer has no file"
  end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then
    return nil, "no visual selection"
  end
  local start_line, start_col = start_pos[2], start_pos[3]
  local end_line, end_col = end_pos[2], end_pos[3]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil, "empty selection"
  end
  if #lines > (config.context.max_selection_lines or 2000) then
    return nil, "selection is too large to attach"
  end
  lines[1] = lines[1]:sub(start_col)
  lines[#lines] = lines[#lines]:sub(1, end_col)
  local text = table.concat(lines, "\n")
  -- Line count alone does not bound the payload: a few very long lines can
  -- still exceed the transport limit and kill the connection.
  local limit = config.context.max_file_bytes or 512 * 1024
  if #text > limit then
    return nil, "selection is too large to attach"
  end
  local label = string.format("%s %d-%d", vim.fn.fnamemodify(path, ":t"), start_line, end_line)
  return {
    kind = "selection",
    label = label,
    path = path,
    uri = to_uri(path),
    text = text,
    range = { start_line = start_line, end_line = end_line },
    block = {
      type = "resource",
      resource = { uri = to_uri(path), mimeType = "text/plain", text = text },
      annotations = { audience = { "assistant" } },
    },
  }
end

---Build an attachment for the current diagnostic line.
---@param config table
---@return table|nil attachment
function M.diagnostics(config)
  local bufnr = vim.api.nvim_get_current_buf()
  local path = buffer_path(bufnr)
  if not path then
    return nil, "current buffer has no file"
  end
  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics == 0 then
    return nil, "no diagnostics in this buffer"
  end
  local lines = {}
  local limit = config.context.max_file_bytes or 512 * 1024
  local bytes = 0
  local total = 0
  for _, diag in ipairs(diagnostics) do
    local line = string.format(
      "%s:%d:%d %s %s",
      path,
      diag.lnum + 1,
      diag.col + 1,
      ({ "ERROR", "WARN", "INFO", "HINT" })[diag.severity] or "INFO",
      diag.message
    )
    bytes = bytes + #line + 1
    if bytes > limit then
      -- Truncate instead of dropping everything: the first diagnostics are
      -- usually the ones that matter, and an unbounded list would exceed the
      -- transport limit.
      lines[#lines + 1] = string.format("... (%d more diagnostics omitted)", #diagnostics - total)
      break
    end
    lines[#lines + 1] = line
    total = total + 1
  end
  local text = table.concat(lines, "\n")
  return {
    kind = "diagnostics",
    label = string.format("diagnostics (%d)", total),
    path = path,
    text = text,
    block = {
      type = "text",
      text = "Diagnostics:\n" .. text,
      annotations = { audience = { "assistant" } },
    },
  }
end

---Extract `@path` mentions from a message and turn readable files into attachments.
---The mention text is left in the message so the agent keeps the reference.
---@param text string
---@param config table
---@param cwd string|nil
---@return table[] attachments
function M.mentions(text, config, cwd)
  local attachments = {}
  local seen = {}
  for token in text:gmatch("@([%w%._%-/]+)") do
    local path = token
    if path:match("[/%.]") and not seen[path] then
      local absolute = path
      if path:sub(1, 1) ~= "/" and cwd then
        absolute = cwd .. "/" .. path
      end
      if vim.fn.filereadable(absolute) == 1 then
        local attachment = M.file(absolute, config)
        if attachment then
          seen[path] = true
          attachments[#attachments + 1] = attachment
        end
      end
    end
  end
  return attachments
end

---Convert attachments plus a text message into prompt content blocks.
---@param text string
---@param attachments table[]
---@return table[]
function M.to_prompt(text, attachments)
  local blocks = {}
  if text and text ~= "" then
    blocks[#blocks + 1] = { type = "text", text = text }
  end
  for _, att in ipairs(attachments or {}) do
    if att.block then
      blocks[#blocks + 1] = att.block
    end
  end
  return blocks
end

return M
