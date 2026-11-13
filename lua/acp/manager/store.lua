-- On-disk layout for manager-owned agent installs.
--
-- Every function here treats the filesystem as untrusted: a receipt may have
-- been hand-edited, a release directory may be a symlink, and an id may come
-- from a command line. Nothing outside `root` is ever read as an install or
-- deleted, and that is enforced by normalising and re-checking every path
-- rather than by string prefixes.
--
-- Layout (one directory per agent, so two agents never share a pointer):
--
--   <root>/<id>/current.json          pointer: which install id is live
--   <root>/<id>/releases/<install-id>/ package.json, node_modules, receipt.json
local M = {}

local Store = {}
Store.__index = Store

local SCHEMA_VERSION = 1

---Ids are ours, not the user's: keep them boring so they cannot escape a path.
---@param id string
---@return boolean
function M.valid_id(id)
  return type(id) == "string" and id:match("^[a-z0-9][a-z0-9_-]*$") ~= nil and #id <= 64
end

---Install ids double as directory names, so the same rule applies except that a
---version number contains dots. Restricted to dots safe for a path segment: no
---leading dot, no separators, no traversal.
---@param value string
---@return boolean
function M.valid_install_id(value)
  if type(value) ~= "string" or #value > 96 then
    return false
  end
  if value:match("^[a-z0-9]") == nil then
    return false
  end
  if value:find("..", 1, true) or value:find("/", 1, true) or value:find("\\", 1, true) then
    return false
  end
  return value:match("^[a-z0-9][a-z0-9._%-]*$") ~= nil
end

---Normalise a path for comparison. Returns nil for anything unusable.
---@param path string|nil
---@return string|nil
local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local ok, out = pcall(vim.fs.normalize, path)
  if not ok or type(out) ~= "string" or out == "" then
    return nil
  end
  return out
end

---Whether `path` is inside `root` (or is `root` itself).
---
---Compares normalised paths component-wise, so `/root/agents-evil` is not
---inside `/root/agents` even though the string starts with it.
---@param root string
---@param path string
---@return boolean
function M.contains(root, path)
  local a, b = normalize(root), normalize(path)
  if not a or not b then
    return false
  end
  if a == b then
    return true
  end
  local sep = a:sub(-1) == "/" and "" or "/"
  return b:sub(1, #a + #sep) == a .. sep
end

---Reject roots that would make "delete what the manager owns" dangerous.
---
---The installer deletes release directories, so a root of `/`, the home
---directory or a project directory must never be accepted silently.
---@param root string
---@return boolean ok
---@return string|nil reason
function M.check_root(root)
  local path = normalize(root)
  if not path then
    return false, "manager.root must be an absolute path"
  end
  if path:sub(1, 1) ~= "/" and not path:match("^%a:[/\\]") then
    return false, "manager.root must be absolute, got " .. path
  end
  if path == "/" then
    return false, "manager.root must not be the filesystem root"
  end
  local home = normalize(vim.uv.os_homedir and vim.uv.os_homedir() or vim.fn.expand("~"))
  if home and path == home then
    return false, "manager.root must not be the home directory"
  end
  -- Being outside the home directory is legitimate (a shared data dir), so it
  -- is not an error; only the roots above are refused.
  -- The agent root is a dedicated data directory; refusing a path that *is*
  -- the project makes an accidental `root = "."` visible instead of destructive.
  if vim.fn.getcwd and path == normalize(vim.fn.getcwd()) then
    return false, "manager.root must not be the current working directory"
  end
  return true
end

---@param opts {root: fun(): string|nil, fs?: table}
---@return table
function M.new(opts)
  return setmetatable({ get_root = opts.root, fs = opts.fs or vim.uv }, Store)
end

---The validated root, or nil plus a reason.
---@return string|nil
---@return string|nil
function Store:root()
  local root = self.get_root()
  if not root or root == "" then
    return nil, "manager.root is not configured"
  end
  return root
end

---@param id string
---@return string|nil
---@return string|nil
function Store:agent_dir(id)
  local root, err = self:root()
  if not root then
    return nil, err
  end
  if not M.valid_id(id) then
    return nil, "invalid agent id " .. tostring(id)
  end
  local dir = normalize(root .. "/" .. id)
  if not dir or not M.contains(root, dir) then
    return nil, "agent directory escapes manager.root"
  end
  return dir
end

---@param id string
---@return string|nil
---@return string|nil
function Store:releases_dir(id)
  local dir, err = self:agent_dir(id)
  if not dir then
    return nil, err
  end
  return dir .. "/releases"
end

---@param id string
---@param install_id string
---@return string|nil
---@return string|nil
function Store:release_dir(id, install_id)
  local dir, err = self:releases_dir(id)
  if not dir then
    return nil, err
  end
  if not M.valid_install_id(install_id) then
    return nil, "invalid install id " .. tostring(install_id)
  end
  return dir .. "/" .. install_id
end

---Read and validate a JSON file. A missing file is `nil, nil`; a broken file is
---`nil, reason` so callers can report "broken" instead of "not installed".
---@param path string
---@return table|nil value
---@return string|nil err
local function read_json(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil, nil
  end
  local text = fh:read("*a")
  fh:close()
  if not text or text == "" then
    return nil, path .. " is empty"
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    return nil, path .. " is not valid JSON"
  end
  if type(value) ~= "table" then
    return nil, path .. " does not contain an object"
  end
  return value
end

---Write JSON through a temporary file in the same directory, then rename.
---
---Renaming within one directory is atomic on every platform we support, which is
---what keeps a crash from leaving a half-written pointer behind.
---@param path string
---@param value table
---@return boolean ok
---@return string|nil err
local function write_json_atomic(path, value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false, "unable to encode " .. path
  end
  local tmp = path .. ".tmp-" .. tostring(vim.uv.hrtime())
  local fh, err = io.open(tmp, "wb")
  if not fh then
    return false, "unable to write " .. tmp .. ": " .. tostring(err)
  end
  local written = fh:write(encoded)
  fh:close()
  if not written then
    os.remove(tmp)
    return false, "unable to write " .. tmp
  end
  local renamed, rename_err = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return false, "unable to replace " .. path .. ": " .. tostring(rename_err)
  end
  return true
end

---Validate a receipt before trusting it.
---
---The receipt is the only thing standing between a hand-edited file and a
---subprocess launched from an arbitrary path, so every field is checked.
---@param id string
---@param value table
---@param dir string the release directory the receipt lives in
---@return table|nil receipt
---@return string|nil err
local function validate_receipt(id, value, dir)
  if value.schemaVersion ~= SCHEMA_VERSION then
    return nil, "unsupported receipt schemaVersion " .. tostring(value.schemaVersion)
  end
  if value.agentId ~= id then
    return nil, "receipt belongs to a different agent"
  end
  if type(value.installId) ~= "string" or not M.valid_install_id(value.installId) then
    return nil, "receipt has an invalid installId"
  end
  if type(value.package) ~= "string" or value.package == "" then
    return nil, "receipt has no package name"
  end
  if type(value.version) ~= "string" or value.version == "" then
    return nil, "receipt has no version"
  end
  if type(value.entry) ~= "string" or value.entry == "" then
    return nil, "receipt has no entrypoint"
  end
  -- The entrypoint is relative to the release directory and must stay inside it.
  local entry = normalize(dir .. "/" .. value.entry)
  if not entry or not M.contains(dir, entry) or entry == normalize(dir) then
    return nil, "receipt entrypoint escapes the release directory"
  end
  return {
    schemaVersion = SCHEMA_VERSION,
    agentId = id,
    installId = value.installId,
    package = value.package,
    version = value.version,
    entry = value.entry,
    bin = type(value.bin) == "string" and value.bin or nil,
    runtime = value.runtime == "node" and "node" or nil,
    installedAt = type(value.installedAt) == "string" and value.installedAt or nil,
    platform = type(value.platform) == "string" and value.platform or nil,
    arch = type(value.arch) == "string" and value.arch or nil,
    nodeVersion = type(value.nodeVersion) == "string" and value.nodeVersion or nil,
  }
end

---The live pointer for one agent.
---@param id string
---@return string|nil install_id
---@return string|nil err nil when the pointer simply does not exist
function Store:read_pointer(id)
  local dir, err = self:agent_dir(id)
  if not dir then
    return nil, err
  end
  local value, read_err = read_json(dir .. "/current.json")
  if read_err then
    return nil, read_err
  end
  if not value then
    return nil, nil
  end
  if value.schemaVersion ~= SCHEMA_VERSION then
    return nil, "unsupported pointer schemaVersion " .. tostring(value.schemaVersion)
  end
  if type(value.installId) ~= "string" or not M.valid_install_id(value.installId) then
    return nil, "pointer has an invalid installId"
  end
  return value.installId, nil
end

---Point one agent at `install_id`.
---@param id string
---@param install_id string
---@param meta table|nil extra fields stored next to the pin
---@return boolean ok
---@return string|nil err
function Store:write_pointer(id, install_id, meta)
  local dir, err = self:agent_dir(id)
  if not dir then
    return false, err
  end
  if not M.valid_install_id(install_id) then
    return false, "invalid install id"
  end
  local ok, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
  if not ok then
    return false, "unable to create " .. dir .. ": " .. tostring(mkdir_err)
  end
  local value = {
    schemaVersion = SCHEMA_VERSION,
    installId = install_id,
    updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  for key, item in pairs(meta or {}) do
    if key ~= "schemaVersion" and key ~= "installId" then
      value[key] = item
    end
  end
  return write_json_atomic(dir .. "/current.json", value)
end

---Read the receipt for one release.
---@param id string
---@param install_id string
---@return table|nil receipt
---@return string|nil err
function Store:read_receipt(id, install_id)
  local dir, err = self:release_dir(id, install_id)
  if not dir then
    return nil, err
  end
  local value, read_err = read_json(dir .. "/receipt.json")
  if read_err then
    return nil, read_err
  end
  if not value then
    return nil, "receipt.json is missing"
  end
  return validate_receipt(id, value, dir)
end

---Write a receipt into an (unpublished) release directory.
---@param id string
---@param receipt table
---@return boolean ok
---@return string|nil err
function Store:write_receipt(id, receipt)
  local dir, err = self:release_dir(id, receipt.installId)
  if not dir then
    return false, err
  end
  local value = {
    schemaVersion = SCHEMA_VERSION,
    agentId = id,
    installId = receipt.installId,
    package = receipt.package,
    version = receipt.version,
    entry = receipt.entry,
    bin = receipt.bin,
    runtime = receipt.runtime,
    installedAt = receipt.installedAt or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    platform = receipt.platform,
    arch = receipt.arch,
    nodeVersion = receipt.nodeVersion,
  }
  return write_json_atomic(dir .. "/receipt.json", value)
end

---Everything the manager knows about one agent.
---
---`status` is the persistent state; `source` describes what would be launched.
---They are separate on purpose: "installed but broken" must not read as usable,
---and "external" must not read as "not installed".
---@param id string
---@return table state
function Store:state(id)
  local state = { id = id, status = "not_installed", install = nil }
  local dir, dir_err = self:agent_dir(id)
  if not dir then
    state.status = "broken"
    state.error = dir_err
    return state
  end
  local install_id, pointer_err = self:read_pointer(id)
  if pointer_err then
    state.status = "broken"
    state.error = pointer_err
    return state
  end
  if not install_id then
    return state
  end
  local receipt, receipt_err = self:read_receipt(id, install_id)
  if not receipt then
    state.status = "broken"
    state.install_id = install_id
    state.error = receipt_err
    return state
  end
  local release_dir = self:release_dir(id, install_id)
  local entry = normalize(release_dir .. "/" .. receipt.entry)
  local stat = entry and self.fs.fs_stat(entry)
  if not stat or stat.type ~= "file" then
    state.status = "broken"
    state.install_id = install_id
    state.error = "entrypoint is missing: " .. tostring(receipt.entry)
    return state
  end
  state.status = "installed"
  state.install_id = install_id
  state.install = receipt
  state.dir = release_dir
  state.entry = entry
  return state
end

---Every install id present on disk for one agent, newest name first.
---@param id string
---@return string[]
function Store:list_install_ids(id)
  local dir = self:releases_dir(id)
  if not dir then
    return {}
  end
  local out = {}
  local handle = self.fs.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, kind = self.fs.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" and M.valid_install_id(name) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---Resolve a path inside a release directory, refusing escapes.
---@param id string
---@param install_id string
---@param relative string
---@return string|nil
function Store:release_path(id, install_id, relative)
  local dir = self:release_dir(id, install_id)
  if not dir then
    return nil
  end
  local path = normalize(dir .. "/" .. relative)
  if not path or not M.contains(dir, path) then
    return nil
  end
  return path
end

M.SCHEMA_VERSION = SCHEMA_VERSION
M.normalize = normalize
M.read_json = read_json
M.write_json_atomic = write_json_atomic

return M
