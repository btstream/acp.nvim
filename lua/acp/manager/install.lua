-- Install, update and remove manager-owned agent packages.
--
-- The transaction rules are the whole point of this module:
--
-- 1. One agent at a time, enforced by the cross-process lock in `manager/lock`.
-- 2. The new release is installed into its own directory and is not referenced
--    by `current.json` until it has been verified.
-- 3. Verification reads the *installed* package.json, not what was requested.
-- 4. Only `current.json` is replaced on success, atomically.
-- 5. A failure or cancellation leaves the previous pointer untouched; the
--    half-built directory is removed so a retry starts clean.
--
-- The module never deletes anything outside a release directory it created and
-- never touches PATH installs, authentication files or agent config.
local Store = require("acp.manager.store")
local lock_mod = require("acp.manager.lock")

local M = {}

local Installer = {}
Installer.__index = Installer

---@param opts {store: table, locks: table, npm: table, config: fun(): table,
---  notify: fun(message: string, level: integer|nil),
---  on_progress: fun(event: table)|nil}
---@return table
function M.new(opts)
  return setmetatable({
    store = opts.store,
    locks = opts.locks,
    npm = opts.npm,
    config = opts.config,
    notify = opts.notify or function() end,
    on_progress = opts.on_progress,
    -- One in-flight operation per agent in this instance, on top of the file
    -- lock: two clicks on "Install" must not start two npm runs.
    running = {},
  }, Installer)
end

---@param event table
function Installer:progress(event)
  if self.on_progress then
    pcall(self.on_progress, event)
  end
end

---Build a unique, path-safe install id.
---
---`hrtime` is a float, and Lua's `tostring` turns large ones into scientific
---notation (`3.04e+14`), which is not a valid directory name. Format it as an
---integer before it reaches the path.
---@param version string
---@return string
local function install_id(version)
  local stamp = string.format("%d", vim.uv.hrtime() % 1e12)
  local suffix = tostring(math.random(1000, 9999))
  return string.format("v%s-%s-%s", version:gsub("[^%w%.%-]", "_"), stamp, suffix)
end

---Validate a request before touching the filesystem or the network.
---@param id string
---@param action string
---@return table|nil entry
---@return string|nil err
function Installer:prepare(id, action)
  local registry = require("acp.manager.registry")
  local entry = registry.get(id)
  if not entry then
    return nil, "unknown agent " .. tostring(id)
  end
  if not entry.installable then
    local _, reason = registry.installable(id)
    return nil, reason or "this agent is not installed by acp.nvim"
  end
  if self.running[id] then
    return nil, "an operation is already running for " .. id
  end
  local root = self.store:root()
  if not root then
    return nil, "manager.root is not configured"
  end
  local root_ok, root_err = Store.check_root(root)
  if not root_ok then
    return nil, root_err
  end
  if action == "update" then
    local state = self.store:state(id)
    if state.status == "not_installed" then
      return nil, id .. " is not installed; use install"
    end
  end
  return entry
end

---Install or update one agent.
---
---`opts.confirm` is the user's decision. It receives a description of what will
---be downloaded and where, plus a callback; the manager never installs without
---it being answered true. The callback form (rather than a return value) keeps
---the UI free to ask asynchronously.
---@param id string
---@param opts {version?: string, confirm: fun(details: table, answer: fun(accepted: boolean)),
---  action?: "install"|"update"}
---@param cb fun(ok: boolean, result_or_err: any)
function Installer:install(id, opts, cb)
  local action = opts.action or "install"
  local entry, prep_err = self:prepare(id, action)
  if not entry then
    cb(false, prep_err)
    return
  end
  local requested = opts.version or "latest"
  local version_ok, version_err = require("acp.manager.npm").valid_version(requested)
  if not version_ok then
    cb(false, version_err)
    return
  end
  self.running[id] = action
  local finished = false
  local function finish(ok, value)
    if finished then
      return
    end
    finished = true
    self.running[id] = nil
    cb(ok, value)
  end

  local cfg = self.config()
  local manager_cfg = cfg.manager or {}
  local timeout = manager_cfg.install_timeout or 300000
  local max_log = manager_cfg.max_log_bytes or 1024 * 1024

  local lock, lock_err = self.locks:acquire(id, { action = action })
  if not lock then
    finish(false, lock_err)
    return
  end
  local released = false
  local function unlock()
    if not released then
      released = true
      self.locks:release(lock)
    end
  end

  local run_opts = { cwd = self.store:root(), timeout = timeout, max_log_bytes = max_log }
  self:progress({ id = id, phase = "checking", action = action })

  self.npm:resolve_version(entry.package, requested, run_opts, function(resolved, version_or_err)
    if not resolved then
      unlock()
      finish(false, { message = tostring(version_or_err) })
      return
    end
    local version = version_or_err
    local details = {
      id = id,
      action = action,
      package = entry.package,
      version = version,
      root = self.store:root(),
      homepage = entry.homepage,
      requires = entry.requires,
      notes = entry.notes,
    }

    -- The decision may be asynchronous (a picker answers on a later turn), so
    -- the installer hands over a callback instead of expecting a return value.
    local answered = false
    local function answer(accepted)
      if answered then
        return
      end
      answered = true
      if not accepted then
        unlock()
        finish(false, { cancelled = true })
        return
      end
      self:build_release(id, entry, version, action, run_opts, unlock, finish)
    end
    local asked, ask_err = pcall(opts.confirm, details, answer)
    if not asked then
      unlock()
      finish(false, { message = "confirmation failed: " .. tostring(ask_err) })
    end
  end)
end

---Install into an unpublished release directory and commit on success.
---@param id string
---@param entry table registry entry
---@param version string exact version
---@param action string
---@param run_opts table
---@param unlock fun()
---@param finish fun(ok: boolean, value: any)
function Installer:build_release(id, entry, version, action, run_opts, unlock, finish)
  local new_id = install_id(version)
  local dir, dir_err = self.store:release_dir(id, new_id)
  if not dir then
    unlock()
    finish(false, { message = dir_err })
    return
  end
  local mkdir_ok = pcall(vim.fn.mkdir, dir, "p")
  if not mkdir_ok then
    unlock()
    finish(false, { message = "unable to create " .. dir })
    return
  end

  self:progress({ id = id, phase = "installing", action = action, version = version, dir = dir })
  self.npm:install({
    dir = dir,
    package = entry.package,
    version = version,
    timeout = run_opts.timeout,
    max_log_bytes = run_opts.max_log_bytes,
  }, function(installed, install_err)
    if not installed then
      -- A failed install leaves nothing to keep: remove only the directory this
      -- operation created.
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, install_err)
      return
    end

    self:progress({ id = id, phase = "verifying", action = action, version = version })
    local manifest, verify_err = self.npm.read_installed(dir, entry.package)
    if not manifest then
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, { message = verify_err })
      return
    end
    if manifest.version ~= version then
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, {
        message = string.format("npm installed %s but %s was requested", manifest.version, version),
      })
      return
    end

    -- The entrypoint must exist inside this release, exactly as declared.
    local entry_path = self.store:release_path(id, new_id, "node_modules/" .. entry.package .. "/" .. entry.entry)
    if not entry_path then
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, { message = "the package does not contain " .. entry.entry })
      return
    end
    local stat = vim.uv.fs_stat(entry_path)
    if not stat or stat.type ~= "file" then
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, { message = "the package entrypoint is missing: " .. entry.entry })
      return
    end

    local receipt_ok, receipt_err = self.store:write_receipt(id, {
      installId = new_id,
      package = entry.package,
      version = manifest.version,
      entry = "node_modules/" .. entry.package .. "/" .. entry.entry,
      bin = entry.bin,
      runtime = "node",
      platform = jit and jit.os or nil,
      arch = jit and jit.arch or nil,
    })
    if not receipt_ok then
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, { message = receipt_err })
      return
    end

    -- Commit: the only step that changes what will be launched.
    local pinned, pin_err = self.store:write_pointer(id, new_id, {
      package = entry.package,
      version = manifest.version,
    })
    if not pinned then
      vim.fn.delete(dir, "rf")
      unlock()
      finish(false, { message = pin_err })
      return
    end

    unlock()
    self:progress({ id = id, phase = "committed", action = action, version = manifest.version })
    finish(true, { id = id, version = manifest.version, install_id = new_id, dir = dir })
  end)
end

function Installer:uninstall(id, opts, cb)
  local entry, prep_err = self:prepare(id, "uninstall")
  if not entry then
    cb(false, prep_err)
    return
  end
  local state = self.store:state(id)
  if state.status == "not_installed" then
    cb(false, id .. " has no manager-owned install")
    return
  end
  self.running[id] = "uninstall"
  local function finish(ok, value)
    self.running[id] = nil
    cb(ok, value)
  end

  local lock, lock_err = self.locks:acquire(id, { action = "uninstall" })
  if not lock then
    finish(false, lock_err)
    return
  end
  local unlocked = false
  local function unlock()
    if not unlocked then
      unlocked = true
      self.locks:release(lock)
    end
  end

  local install_id_value = state.install_id
  local busy, busy_reason = self.locks:install_in_use(id, install_id_value)
  if busy then
    unlock()
    finish(false, { message = "cannot remove " .. id .. ": " .. tostring(busy_reason) })
    return
  end

  local details = {
    id = id,
    action = "uninstall",
    package = entry.package,
    version = state.install and state.install.version or nil,
    root = state.dir,
    keep_auth = true,
  }
  local answered = false
  local function proceed_removal(accepted)
    if answered then
      return
    end
    answered = true
    if not accepted then
      unlock()
      finish(false, { cancelled = true })
      return
    end
    self:remove_release(id, install_id_value, unlock, finish)
  end
  local asked, ask_err = pcall(opts.confirm, details, proceed_removal)
  if not asked then
    unlock()
    finish(false, { message = "confirmation failed: " .. tostring(ask_err) })
  end
end

---Delete an agent's pinned release after the user approved it.
---@param id string
---@param install_id_value string
---@param unlock fun()
---@param finish fun(ok: boolean, value: any)
function Installer:remove_release(id, install_id_value, unlock, finish)
  -- Drop the pointer first: even if deleting the files fails, nothing will load
  -- a half-removed install. The receipt path is re-validated by the store.
  local dir, dir_err = self.store:release_dir(id, install_id_value)
  if not dir then
    unlock()
    finish(false, { message = dir_err })
    return
  end
  local root = self.store:root()
  if not root or not Store.contains(root, dir) then
    unlock()
    finish(false, { message = "refusing to remove a path outside manager.root" })
    return
  end

  local agent_dir = self.store:agent_dir(id)
  if agent_dir then
    os.remove(agent_dir .. "/current.json")
  end
  local removed_ok = vim.fn.delete(dir, "rf") == 0
  unlock()
  if not removed_ok then
    finish(false, { message = "the pointer was removed but files remain in " .. dir })
    return
  end
  self:progress({ id = id, phase = "removed", action = "uninstall" })
  finish(true, { id = id })
end

---Release ids that are present but not pinned, oldest first.
---
---Used by the UI to report leftovers; cleaning them is a separate, explicit
---action because a rollback release may still be wanted.
---@param id string
---@return string[]
function Installer:orphans(id)
  local state = self.store:state(id)
  local out = {}
  for _, candidate in ipairs(self.store:list_install_ids(id)) do
    if candidate ~= state.install_id then
      out[#out + 1] = candidate
    end
  end
  return out
end

M.install_id = install_id

return M
