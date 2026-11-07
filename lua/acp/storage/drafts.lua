-- Draft persistence so unsent messages survive restarts.
--
-- Drafts are small (text plus attachment metadata) and keyed by project +
-- session id. Nothing is written when the composer is empty.
local M = {}

local MAX_TEXT = 200 * 1024
local MAX_DRAFTS = 50

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
  local fh = io.open(M.path(), "wb")
  if not fh then
    return false
  end
  fh:write(encoded)
  fh:close()
  return true
end

local function key(cwd, session_id)
  return (cwd or "") .. "\0" .. (session_id or "")
end

---Persist one draft. Passing an empty text removes the entry.
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
      attachments = attachments or {},
      saved_at = os.time(),
    }
  end

  -- Bound the number of stored drafts.
  local keys = vim.tbl_keys(store)
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
  if not entry then
    return nil
  end
  return { text = entry.text or "", attachments = entry.attachments or {} }
end

function M.clear()
  pcall(vim.uv.fs_unlink, M.path())
end

return M
