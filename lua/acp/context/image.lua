-- Image attachments and their on-disk store.
--
-- Only metadata travels with the composer: a path, a MIME type, a byte count
-- and a digest. Base64 is produced at send time, so drafts, the local message
-- queue and session blocks never hold an inflated copy of the pixels.
local M = {}

---Formats the agent can be expected to decode, and the extension used on disk.
M.EXTENSION = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/webp"] = "webp",
  ["image/gif"] = "gif",
}

local PNG = "\137PNG\r\n\26\n"

---Identify an image from its leading bytes. The container is sniffed rather
---than trusted: a file named `shot.png` may be anything, and the agent would
---reject the resulting block only after the user pressed send.
---@param bytes string
---@return string|nil mime
function M.sniff(bytes)
  if type(bytes) ~= "string" then
    return nil
  end
  if #bytes >= #PNG and bytes:sub(1, #PNG) == PNG then
    return "image/png"
  end
  if #bytes >= 3 and bytes:sub(1, 3) == "\255\216\255" then
    return "image/jpeg"
  end
  if #bytes >= 6 and bytes:sub(1, 3) == "GIF" then
    return "image/gif"
  end
  if #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
    return "image/webp"
  end
  return nil
end

---@param mime string
---@return string|nil
function M.extension(mime)
  return M.EXTENSION[mime]
end

---@return string
function M.dir()
  return vim.fn.stdpath("state") .. "/acp/images"
end

---Whether `path` is a supported image file within `limit` bytes.
---
---Only the header is read, so this is safe to call for every mentioned path
---before deciding whether to parse it as an image.
---@param path string
---@param limit integer|nil
---@return boolean
function M.is_file(path, limit)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return false
  end
  if limit and stat.size > limit then
    return false
  end
  local fh = io.open(path, "rb")
  if not fh then
    return false
  end
  local head = fh:read(12) or ""
  fh:close()
  return M.sniff(head) ~= nil
end

---Read at most `limit` bytes, so a file that grows after `fs_stat` cannot
---exceed the budget it was validated against.
---@param path string
---@param limit integer|nil
---@return string|nil bytes
---@return string|nil err
function M.read(path, limit)
  local fh = io.open(path, "rb")
  if not fh then
    return nil, "unable to read image"
  end
  local bytes = fh:read(limit and (limit + 1) or "*a")
  fh:close()
  if not bytes then
    return nil, "unable to read image"
  end
  if limit and #bytes > limit then
    return nil, "image is too large"
  end
  return bytes
end

local function ensure_dir()
  local dir = M.dir()
  if vim.fn.isdirectory(dir) == 1 then
    return vim.uv.fs_chmod(dir, 448) and dir or nil
  end
  pcall(vim.fn.mkdir, dir, "p", 448) -- 0700
  return vim.fn.isdirectory(dir) == 1 and dir or nil
end

---Store bytes under their digest and return the path. The name is derived from
---the content, so the same screenshot pasted twice reuses one file and no part
---of the name comes from user input.
---@param bytes string
---@param mime string
---@return string|nil path
---@return string|nil err
function M.store(bytes, mime)
  local ext = M.EXTENSION[mime]
  if not ext then
    return nil, "unsupported image format"
  end
  local dir = ensure_dir()
  if not dir then
    return nil, "unable to create the image cache directory"
  end
  local path = string.format("%s/%s.%s", dir, vim.fn.sha256(bytes), ext)
  if vim.fn.filereadable(path) == 1 then
    local stat = vim.uv.fs_lstat(path)
    if stat and stat.type == "file" and M.read(path, #bytes) == bytes and vim.uv.fs_chmod(path, 384) then
      return path
    end
    return nil, "image cache entry is invalid"
  end
  local tmp = path .. "." .. tostring(vim.uv.hrtime()) .. ".tmp"
  local fd = vim.uv.fs_open(tmp, "wx", 384) -- private from creation, not after writing
  if not fd then
    return nil, "unable to write the image cache"
  end
  local wrote = vim.uv.fs_write(fd, bytes, 0)
  local closed = vim.uv.fs_close(fd)
  if wrote ~= #bytes or not closed then
    pcall(os.remove, tmp)
    return nil, "unable to write the image cache"
  end
  local ok_rename, renamed = pcall(vim.uv.fs_rename, tmp, path)
  if not ok_rename or not renamed then
    pcall(os.remove, tmp)
    return nil, "unable to commit the image cache"
  end
  return path
end

---Drop expired entries, then the oldest ones until the directory fits.
---
---Cleanup runs opportunistically rather than on a timer: the composer is the
---only writer, and attaching an image is already a moment where a little extra
---I/O is not noticeable.
---@param ttl_hours number
---@param max_bytes integer
---@return integer removed
function M.prune(ttl_hours, max_bytes, protected)
  local dir = M.dir()
  if vim.fn.isdirectory(dir) ~= 1 then
    return 0
  end
  local names = vim.fn.readdir(dir)
  if type(names) ~= "table" then
    return 0
  end
  local now = os.time()
  local ttl = tonumber(ttl_hours) or 0
  local entries, total, removed = {}, 0, 0
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    local stat = vim.uv.fs_stat(path)
    if protected and protected[path] then
      -- Live attachments take precedence over cache budgets. They become
      -- eligible again after the draft/queue/history reference is released.
    elseif not stat then
      pcall(os.remove, path)
      removed = removed + 1
    elseif name:sub(-4) == ".tmp" or (ttl > 0 and now - stat.mtime.sec > ttl * 3600) then
      pcall(os.remove, path)
      removed = removed + 1
    else
      entries[#entries + 1] = { path = path, at = stat.mtime.sec, size = stat.size }
      total = total + stat.size
    end
  end
  if not max_bytes or max_bytes <= 0 or total <= max_bytes then
    return removed
  end
  table.sort(entries, function(a, b)
    return a.at < b.at
  end)
  for _, entry in ipairs(entries) do
    if total <= max_bytes then
      break
    end
    pcall(os.remove, entry.path)
    total = total - entry.size
    removed = removed + 1
  end
  return removed
end

return M
