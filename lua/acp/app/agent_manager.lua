-- User-facing actions for managed agent installs.
--
-- This layer owns the decisions a user has to make: confirm an install, pick a
-- version, refresh the list, cancel a task. The mechanics live in
-- `manager/install`; the drawing lives in `ui/agent_manager`. Keeping the three
-- apart means the transaction can be tested with no UI, and the UI can be tested
-- with no npm.
--
-- Install results are reported through `state`, which the UI subscribes to. The
-- service never opens the panel, never starts an agent and never logs in.
local Store = require("acp.manager.store")
local Lock = require("acp.manager.lock")
local Resolve = require("acp.manager.resolve")
local Registry = require("acp.manager.registry")
local Installer = require("acp.manager.install")
local npm_mod = require("acp.manager.npm")

local M = {}

local Manager = {}
Manager.__index = Manager

---@param opts {config: fun(): table, notify: fun(message: string, level: integer|nil),
---  presenter: table, store?: table, locks?: table, npm?: table,
---  confirm?: fun(details: table, cb: fun(accepted: boolean)),
---  on_changed: fun()|nil}
---@return table
function M.new(opts)
  local self = setmetatable({
    config = opts.config,
    notify = opts.notify or function() end,
    presenter = opts.presenter,
    on_changed = opts.on_changed,
    injected = { store = opts.store, locks = opts.locks, npm = opts.npm },
    confirm = opts.confirm,
    task = nil,
    log_tail = {},
  }, Manager)
  return self
end

---The store for the current config, rebuilt after a reconfiguration.
---@return table
function Manager:store()
  if self.injected.store then
    return self.injected.store
  end
  local cfg = self.config()
  if not self._store or self._store_key ~= Resolve.manager_root(cfg) then
    self._store = Resolve.new_store(cfg)
    self._store_key = Resolve.manager_root(cfg)
  end
  return self._store
end

---The lock/lease manager for the current config.
---@return table
function Manager:locks()
  if self.injected.locks then
    return self.injected.locks
  end
  local cfg = self.config()
  local root = Resolve.manager_root(cfg)
  if not self._locks or self._locks_key ~= root then
    if self._locks then
      self._locks:close()
    end
    self._locks = Lock.new({
      root = function()
        return root
      end,
    })
    self._locks_key = root
  end
  return self._locks
end

---The npm runner: real subprocesses unless a test injected one.
---@return table
function Manager:npm()
  if self.injected.npm then
    return self.injected.npm
  end
  if not self._npm then
    local cfg = self.config()
    local manager_cfg = cfg.manager or {}
    self._npm = npm_mod.new({
      run = function(argv, opts, cb)
        return self:_spawn(argv, opts, cb)
      end,
      node = function()
        return manager_cfg.node or "node"
      end,
      npm = function()
        return manager_cfg.npm or "npm"
      end,
    })
  end
  return self._npm
end

---Run one process with a bounded tail of output.
---
---`vim.system` is used rather than `jobstart` because the manager never needs a
---terminal: it needs an exit code and a capped log. The tail is capped while
---collecting, not after, so a chatty install cannot blow up memory.
---@param argv string[]
---@param opts {cwd: string, timeout: integer, max_log_bytes: integer, env?: table}
---@param cb fun(ok: boolean, result: table)
function Manager:_spawn(argv, opts, cb)
  local limit = opts.max_log_bytes or 1024 * 1024
  local collected = { stdout = {}, stderr = {}, bytes = 0 }
  local function add(stream, data)
    if type(data) ~= "string" or data == "" then
      return
    end
    if collected.bytes >= limit then
      return
    end
    local room = limit - collected.bytes
    if #data > room then
      data = data:sub(1, room)
    end
    collected.bytes = collected.bytes + #data
    local list = collected[stream]
    list[#list + 1] = data
  end
  local ok, proc = pcall(vim.system, argv, {
    cwd = opts.cwd,
    env = opts.env,
    text = true,
    timeout = opts.timeout,
    stdout = function(_, data)
      add("stdout", data)
    end,
    stderr = function(_, data)
      add("stderr", data)
    end,
  }, function(result)
    -- `vim.system` invokes this in a fast event context, where Vimscript
    -- functions (including `vim.fn.delete`) are forbidden. Everything after an
    -- install needs those, so the result is handed back on the main loop.
    vim.schedule(function()
      local stdout = table.concat(collected.stdout)
      local stderr = table.concat(collected.stderr)
      local tail = stderr ~= "" and stderr or stdout
      if #tail > 4000 then
        tail = tail:sub(-4000)
      end
      cb(true, {
        code = result.code or -1,
        stdout = stdout,
        stderr = stderr,
        tail = tail,
      })
    end)
  end)
  if not ok then
    cb(false, { message = tostring(proc) })
    return
  end
  if not proc then
    cb(false, { message = "unable to start " .. argv[1] })
  end
end

---Build the installer for the current config.
---@return table
function Manager:installer()
  local cfg = self.config()
  return Installer.new({
    store = self:store(),
    locks = self:locks(),
    npm = self:npm(),
    config = function()
      return cfg
    end,
    notify = self.notify,
    on_progress = function(event)
      self.progress = event
      self:changed()
    end,
  })
end

function Manager:changed()
  if self.on_changed then
    pcall(self.on_changed)
  end
end

---Whether an install/update/uninstall is in flight.
---@return boolean
function Manager:busy()
  return self.task ~= nil
end

---Every agent with its persistent state and launch source.
---
---External agents are listed too: a user needs to see that OpenCode is present
---on PATH and that pi is running through npx, not that it is "missing".
---@return table[]
function Manager:list()
  local cfg = self.config()
  local store = self:store()
  local rows = {}
  for _, id in ipairs(Registry.ids()) do
    local entry = Registry.get(id)
    local state = store:state(id)
    local description = Resolve.describe(cfg, id, cfg.launch_origin, store)
    rows[#rows + 1] = {
      id = id,
      title = entry.title,
      package = entry.package,
      homepage = entry.homepage,
      installable = entry.installable,
      requires = entry.requires,
      notes = entry.notes,
      status = state.status,
      install = state.install,
      error = state.error,
      root = state.dir,
      source = description.source,
      command = description.command,
      args = description.args,
      available = description.available,
      resolve_error = description.error,
      current = cfg.agent == id,
    }
  end
  return rows
end

---Ask the user to confirm a destructive or networked action.
---
---The default presenter is a picker with the details in the item description;
---tests inject a confirm function and skip it.
---@param details table
---@param cb fun(accepted: boolean)
function Manager:ask(details, cb)
  if self.confirm then
    local ok, accepted = pcall(self.confirm, details, cb)
    if ok then
      cb(accepted == true)
    else
      cb(false)
    end
    return
  end
  local lines = {}
  local function line(text)
    lines[#lines + 1] = text
  end
  if details.action == "uninstall" then
    line(string.format("Remove %s %s?", details.id, details.version and ("v" .. details.version) or ""))
    line("Location: " .. tostring(details.root))
    line("Your agent credentials and session history are not touched.")
  else
    line(string.format("%s %s %s", details.action == "update" and "Update" or "Install", details.id, details.version))
    line("Package: " .. tostring(details.package))
    line("Location: " .. tostring(details.root))
    if details.homepage then
      line("Source: " .. details.homepage)
    end
    for _, requirement in ipairs(details.requires or {}) do
      line("Needs: " .. requirement)
    end
    line("npm may run the package's install scripts with your permissions.")
  end
  for _, note in ipairs(details.notes or {}) do
    line(note)
  end
  local items = {
    { label = details.action == "uninstall" and "Remove it" or "Continue", value = true },
    { label = "Cancel", value = false },
  }
  self.presenter.select({
    title = table.concat(lines, "\n"),
    items = items,
    on_choice = function(value)
      cb(value == true)
    end,
    on_cancel = function()
      cb(false)
    end,
  })
end

---Install or update one agent.
---@param id string
---@param opts {version?: string, action?: string}|nil
function Manager:install(id, opts)
  opts = opts or {}
  if self:busy() then
    self.notify("an agent operation is already running", vim.log.levels.WARN)
    return false
  end
  local installer = self:installer()
  local action = opts.action or "install"
  self.task = { id = id, action = action }
  self.progress = { id = id, phase = "checking", action = action }
  self:changed()
  installer:install(id, {
    version = opts.version,
    action = action,
    confirm = function(details, answer)
      self:ask(details, answer)
    end,
  }, function(ok, value)
    self.task = nil
    if ok then
      self.progress = { id = id, phase = "done", action = action }
      self.notify(string.format("%s %s installed", id, value.version), vim.log.levels.INFO)
    elseif type(value) == "table" and value.cancelled then
      self.progress = { id = id, phase = "cancelled", action = action }
    else
      local message = type(value) == "table" and (value.message or vim.inspect(value)) or tostring(value)
      self.progress = { id = id, phase = "failed", action = action, message = message }
      self.notify(string.format("%s %s failed: %s", action, id, message), vim.log.levels.ERROR)
    end
    self:changed()
  end)
  return true
end

---Update one agent to the latest (or a given) version.
---@param id string
---@param opts {version?: string}|nil
function Manager:update(id, opts)
  opts = opts or {}
  opts.action = "update"
  return self:install(id, opts)
end

---Remove the manager-owned copy of one agent.
---@param id string
function Manager:uninstall(id)
  if self:busy() then
    self.notify("an agent operation is already running", vim.log.levels.WARN)
    return false
  end
  local installer = self:installer()
  self.task = { id = id, action = "uninstall" }
  self:changed()
  installer:uninstall(id, {
    confirm = function(details, answer)
      self:ask(details, answer)
    end,
  }, function(ok, value)
    self.task = nil
    if ok then
      self.progress = { id = id, phase = "removed", action = "uninstall" }
      self.notify(id .. " uninstalled", vim.log.levels.INFO)
    elseif type(value) == "table" and value.cancelled then
      self.progress = { id = id, phase = "cancelled", action = "uninstall" }
    else
      local message = type(value) == "table" and (value.message or vim.inspect(value)) or tostring(value)
      self.progress = { id = id, phase = "failed", action = "uninstall", message = message }
      self.notify("uninstall failed: " .. message, vim.log.levels.ERROR)
    end
    self:changed()
  end)
  return true
end

---Toolchain facts for the UI and health check. Never installs.
---@param probe fun(argv: string[], cb: fun(ok: boolean, out: string))|nil
---@return table
function Manager:toolchain(probe)
  return self:npm():toolchain(probe)
end

---Close leases owned by this instance (used on teardown).
function Manager:close()
  if self._locks then
    self._locks:close()
  end
end

M.Store = Store
M.Registry = Registry

return M
