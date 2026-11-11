-- The temporary file an inline agent is allowed to edit.
--
-- A sibling dotfile keeps relative imports, project-root detection and language
-- tooling working. When that is not possible the copy falls back to the state
-- directory. Copies are private, uniquely named and always removed.
local M = {}

local seq = 0

---@return string
local function state_dir()
  return vim.fn.stdpath("state") .. "/acp/inline"
end

---@param path string
---@return string
local function basename(path)
  local name = vim.fs.basename(path)
  return name ~= "" and name or "buffer.txt"
end

---@param path string|nil
---@param config table
---@return string dir, boolean sibling
local function target_dir(path, config)
  if config.inline.copy_dir == "sibling" and path and path ~= "" then
    local dir = vim.fs.dirname(path)
    local stat = vim.uv.fs_stat(dir)
    if stat and stat.type == "directory" and vim.fn.filewritable(dir) == 2 then
      return dir, true
    end
  end
  local dir = state_dir()
  pcall(vim.fn.mkdir, dir, "p", 448)
  return dir, false
end

---Write `lines` to a new private copy and return its path.
---
---`eol` is the source buffer's line ending, so the agent edits the text it would
---see on disk rather than a normalised variant.
---@param selection AcpInlineSelection
---@param config table
---@return string|nil path
---@return string|nil err
function M.create(selection, config)
  local dir, sibling = target_dir(selection.path, config)
  seq = seq + 1
  local prefix = sibling and "." or ""
  local name = string.format("%sacp-inline-%d-%d-%s", prefix, vim.uv.hrtime(), seq, basename(selection.path))
  local path = dir .. "/" .. name
  local data = table.concat(selection.original, "\n")
  local eol = vim.bo[selection.bufnr].fileformat == "dos" and "\r\n" or "\n"
  if eol == "\r\n" then
    data = table.concat(selection.original, "\r\n")
  end
  -- Keep the conventional final newline so "add a line at the end" works.
  data = data .. eol

  local fd = vim.uv.fs_open(path, "wx", 384)
  if not fd then
    return nil, "unable to create the inline copy"
  end
  local wrote = vim.uv.fs_write(fd, data, 0)
  local closed = vim.uv.fs_close(fd)
  if wrote ~= #data or not closed then
    pcall(vim.uv.fs_unlink, path)
    return nil, "unable to write the inline copy"
  end
  return path
end

---Read a copy back as lines, normalising the trailing newline.
---@param path string
---@return string[]|nil lines
function M.read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil
  end
  data = data:gsub("\r\n", "\n")
  local lines = vim.split(data, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

---@param path string|nil
---@param config table
---@return boolean
function M.is_copy_path(path, config)
  if not path then
    return false
  end
  local real = vim.uv.fs_realpath(path) or path
  local name = vim.fs.basename(real)
  if name:find("^%.?acp%-inline%-") then
    return true
  end
  local state = state_dir()
  return vim.startswith(real, state .. "/")
end

---@param path string|nil
function M.remove(path)
  if path and path ~= "" then
    pcall(vim.uv.fs_unlink, path)
  end
end

return M
