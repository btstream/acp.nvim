-- Draft persistence so unsent messages survive restarts.
--
-- Drafts are small (text plus attachment metadata) and keyed by project +
-- session id. Nothing is written when the composer is empty.
local M = {}
local memory = require("acp.session.memory")

local MAX_TEXT = 200 * 1024
local MAX_DRAFTS = 50
-- Attachments in a draft keep their metadata plus a bounded slice of text.
local MAX_ATTACHMENT_TEXT = 2000
local MAX_DRAFT_ATTACHMENTS = 20
local cached_path, cached_store, cached_stamp, dirty, timer
local epoch = 0
local inflight = false

local function stamp(path)
  local st = vim.uv.fs_stat(path)
  return st and string.format("%d:%d:%d", st.size, st.mtime.sec, st.mtime.nsec) or "missing"
end

local function state_dir()
  local dir = vim.fn.stdpath("state") .. "/acp"
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  return dir
end

---@return string
function M.path()
  return state_dir() .. "/drafts.json"
end

---@return table
local function read_store(path)
  local fh = io.open(path, "rb")
  if not fh then
    return {}
  end
  local data = fh:read("*a")
  fh:close()
  if not data or data == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

local function cancel_timer()
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  timer = nil
end

local function load()
  local path = M.path()
  if cached_path ~= path then
    if dirty and M.flush then
      M.flush()
    end
    epoch = epoch + 1
    cached_path, cached_store, cached_stamp = path, read_store(path), stamp(path)
  elseif not dirty and stamp(path) ~= cached_stamp then
    cached_store, cached_stamp = read_store(path), stamp(path)
  end
  return cached_store
end

local function save(store, path)
  local ok, encoded = pcall(vim.json.encode, store)
  if not ok then
    return false
  end
  -- Write to a sibling file and rename it into place. A crash mid-write used to
  -- leave a truncated file, losing every stored draft at once.
  path = path or M.path()
  local tmp = path .. ".tmp"
  local fh = io.open(tmp, "wb")
  if not fh then
    return false
  end
  local wrote = fh:write(encoded)
  fh:close()
  if not wrote then
    pcall(vim.uv.fs_unlink, tmp)
    return false
  end
  local renamed = vim.uv.fs_rename(tmp, path)
  if not renamed then
    -- Fall back to an in-place write on filesystems where rename fails.
    local dst = io.open(path, "wb")
    if not dst then
      pcall(vim.uv.fs_unlink, tmp)
      return false
    end
    dst:write(encoded)
    dst:close()
    pcall(vim.uv.fs_unlink, tmp)
  end
  return true
end

-- Used on editor shutdown and by tests needing durable data immediately.
function M.flush()
  cancel_timer()
  epoch = epoch + 1 -- invalidate any asynchronous write already in flight
  if inflight and not vim.wait(2000, function()
    return not inflight
  end, 5) then
    return false
  end
  if not dirty then
    return true
  end
  local ok = save(cached_store, cached_path)
  if ok then
    dirty, cached_stamp = false, stamp(cached_path)
  end
  return ok
end

local function flush_async()
  timer = nil
  if not dirty then
    return
  end
  if inflight then
    timer = vim.defer_fn(flush_async, 150)
    return
  end
  local ok, data = pcall(vim.json.encode, cached_store)
  if not ok then
    return
  end
  local path, version = cached_path, epoch
  inflight = true
  local tmp = path .. ".tmp." .. vim.uv.os_getpid() .. "." .. version
  local function failed(err)
    inflight = false
    vim.uv.fs_unlink(tmp, function() end)
    if err then
      vim.schedule(function()
        require("acp.log").warn("unable to persist drafts: %s", tostring(err))
      end)
    end
  end
  vim.uv.fs_open(tmp, "w", 384, function(err, fd)
    if err then
      failed(err)
      return
    end
    local offset = 0
    local write
    write = function()
      vim.uv.fs_write(fd, data:sub(offset + 1), offset, function(write_err, wrote)
        if write_err or not wrote or wrote == 0 then
          vim.uv.fs_close(fd, function()
            failed(write_err or "short draft write")
          end)
          return
        end
        offset = offset + wrote
        if offset < #data then
          write()
          return
        end
        vim.uv.fs_close(fd, function(close_err)
          if close_err or version ~= epoch then
            failed(close_err)
            return
          end
          vim.uv.fs_rename(tmp, path, function(rename_err)
            if rename_err then
              failed(rename_err)
              return
            end
            inflight = false
            vim.schedule(function()
              if version == epoch then
                dirty, cached_stamp = false, stamp(path)
              end
            end)
          end)
        end)
      end)
    end
    write()
  end)
end

local function schedule_save()
  epoch, dirty = epoch + 1, true
  cancel_timer()
  timer = vim.defer_fn(flush_async, 150)
  return true
end

local function key(cwd, session_id)
  return (cwd or "") .. "\0" .. (session_id or "")
end

---Persist one draft. Passing an empty text removes the entry.
---Keep a draft's attachments small enough that `drafts.json` cannot grow to
---megabytes, which would make every read/write slow and eventually push a
---following prompt past `transport.max_line_bytes`.
---@param attachments table|nil
---@return table
local function trim_attachments(attachments)
  local out = {}
  for _, att in ipairs(attachments or {}) do
    if type(att) == "table" then
      local copy = {}
      for k, v in pairs(att) do
        if k ~= "text" and k ~= "block" then
          copy[k] = v
        end
      end
      -- Text content is what makes attachments large; a draft only needs the
      -- reference so the composer can show a chip again.
      local text = att.text
      if type(text) == "string" then
        copy.text = memory.clip(text, MAX_ATTACHMENT_TEXT)
        copy.text_truncated = #text > MAX_ATTACHMENT_TEXT
      end
      out[#out + 1] = copy
    end
    if #out >= MAX_DRAFT_ATTACHMENTS then
      break
    end
  end
  return out
end

---@param cwd string
---@param session_id string|nil
---@param text string|nil
---@param attachments table|nil
function M.put(cwd, session_id, text, attachments)
  local store = load()
  local k = key(cwd, session_id)
  if (not text or text:match("^%s*$")) and #(attachments or {}) == 0 then
    store[k] = nil
  else
    store[k] = {
      cwd = cwd,
      session_id = session_id,
      text = memory.clip(text or "", MAX_TEXT),
      attachments = trim_attachments(attachments),
      saved_at = os.time(),
    }
  end

  -- Bound the number of stored drafts. Entries are sanitised first so a hand
  -- edited file cannot crash the pruning sort.
  local keys = {}
  for candidate, entry in pairs(store) do
    if type(entry) == "table" then
      keys[#keys + 1] = candidate
    else
      store[candidate] = nil
    end
  end
  if #keys > MAX_DRAFTS then
    table.sort(keys, function(a, b)
      return (store[a].saved_at or 0) > (store[b].saved_at or 0)
    end)
    for i = MAX_DRAFTS + 1, #keys do
      store[keys[i]] = nil
    end
  end

  return schedule_save()
end

---@param cwd string
---@param session_id string|nil
---@return {text: string, attachments: table[]}|nil
function M.get(cwd, session_id)
  local entry = load()[key(cwd, session_id)]
  if type(entry) ~= "table" then
    return nil
  end
  -- Sanitise: a hand-edited file may hold a non-list where a list is expected,
  -- which would crash `ipairs` in the composer.
  local attachments = {}
  if type(entry.attachments) == "table" then
    for _, att in ipairs(entry.attachments) do
      if type(att) == "table" then
        attachments[#attachments + 1] = vim.deepcopy(att)
      end
    end
  end
  return { text = type(entry.text) == "string" and entry.text or "", attachments = attachments }
end

function M.clear()
  cancel_timer()
  epoch = epoch + 1
  if inflight and not vim.wait(2000, function()
    return not inflight
  end, 5) then
    return false
  end
  cached_path, cached_store, cached_stamp, dirty = nil, nil, nil, false
  pcall(vim.uv.fs_unlink, M.path())
end

return M
