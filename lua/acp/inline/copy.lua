-- Private, bounded copies owned by this process. A filename prefix is never
-- authorization to read/write/delete a file.
local M = {}
local owned, sequence = {}, 0
local function state_dir()
  return vim.fn.stdpath("state") .. "/acp/inline"
end
local function canonical(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    return nil
  end
  return vim.uv.fs_realpath(path) or vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function prune(dir)
  for _, name in ipairs(vim.fn.readdir(dir)) do
    local pid = name:match("^%.?acp%-inline%-(%d+)%-")
    local path = dir .. "/" .. name
    local st = pid and vim.uv.fs_lstat(path)
    if st and st.type == "file" and os.time() - st.mtime.sec > 24 * 3600 then
      local ok, alive = pcall(vim.uv.kill, tonumber(pid), 0)
      if not ok or alive ~= 0 then
        pcall(vim.uv.fs_unlink, path)
      end
    end
  end
end

function M.create(selection, config)
  local dir, sibling
  if config.inline.copy_dir == "sibling" and selection.path ~= "" then
    dir = vim.fs.dirname(selection.path)
    sibling = dir and vim.fn.isdirectory(dir) == 1 and vim.fn.filewritable(dir) == 2
  end
  if not sibling then
    dir = state_dir()
    local ok = pcall(vim.fn.mkdir, dir, "p", 448)
    if not ok or not vim.uv.fs_chmod(dir, 448) then
      return nil, "unable to create private inline directory"
    end
  end
  prune(dir)
  sequence = sequence + 1
  local name = selection.path ~= "" and vim.fs.basename(selection.path) or "untitled.txt"
  local path = string.format(
    "%s/%sacp-inline-%d-%s-%d-%s",
    dir,
    sibling and "." or "",
    vim.fn.getpid(),
    tostring(vim.uv.hrtime()),
    sequence,
    name
  )
  local eol = selection.fileformat == "dos" and "\r\n" or "\n"
  local data = table.concat(selection.original, eol) .. (selection.eol == false and "" or eol)
  if #data > config.inline.max_copy_bytes then
    return nil, "buffer exceeds inline.max_copy_bytes"
  end
  local fd = vim.uv.fs_open(path, "wx", 384)
  if not fd then
    return nil, "unable to create the inline copy"
  end
  local n = vim.uv.fs_write(fd, data, 0)
  local closed = vim.uv.fs_close(fd)
  if n ~= #data or not closed then
    pcall(vim.uv.fs_unlink, path)
    return nil, "unable to write the inline copy"
  end
  owned[path] = true
  return path
end

function M.is_copy_path(path, expected)
  if type(expected) ~= "string" or not owned[expected] then
    return false
  end
  local st = vim.uv.fs_lstat(expected)
  if not st or st.type ~= "file" or (st.nlink and st.nlink > 1) then
    return false
  end
  local input = canonical(path)
  return input ~= nil and input == canonical(expected)
end

function M.read(path, limit)
  if not owned[path] or not M.is_copy_path(path, path) then
    return nil, "inline copy is missing or not a regular private file"
  end
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil, "unable to read inline copy"
  end
  local st = vim.uv.fs_fstat(fd)
  limit = limit or 8 * 1024 * 1024
  if not st or st.type ~= "file" or (st.nlink and st.nlink > 1) or st.size > limit then
    vim.uv.fs_close(fd)
    return nil, "inline result exceeds inline.max_copy_bytes"
  end
  local data = vim.uv.fs_read(fd, limit + 1, 0)
  local after = vim.uv.fs_fstat(fd)
  vim.uv.fs_close(fd)
  if not data or #data > limit then
    return nil, "inline result exceeds inline.max_copy_bytes"
  end
  if
    not after
    or #data ~= st.size
    or after.size ~= st.size
    or not vim.deep_equal(after.mtime, st.mtime)
    or not M.is_copy_path(path, path)
  then
    return nil, "inline copy changed while reading"
  end
  if data:find("\0", 1, true) then
    return nil, "inline result contains binary data"
  end
  data = data:gsub("\r\n", "\n")
  local eol = data:sub(-1) == "\n"
  if eol then
    data = data:sub(1, -2)
  end
  return vim.split(data, "\n", { plain = true }), nil, eol
end

function M.remove(path)
  if path and owned[path] then
    pcall(vim.uv.fs_unlink, path)
    owned[path] = nil
  end
end
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for path in pairs(owned) do
      M.remove(path)
    end
  end,
})
return M
