-- A fake npm for the manager tests.
--
-- The manager's real npm runner spawns processes; these tests need to be
-- offline and deterministic, so the runner is replaced with this scripted one.
-- It answers `npm view` and `npm install` the way the real tool would, including
-- the failure modes that matter: a mismatched version, a missing entrypoint and
-- a non-zero exit.
local M = {}

---A package that satisfies the registry entries used in tests.
---@param package string
---@param version string
---@param entry string
local function make_package(dir, package, version, entry)
  local base = dir .. "/node_modules/" .. package
  vim.fn.mkdir(base .. "/" .. vim.fs.dirname(entry), "p")
  local manifest = vim.json.encode({ name = package, version = version, type = "module" })
  local fh = assert(io.open(base .. "/package.json", "wb"))
  fh:write(manifest)
  fh:close()
  local script = assert(io.open(base .. "/" .. entry, "wb"))
  script:write("#!/usr/bin/env node\n")
  script:close()
end

---@param opts {version?: string, install_entry?: string, fail_install?: boolean,
---  fail_view?: boolean, installed_version?: string, no_bin?: boolean,
---  entry_override?: string}
---@return table runner
function M.new(opts)
  opts = opts or {}
  local calls = {}
  local runner = { calls = calls }
  runner.run = function(argv, run_opts, cb)
    local copy = vim.deepcopy(argv)
    calls[#calls + 1] = { argv = copy, opts = run_opts }
    local tail = copy[2] or ""
    if tail == "view" then
      if opts.fail_view then
        cb(true, { code = 1, stdout = "", stderr = "E404 not found", tail = "E404 not found" })
        return
      end
      local version = opts.version or "9.9.9"
      cb(true, { code = 0, stdout = vim.json.encode(version), stderr = "", tail = "" })
      return
    end
    if tail == "install" then
      if opts.fail_install then
        cb(true, { code = 1, stdout = "", stderr = "boom", tail = "npm error boom" })
        return
      end
      local cwd = run_opts.cwd
      -- Install whatever the manifest asked for, the way npm would.
      local package = opts.package or "fake-pkg"
      local fh = io.open(cwd .. "/package.json", "rb")
      if fh then
        local text = fh:read("*a")
        fh:close()
        local parsed_ok, value = pcall(vim.json.decode, text)
        if parsed_ok and type(value) == "table" and type(value.dependencies) == "table" then
          for name in pairs(value.dependencies) do
            package = name
          end
        end
      end
      if not opts.no_bin then
        make_package(
          cwd,
          package,
          opts.installed_version or opts.version or "9.9.9",
          opts.install_entry or opts.entry_override or "dist/index.js"
        )
      end
      cb(true, { code = 0, stdout = "added 1 package", stderr = "", tail = "" })
      return
    end
    cb(true, { code = 0, stdout = "", stderr = "", tail = "" })
  end
  return runner
end

M.make_package = make_package

return M
