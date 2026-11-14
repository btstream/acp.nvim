-- Detect an agent writing the source file directly instead of the copy.
--
-- Inline editing hands the agent a private copy and expects the change to come
-- back as edits to that copy. An agent with an auto-approving mode, or one that
-- ignores the instruction, can write the real file mid-turn; applying the
-- reviewed hunks on top would then discard or duplicate work. The snapshot
-- taken before the turn is compared afterwards.
local M = {}

---A file's identity for change detection.
---@class AcpDiskSnapshot
---@field path string
---@field mtime integer|nil
---@field size integer|nil
---@field hash string|nil

---@param path string
---@return AcpDiskSnapshot|nil
function M.capture(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then
    -- A file that does not exist yet is still a state worth remembering: the
    -- agent creating it is also a direct write.
    return { path = path, mtime = nil, size = nil, hash = nil }
  end
  return {
    path = path,
    mtime = st.mtime.sec,
    size = st.size,
    hash = M.hash(path),
  }
end

---Content hash of a file, or nil when it cannot be read.
---@param path string
---@return string|nil
function M.hash(path)
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local st = vim.uv.fs_fstat(fd)
  if not st or st.type ~= "file" or st.size > 32 * 1024 * 1024 then
    vim.uv.fs_close(fd)
    return nil
  end
  local data = st.size > 0 and vim.uv.fs_read(fd, st.size, 0) or ""
  vim.uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil
  end
  return vim.fn.sha256(data)
end

---Whether the file changed since `snapshot`.
---
---mtime alone is not enough (a fast rewrite can land in the same second), and
---the hash is skipped for very large files, so the comparison uses everything
---that was captured.
---@param snapshot AcpDiskSnapshot|nil
---@return boolean changed
---@return string|nil reason
function M.changed(snapshot)
  if not snapshot then
    return false, nil
  end
  local now = M.capture(snapshot.path)
  if not now then
    return false, nil
  end
  if snapshot.hash ~= nil or now.hash ~= nil then
    if snapshot.hash ~= now.hash then
      return true, "the file content on disk changed during the inline edit"
    end
    return false, nil
  end
  if snapshot.size ~= now.size then
    return true, "the file size on disk changed during the inline edit"
  end
  if snapshot.mtime ~= now.mtime then
    return true, "the file on disk was rewritten during the inline edit"
  end
  return false, nil
end

---Read the file's current lines, for the "show the diff" action.
---
---Text is required: a binary file would be loaded as a single garbled line, and
---inserting that into the buffer would corrupt it.
---@param path string
---@return string[]|nil
function M.read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local st = vim.uv.fs_fstat(fd)
  local limit = 32 * 1024 * 1024
  if not st or st.type ~= "file" or st.size > limit then
    vim.uv.fs_close(fd)
    return nil
  end
  local data = st.size > 0 and vim.uv.fs_read(fd, st.size, 0) or ""
  vim.uv.fs_close(fd)
  if type(data) ~= "string" or data:find("\0", 1, true) then
    return nil
  end
  local ok, lines = pcall(vim.split, data:gsub("\r\n", "\n"), "\n", { plain = true })
  if not ok then
    return nil
  end
  -- `vim.split` keeps a trailing empty element for a final newline; strip it so
  -- the buffer does not gain a blank last line.
  if lines[#lines] == "" and data:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  return lines
end

return M
