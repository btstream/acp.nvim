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
    -- Per-agent state, Mason-style: several agents may install at once, each
    -- with its own phase and live log. `progress` is the latest event overall.
    tasks = {},
    outcome = {},
    logs = {},
    latest = {},
    checking = {},
  }, Manager)
  return self
end

---Take over the per-agent state of a service replaced by a reconfiguration.
---
---The tables are shared, not copied: an install started by the old service
---still finishes through its own callbacks and must show up here.
---@param previous table
function Manager:adopt(previous)
  for _, key in ipairs({ "tasks", "outcome", "logs", "latest", "checking" }) do
    if type(previous[key]) == "table" then
      self[key] = previous[key]
    end
  end
  self.checked_at = previous.checked_at
  local old_changed = previous.on_changed
  previous.on_changed = self.on_changed or old_changed
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
  local on_output = opts.on_output
  local partial = { stdout = "", stderr = "" }
  local function emit(stream, data)
    if not on_output then
      return
    end
    local text = partial[stream] .. data
    local lines = vim.split(text, "\n", { plain = true })
    partial[stream] = table.remove(lines)
    if #lines > 0 then
      vim.schedule(function()
        for _, line in ipairs(lines) do
          line = line:gsub("\r", "")
          if line ~= "" then
            pcall(on_output, line)
          end
        end
      end)
    end
  end
  local function add(stream, data)
    if type(data) ~= "string" or data == "" then
      return
    end
    emit(stream, data)
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
      if on_output then
        for _, rest in pairs(partial) do
          if rest ~= "" then
            pcall(on_output, (rest:gsub("\r", "")))
          end
        end
      end
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
      self:record(event)
    end,
  })
end

function Manager:changed()
  if self.on_changed then
    pcall(self.on_changed)
  end
end

local MAX_LOG_LINES = 200

---Record one installer event: phase changes and live output lines.
---@param event table
function Manager:record(event)
  local id = event.id
  if not id then
    return
  end
  if event.phase == "output" then
    local log = self.logs[id] or {}
    self.logs[id] = log
    log[#log + 1] = event.line
    if #log > MAX_LOG_LINES then
      table.remove(log, 1)
    end
  else
    local task = self.tasks[id]
    if task then
      task.phase = event.phase
      task.version = event.version or task.version
    end
    self.progress = event
  end
  self:changed()
end

---Whether an operation is in flight, for one agent or for any.
---@param id string|nil
---@return boolean
function Manager:busy(id)
  if id then
    return self.tasks[id] ~= nil
  end
  return next(self.tasks) ~= nil
end

---The in-flight task for one agent, if any.
---@param id string
---@return table|nil
function Manager:task_of(id)
  return self.tasks[id]
end

---Start a task, refusing a second one for the same agent.
---@param id string
---@param action string
---@return boolean
function Manager:begin(id, action)
  if self.tasks[id] then
    self.notify(string.format("%s: %s is already running", id, self.tasks[id].action), vim.log.levels.WARN)
    return false
  end
  self.tasks[id] = { id = id, action = action, phase = "checking", started = vim.uv.now() }
  self.outcome[id] = nil
  self.logs[id] = {}
  self.progress = { id = id, phase = "checking", action = action }
  self:changed()
  return true
end

---Finish a task and remember how it ended, for the window.
---@param id string
---@param outcome table
function Manager:conclude(id, outcome)
  self.tasks[id] = nil
  outcome.id = id
  self.outcome[id] = outcome
  self.progress = outcome
  self:changed()
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
      task = self.tasks[id],
      outcome = self.outcome[id],
      log = self.logs[id],
      latest = self.latest[id],
      outdated = state.status == "installed"
        and self.latest[id] ~= nil
        and state.install ~= nil
        and self.latest[id] ~= state.install.version,
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
  -- Like Mason, pressing install is the decision; a confirmation dialog only
  -- appears when `manager.confirm = true`. Tests inject their own.
  local cfg = self.config()
  local wants_confirm = type(cfg.manager) == "table" and cfg.manager.confirm == true
  if not self.confirm and not wants_confirm then
    cb(true)
    return
  end
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
  -- The window uses this to keep itself open while a picker is on screen: the
  -- picker makes the agents float lose focus, which normally closes it.
  self.asking = (self.asking or 0) + 1
  local finished = false
  local function answer(value)
    if finished then
      return
    end
    finished = true
    self.asking = math.max(0, (self.asking or 1) - 1)
    cb(value)
    self:changed()
  end
  self.presenter.select({
    title = table.concat(lines, "\n"),
    items = items,
    on_choice = function(value)
      answer(value == true)
    end,
    on_cancel = function()
      answer(false)
    end,
  })
end

---Install or update one agent.
---@param id string
---@param opts {version?: string, action?: string}|nil
---@return boolean started
function Manager:install(id, opts)
  opts = opts or {}
  local action = opts.action or "install"
  if not self:begin(id, action) then
    return false
  end
  local installer = self:installer()
  installer:install(id, {
    version = opts.version,
    action = action,
    confirm = function(details, answer)
      self:ask(details, answer)
    end,
  }, function(ok, value)
    if ok then
      if value.unchanged then
        self:conclude(id, { phase = "unchanged", action = action, version = value.version })
        self.notify(string.format("%s is already up to date (%s)", id, value.version), vim.log.levels.INFO)
      else
        self:conclude(id, { phase = "done", action = action, version = value.version })
        self.notify(string.format("%s %s installed", id, value.version), vim.log.levels.INFO)
      end
    elseif type(value) == "table" and value.cancelled then
      self:conclude(id, { phase = "cancelled", action = action })
    else
      local message = type(value) == "table" and (value.message or vim.inspect(value)) or tostring(value)
      if type(value) == "table" and type(value.log) == "string" and value.log ~= "" then
        local log = self.logs[id] or {}
        self.logs[id] = log
        for _, line in ipairs(vim.split(value.log, "\n", { trimempty = true })) do
          log[#log + 1] = line
        end
      end
      self:conclude(id, { phase = "failed", action = action, message = message })
      self.notify(string.format("%s %s failed: %s", action, id, message), vim.log.levels.ERROR)
    end
  end)
  return true
end

---Update one agent to the latest (or a given) version.
---@param id string
---@param opts {version?: string}|nil
---@return boolean started
function Manager:update(id, opts)
  opts = opts or {}
  opts.action = "update"
  return self:install(id, opts)
end

---Update every managed install that has a newer version.
---
---Without a prior check every installed agent is updated; the installer skips
---those already at the latest version.
---@return integer started
function Manager:update_all()
  local started = 0
  for _, row in ipairs(self:list()) do
    if row.status == "installed" and (row.latest == nil or row.outdated) and not self.tasks[row.id] then
      if self:update(row.id) then
        started = started + 1
      end
    end
  end
  if started == 0 then
    self.notify("every managed agent is up to date", vim.log.levels.INFO)
  end
  return started
end

---Ask npm for the latest version of every managed install.
---
---Read-only: nothing is installed. Results land in `latest` and the window
---marks outdated rows.
---@param cb fun()|nil called once every query has answered
function Manager:check_outdated(cb)
  local store = self:store()
  local pending = 0
  local function done()
    pending = pending - 1
    if pending == 0 then
      self:changed()
      if cb then
        cb()
      end
    end
  end
  local cfg = self.config()
  local manager_cfg = cfg.manager or {}
  for _, id in ipairs(Registry.ids()) do
    local package = Registry.package_of(id)
    if package and store:state(id).status == "installed" and not self.checking[id] then
      pending = pending + 1
      self.checking[id] = true
      self:npm():resolve_version(package, "latest", {
        cwd = store:root(),
        timeout = math.min(manager_cfg.install_timeout or 300000, 60000),
        max_log_bytes = 64 * 1024,
      }, function(ok, version)
        self.checking[id] = nil
        if ok then
          self.latest[id] = version
        end
        done()
      end)
    end
  end
  self.checked_at = vim.uv.now()
  if pending == 0 and cb then
    cb()
  end
end

---Whether a latest-version check is running.
---@return boolean
function Manager:is_checking()
  return next(self.checking) ~= nil
end

---Install every agent in `ids` that is not installed yet.
---@param ids string[]
---@return integer started
function Manager:ensure_installed(ids)
  local started = 0
  local store = self:store()
  for _, id in ipairs(ids or {}) do
    if Registry.package_of(id) and store:state(id).status == "not_installed" and not self.tasks[id] then
      if self:install(id) then
        started = started + 1
      end
    end
  end
  return started
end

---Remove the manager-owned copy of one agent.
---@param id string
---@return boolean started
function Manager:uninstall(id)
  if not self:begin(id, "uninstall") then
    return false
  end
  local installer = self:installer()
  installer:uninstall(id, {
    confirm = function(details, answer)
      self:ask(details, answer)
    end,
  }, function(ok, value)
    if ok then
      self.latest[id] = nil
      self:conclude(id, { phase = "removed", action = "uninstall" })
      self.notify(id .. " uninstalled", vim.log.levels.INFO)
    elseif type(value) == "table" and value.cancelled then
      self:conclude(id, { phase = "cancelled", action = "uninstall" })
    else
      local message = type(value) == "table" and (value.message or vim.inspect(value)) or tostring(value)
      self:conclude(id, { phase = "failed", action = "uninstall", message = message })
      self.notify("uninstall failed: " .. message, vim.log.levels.ERROR)
    end
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
