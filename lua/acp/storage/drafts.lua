-- Draft persistence so unsent messages survive restarts.
--
-- Drafts are small (text plus attachment metadata) and keyed by project +
-- session id. Nothing is written when the composer is empty.
local M = {}

local MAX_TEXT = 200 * 1024
local MAX_DRAFTS = 50
-- Attachments in a draft keep their metadata plus a bounded slice of text.
local MAX_ATTACHMENT_TEXT = 2000
local MAX_DRAFT_ATTACHMENTS = 20

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
local function load()
  local fh = io.open(M.path(), "rb")
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

local function save(store)
  local ok, encoded = pcall(vim.json.encode, store)
  if not ok then
    return false
  end
  -- Write to a sibling file and rename it into place. A crash mid-write used to
  -- leave a truncated file, losing every stored draft at once.
  local path = M.path()
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
        copy.text = text:sub(1, MAX_ATTACHMENT_TEXT)
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
  if not text or text:match("^%s*$") then
    store[k] = nil
  else
    store[k] = {
      cwd = cwd,
      session_id = session_id,
      text = text:sub(1, MAX_TEXT),
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

  return save(store)
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
        attachments[#attachments + 1] = att
      end
    end
  end
  return { text = type(entry.text) == "string" and entry.text or "", attachments = attachments }
end

function M.clear()
  pcall(vim.uv.fs_unlink, M.path())
end

return M
