-- Cross-process locks and release leases for the agent manager.
--
-- Two Neovim instances can install, update or launch the same agent at the same
-- time. A Lua mutex would not help, so the lock is the filesystem itself:
-- `fs_mkdir` succeeds for exactly one caller.
--
-- A lock alone is not enough for launches. Installing while another instance is
-- *running* a release would delete the files under its feet, so a running
-- process also takes a shared lease on the exact install id it uses. Update and
-- uninstall refuse to proceed while a lease is live.
--
-- Staleness is checked with pid liveness plus a heartbeat file, and on the same
-- host only. A lock from another host cannot be probed, so it is reported as
-- unknown rather than silently stolen.
local log = require("acp.log")

local M = {}

local Lock = {}
Lock.__index = Lock

---Milliseconds between heartbeat writes while a lease is held.
local HEARTBEAT_MS = 15000
---A lock or lease older than this with no live pid is treated as abandoned.
local STALE_MS = 120000

---@return string
local function hostname()
  local ok, name = pcall(vim.uv.os_gethostname)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end
  return "unknown"
end

---@return string
local function pid()
  return tostring(vim.uv.os_getpid())
end

---@param path string
---@return table|nil
local function read_json(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  if not text or text == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil
  end
  return value
end

---@param path string
---@param value table
---@return boolean ok
local function write_json(path, value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false
  end
  local tmp = path .. ".tmp-" .. tostring(vim.uv.hrtime())
  local fh = io.open(tmp, "wb")
  if not fh then
    return false
  end
  local written = fh:write(encoded)
  fh:close()
  if not written then
    os.remove(tmp)
    return false
  end
  if not os.rename(tmp, path) then
    os.remove(tmp)
    return false
  end
  return true
end

---Whether `value` still looks alive.
---
---Returns `live`, `reason`. A lock whose pid is gone but whose file is recent is
---*not* stolen: a slow npm run can legitimately outlive a short grace period, and
---stealing it would start two installers in one directory.
---@param value table|nil
---@param path string
---@return boolean live
---@return string|nil reason
---Wall-clock milliseconds.
---
---Heartbeats are compared across processes and across reboots, so they cannot
---use `vim.uv.now()`: that is a monotonic clock that restarts at boot, which
---made a lock written before a reboot look fresh forever afterwards.
---@return integer
function M.now()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function alive(value, path, now)
  if not value then
    -- Unreadable or half-written: treat as live-but-unknown so callers do not
    -- delete what they cannot reason about.
    return true, "lock file is unreadable"
  end
  if value.host ~= hostname() then
    return true, "held by another host (" .. tostring(value.host) .. ")"
  end
  local owner = tonumber(value.pid)
  if not owner then
    return true, "lock file has no pid"
  end
  -- `uv.kill(pid, 0)` returns true when the process exists, or nil plus an errno
  -- string such as "ESRCH: no such process". It does not raise, so pcall alone
  -- says nothing about liveness.
  local ok, sent, err = pcall(vim.uv.kill, owner, 0)
  if ok and sent then
    return true, "pid " .. owner .. " is running"
  end
  local message = tostring(ok and err or sent)
  if not message:match("ESRCH") then
    -- EPERM and friends mean the process exists but is not ours.
    return true, "pid " .. owner .. " exists but cannot be signalled"
  end
  local heartbeat = tonumber(value.heartbeat) or 0
  -- A heartbeat in the future (clock moved back) cannot be aged: keep the
  -- conservative answer and do not steal it.
  if heartbeat > 0 and ((now or M.now)() - heartbeat) > STALE_MS then
    return false, "abandoned"
  end
  -- The process is gone but the record is fresh: it may be the tail of a crash.
  -- Wait for the caller to decide rather than declaring the lock free.
  return true, "pid " .. owner .. " is gone; lock " .. path .. " is recent"
end

---@param opts {root: fun(): string|nil, clock?: fun(): integer}
---@return table
function M.new(opts)
  return setmetatable({
    get_root = opts.root,
    clock = opts.clock or M.now,
    leases = {},
    timers = {},
  }, Lock)
end

---Directory for the exclusive per-agent lock.
---
---`fs_mkdir` is the atomic primitive, so this directory *is* the lock. Leases
---must not live here: a held lock would then look like a stray file.
---@param id string
---@return string|nil
function Lock:locks_dir(id)
  local root = self.get_root()
  if not root or root == "" then
    return nil
  end
  return root .. "/.locks/" .. id
end

---Directory for shared leases on one agent.
---@param id string
---@return string|nil
function Lock:leases_dir(id)
  local root = self.get_root()
  if not root or root == "" then
    return nil
  end
  return root .. "/.leases/" .. id
end

---Try to take the exclusive per-agent lock.
---
---Returns the lock handle on success. On failure the reason says who holds it,
---which is what the UI needs to show instead of "busy".
---@param id string
---@param meta table|nil
---@return table|nil handle
---@return string|nil err
function Lock:acquire(id, meta)
  local dir = self:locks_dir(id)
  if not dir then
    return nil, "manager.root is not configured"
  end
  pcall(vim.fn.mkdir, dir:gsub("/[^/]+$", ""), "p")
  local ok = vim.uv.fs_mkdir(dir, 448)
  if not ok then
    local info = read_json(dir .. "/owner.json")
    local live, reason = alive(info, dir, self.clock)
    if live then
      return nil, "another instance is using this agent: " .. tostring(reason)
    end
    -- Abandoned: reclaim it. `rmdir` would fail because the directory holds
    -- owner.json, so remove the record first and retry the mkdir.
    os.remove(dir .. "/owner.json")
    -- `delete(..., "d")` refuses non-empty directories; `"rf"` is what actually
    -- clears a leftover record from a crashed run.
    vim.fn.delete(dir, "rf")
    if not vim.uv.fs_mkdir(dir, 448) then
      return nil, "unable to reclaim an abandoned lock at " .. dir
    end
  end
  local owner = vim.tbl_extend("force", {
    host = hostname(),
    pid = pid(),
    acquiredAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    heartbeat = self.clock(),
  }, meta or {})
  if not write_json(dir .. "/owner.json", owner) then
    vim.fn.delete(dir, "rf")
    return nil, "unable to record the lock owner"
  end
  local handle = { dir = dir, id = id, owner = owner, released = false }
  return handle
end

---Release a lock taken by `acquire`.
---@param handle table|nil
function Lock:release(handle)
  if not handle or handle.released then
    return
  end
  handle.released = true
  local info = read_json(handle.dir .. "/owner.json")
  -- Only the owner removes its own lock: a reclaimed lock belongs to someone else.
  if info and info.pid == pid() and info.host == hostname() then
    vim.fn.delete(handle.dir, "rf")
  end
end

---Take a shared lease on one install id.
---
---The file is named after the pid so two processes never overwrite each other.
---@param id string
---@param install_id string
---@return table|nil lease
---@return string|nil err
function Lock:lease(id, install_id)
  local dir = self:leases_dir(id)
  if not dir then
    return nil, "manager.root is not configured"
  end
  local path = dir .. "/lease-" .. pid() .. ".json"
  pcall(vim.fn.mkdir, dir, "p")
  local value = {
    host = hostname(),
    pid = pid(),
    installId = install_id,
    heartbeat = self.clock(),
    startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  if not write_json(path, value) then
    return nil, "unable to record a lease at " .. path
  end
  local lease = { path = path, id = id, install_id = install_id, released = false }
  self.leases[path] = lease
  -- Keep the heartbeat fresh so a long turn is not mistaken for a crash.
  local timer = vim.uv.new_timer()
  if timer then
    timer:start(
      HEARTBEAT_MS,
      HEARTBEAT_MS,
      vim.schedule_wrap(function()
        if lease.released then
          return
        end
        value.heartbeat = self.clock()
        write_json(path, value)
      end)
    )
    self.timers[path] = timer
  end
  return lease
end

---Release a lease and stop its heartbeat.
---@param lease table|nil
function Lock:unlease(lease)
  if not lease or lease.released then
    return
  end
  lease.released = true
  local timer = self.timers[lease.path]
  if timer then
    self.timers[lease.path] = nil
    pcall(function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end)
  end
  self.leases[lease.path] = nil
  local info = read_json(lease.path)
  if info and info.pid == pid() and info.host == hostname() then
    os.remove(lease.path)
  end
end

---Live leases for one agent.
---
---Stale leases (dead pid, old heartbeat) are removed on the way through: they are
---evidence of a crash, not of a running install.
---@param id string
---@return table[] leases records that are still live
---@return string[] unknown reasons for leases that could not be inspected
function Lock:live_leases(id)
  local dir = self:leases_dir(id)
  local live, unknown = {}, {}
  if not dir then
    return live, unknown
  end
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return live, unknown
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:match("^lease%-.*%.json$") then
      local path = dir .. "/" .. name
      local info = read_json(path)
      local is_live, reason = alive(info, path, self.clock)
      if is_live then
        if reason and reason:match("cannot be signalled") then
          unknown[#unknown + 1] = name .. ": " .. reason
        elseif info and info.installId then
          live[#live + 1] = info
        else
          unknown[#unknown + 1] = name .. ": " .. tostring(reason)
        end
      else
        log.debug("removing stale lease %s (%s)", path, tostring(reason))
        os.remove(path)
      end
    end
  end
  return live, unknown
end

---Whether any live lease references a given install id.
---@param id string
---@param install_id string
---@return boolean busy
---@return string|nil reason
function Lock:install_in_use(id, install_id)
  local live, unknown = self:live_leases(id)
  for _, lease in ipairs(live) do
    if lease.installId == install_id then
      return true, "in use by pid " .. tostring(lease.pid)
    end
  end
  if #unknown > 0 then
    return true, "cannot verify use: " .. unknown[1]
  end
  return false, nil
end

---Release every lease this instance holds and stop their timers.
function Lock:close()
  for path, lease in pairs(self.leases) do
    self.leases[path] = nil
    self:unlease(lease)
  end
  for path, timer in pairs(self.timers) do
    self.timers[path] = nil
    pcall(function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end)
  end
end

M.alive = alive
M.hostname = hostname
-- Exposed so tests (and a future repair command) can write the same records.
M.write_json_atomic = write_json

return M
