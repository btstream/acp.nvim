-- The npm side of the agent manager.
--
-- Everything here is argv-based: package names and versions come from the
-- built-in registry or from a user-typed exact version that is validated before
-- it reaches a process. No shell string is ever built, and no user-supplied
-- package name is accepted.
--
-- The runner is injected so tests can drive a fake npm without network access.
local log = require("acp.log")

local M = {}

---A version the manager is willing to pass to npm.
---
---Only an exact released version or "latest": ranges, tags other than latest,
---git URLs and local paths are refused. `npm install` would happily interpret
---all of them, which is exactly the risk being avoided.
---@param version string
---@return boolean
---@return string|nil reason
function M.valid_version(version)
  if type(version) ~= "string" or version == "" then
    return false, "version must be a string"
  end
  if version == "latest" then
    return true
  end
  -- Semver core with optional prerelease/build. Deliberately stricter than npm.
  if #version > 64 then
    return false, "version is too long"
  end
  if
    not version:match("^%d+%.%d+%.%d+")
    or not version:match("^[0-9A-Za-z%.%-%+]+$")
    or version:find("..", 1, true)
    or version:sub(1, 1) == "-"
  then
    return false, "version must be an exact release such as 1.2.3"
  end
  return true
end

---Check that a package name looks like an npm package and nothing else.
---
---The registry is the source of these, but a corrupted registry entry must not
---turn into a path or a flag on the command line.
---@param name string
---@return boolean
function M.valid_package(name)
  if type(name) ~= "string" or name == "" or #name > 128 then
    return false
  end
  if name:sub(1, 1) == "-" then
    return false
  end
  -- Scoped and unscoped names, optionally with a version suffix.
  local base = name:gsub("@[^@]*$", "")
  if base == "" then
    base = name
  end
  return base:match("^@?[%w%._%-]+/?[%w%._%-]*$") ~= nil
end

---@param opts {run: fun(argv: string[], opts: table, cb: fun(ok: boolean, result: any)),
---  node: fun(): string, npm: fun(): string, clock?: fun(): integer}
---@return table
function M.new(opts)
  return setmetatable({
    run = opts.run,
    node = opts.node,
    npm = opts.npm,
    clock = opts.clock or function()
      return vim.uv.now()
    end,
  }, { __index = M })
end

---Run npm with a bounded log and a timeout.
---
---The result is `{code, stdout, stderr, timed_out}`. Callers decide what a
---non-zero exit means; this layer only reports.
---@param argv string[]
---@param opts {cwd: string, timeout: integer, max_log_bytes: integer, env?: table}
---@param cb fun(ok: boolean, result: table)
function M:run_npm(argv, opts, cb)
  local args = { self.npm() }
  vim.list_extend(args, argv)
  -- Echo the command into the live log, the way Mason shows what it runs.
  if opts and type(opts.on_output) == "function" then
    pcall(opts.on_output, "$ " .. table.concat(args, " "))
    if opts.quiet then
      opts = vim.tbl_extend("force", {}, opts)
      opts.on_output = nil
    end
  end
  return self.run(args, opts, cb)
end

---Resolve the exact version `npm view` reports for a package.
---@param package string
---@param spec string|nil "latest" or an exact version
---@param opts {cwd: string, timeout: integer, max_log_bytes: integer}
---@param cb fun(ok: boolean, version_or_err: any)
function M:resolve_version(package, spec, opts, cb)
  if not M.valid_package(package) then
    cb(false, "invalid package name")
    return
  end
  spec = spec or "latest"
  if not M.valid_version(spec) then
    cb(false, "invalid version spec " .. tostring(spec))
    return
  end
  -- `npm view <pkg>@<spec> version --json` prints a JSON string (or an array
  -- when the range matches several releases, which an exact spec will not).
  -- The JSON answer is parsed, not shown: only the command is echoed.
  local view_opts = vim.tbl_extend("force", {}, opts or {}, { quiet = true })
  self:run_npm({ "view", package .. "@" .. spec, "version", "--json" }, view_opts, function(ok, result)
    if not ok then
      cb(false, result)
      return
    end
    local text = vim.trim(result.stdout or "")
    if text == "" then
      cb(false, "npm view returned no version")
      return
    end
    local decoded_ok, decoded = pcall(vim.json.decode, text)
    local version = decoded_ok and decoded or nil
    if type(version) == "table" then
      version = version[1]
    end
    if type(version) ~= "string" or not M.valid_version(version) or version == "latest" then
      cb(false, "npm view returned an unusable version: " .. text:sub(1, 80))
      return
    end
    cb(true, version)
  end)
end

---Write the minimal manifest npm installs from.
---
---Only the one dependency is listed: the Manager never adopts a project's
---package.json, and the version is already resolved to an exact release.
---@param dir string
---@param package string
---@param version string
---@return boolean ok
---@return string|nil err
function M.write_manifest(dir, package, version)
  if not M.valid_package(package) or not M.valid_version(version) then
    return false, "refusing to write a manifest with an unvalidated package or version"
  end
  local value = {
    name = "acp-nvim-managed",
    private = true,
    version = "0.0.0",
    description = "Installed by acp.nvim; do not edit.",
    dependencies = { [package] = version },
  }
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return false, "unable to encode the manifest"
  end
  local path = dir .. "/package.json"
  local fh, err = io.open(path, "wb")
  if not fh then
    return false, "unable to write " .. path .. ": " .. tostring(err)
  end
  local written = fh:write(encoded)
  fh:close()
  if not written then
    return false, "unable to write " .. path
  end
  return true
end

---Read the installed package version from its own package.json.
---
---This is the authoritative check: npm may have installed something other than
---what was requested (a tampered registry response, a mismatched cache), and the
---receipt must describe what is really on disk.
---@param dir string
---@param package string
---@return table|nil manifest
---@return string|nil err
function M.read_installed(dir, package)
  local path = dir .. "/node_modules/" .. package .. "/package.json"
  local fh = io.open(path, "rb")
  if not fh then
    return nil, "the package was not installed"
  end
  local text = fh:read("*a")
  fh:close()
  local ok, value = pcall(vim.json.decode, text or "")
  if not ok or type(value) ~= "table" then
    return nil, "the installed package.json is unreadable"
  end
  if value.name ~= package then
    return nil, string.format("installed package is %s, expected %s", tostring(value.name), package)
  end
  if type(value.version) ~= "string" or not M.valid_version(value.version) or value.version == "latest" then
    return nil, "the installed package has an unusable version"
  end
  return value
end

---Install the resolved version into an empty release directory.
---@param opts {dir: string, package: string, version: string, timeout: integer,
---  max_log_bytes: integer, env?: table}
---@param cb fun(ok: boolean, err: any)
function M:install(opts, cb)
  if not M.valid_package(opts.package) then
    cb(false, "invalid package name")
    return
  end
  if not M.valid_version(opts.version) or opts.version == "latest" then
    cb(false, "install requires an exact version")
    return
  end
  local written, write_err = M.write_manifest(opts.dir, opts.package, opts.version)
  if not written then
    cb(false, write_err)
    return
  end
  -- `--no-audit --no-fund` keeps the output bounded; `--omit=dev` avoids pulling
  -- test tooling into the data directory. Lifecycle scripts are left enabled
  -- because some packages need them to place their binary; the confirmation
  -- shown to the user states that plainly.
  self:run_npm({
    "install",
    "--no-audit",
    "--no-fund",
    "--omit=dev",
    "--loglevel=notice",
    "--progress=false",
  }, {
    cwd = opts.dir,
    timeout = opts.timeout,
    max_log_bytes = opts.max_log_bytes,
    env = opts.env,
    on_output = opts.on_output,
  }, function(ok, result)
    if not ok then
      cb(false, result)
      return
    end
    if result.code ~= 0 then
      cb(false, {
        message = "npm install failed with exit code " .. tostring(result.code),
        log = result.tail,
      })
      return
    end
    cb(true, nil)
  end)
end

---The argv used to launch an installed JS entrypoint.
---
---Running `node <abs entry>` instead of the shim on PATH keeps the launch
---independent of PATH order and avoids spawning `.cmd` shims on Windows.
---@param entry string absolute path to the entry script
---@param args string[]
---@return string[]
function M.node_argv(entry, args)
  local argv = { entry }
  for _, arg in ipairs(args or {}) do
    argv[#argv + 1] = arg
  end
  return argv
end

---Check the Node.js version against a minimum major.
---@param current string e.g. "v22.1.0"
---@param required_major integer
---@return boolean
function M.node_satisfies(current, required_major)
  if required_major <= 0 then
    return true
  end
  local major = tonumber((current or ""):match("^v?(%d+)"))
  if not major then
    return false
  end
  return major >= required_major
end

---Inspect the local toolchain without installing anything.
---@param probe fun(argv: string[], cb: fun(ok: boolean, out: string))|nil
---@return table {node, npm, node_version, ok, error}
function M:toolchain(probe)
  local info = { node = self.node(), npm = self.npm() }
  if not probe then
    info.ok = true
    return info
  end
  local done = false
  probe({ info.node, "--version" }, function(ok, out)
    if done then
      return
    end
    done = true
    if not ok then
      info.ok = false
      info.error = "node was not found: " .. tostring(out)
      return
    end
    info.node_version = vim.trim(out)
    probe({ info.npm, "--version" }, function(npm_ok, npm_out)
      if not npm_ok then
        info.ok = false
        info.error = "npm was not found: " .. tostring(npm_out)
        return
      end
      info.npm_version = vim.trim(npm_out)
      info.ok = true
      if self.on_toolchain then
        self.on_toolchain(info)
      end
    end)
  end)
  return info
end

---Log the command that failed, without the full environment.
---@param argv string[]
---@param result table|nil
function M.log_failure(argv, result)
  if not result then
    return
  end
  log.error("npm command failed (%s): %s", tostring(result.code), table.concat(argv, " "))
  if result.tail and result.tail ~= "" then
    log.error("%s", result.tail)
  end
end

return M
