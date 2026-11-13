-- Install transaction: install, update, uninstall and their failure modes.
--
-- Uses the scripted npm from tests/fake_npm.lua, so nothing here touches the
-- network or a real npm cache.
return function(t)
  local store_mod = require("acp.manager.store")
  local lock_mod = require("acp.manager.lock")
  local npm_mod = require("acp.manager.npm")
  local Installer = require("acp.manager.install")
  local fake = require("tests.fake_npm")
  local registry = require("acp.manager.registry")

  local counter = 0
  local function temp_root()
    counter = counter + 1
    local dir = string.format("/tmp/opencode/acp-install-%d-%d", vim.uv.hrtime(), counter)
    vim.fn.mkdir(dir, "p")
    return dir
  end

  ---Build an installer over a temp root with a scripted npm.
  local function setup(fake_opts, config)
    local root = temp_root()
    local store = store_mod.new({
      root = function()
        return root
      end,
    })
    local locks = lock_mod.new({
      root = function()
        return root
      end,
    })
    local runner = fake.new(fake_opts)
    local npm = npm_mod.new({
      run = runner.run,
      node = function()
        return "node"
      end,
      npm = function()
        return "npm"
      end,
    })
    local progress = {}
    local installer = Installer.new({
      store = store,
      locks = locks,
      npm = npm,
      config = function()
        return vim.tbl_extend("force", {
          manager = { install_timeout = 5000, max_log_bytes = 4096 },
        }, config or {})
      end,
      notify = function() end,
      on_progress = function(event)
        progress[#progress + 1] = event
      end,
    })
    return {
      root = root,
      store = store,
      locks = locks,
      installer = installer,
      runner = runner,
      progress = progress,
      cleanup = function()
        locks:close()
        vim.fn.delete(root, "rf")
      end,
    }
  end

  local allow = function(_, answer)
    answer(true)
  end
  local deny = function(_, answer)
    answer(false)
  end

  ---Run an install and wait for the callback.
  local function run(fn, cb)
    local settled
    fn(function(ok, value)
      settled = { ok = ok, value = value }
    end)
    -- The scripted npm is synchronous, so the callback has already fired.
    assert(settled, "operation did not settle")
    return settled
  end

  t.describe("manager install", function()
    t.it("installs the resolved version and pins it only after verifying", function()
      local env = setup({ version = "1.2.3" })
      local result = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      t.eq(true, result.ok, vim.inspect(result.value))
      t.eq("1.2.3", result.value.version)

      local state = env.store:state("claude")
      t.eq("installed", state.status)
      t.eq("1.2.3", state.install.version)
      t.eq("@agentclientprotocol/claude-agent-acp", state.install.package)

      -- A pointer is written after the receipt, and the phases are visible.
      local phases = {}
      for _, event in ipairs(env.progress) do
        phases[#phases + 1] = event.phase
      end
      t.eq({ "checking", "installing", "verifying", "committed" }, phases)
      env.cleanup()
    end)

    t.it("does not touch anything when the user declines", function()
      local env = setup({ version = "1.2.3" })
      local result = run(function(cb)
        env.installer:install("claude", { confirm = deny }, cb)
      end)
      t.eq(false, result.ok)
      t.eq(true, result.value.cancelled)
      t.eq("not_installed", env.store:state("claude").status)
      -- Not even a version lookup should create an install directory.
      t.eq({}, env.store:list_install_ids("claude"))
      env.cleanup()
    end)

    t.it("keeps the previous release when an update fails", function()
      local env = setup({ version = "1.0.0" })
      local first = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      t.eq(true, first.ok)
      local old_id = first.value.install_id

      -- Second attempt resolves a new version but npm install fails.
      env.runner = nil
      local failing = fake.new({ version = "2.0.0", fail_install = true })
      env.installer.npm.run = failing.run
      local second = run(function(cb)
        env.installer:install("claude", { confirm = allow, action = "update" }, cb)
      end)
      t.eq(false, second.ok)

      local state = env.store:state("claude")
      t.eq("installed", state.status, "the old release must stay usable")
      t.eq(old_id, state.install_id)
      t.eq("1.0.0", state.install.version)
      env.cleanup()
    end)

    t.it("removes the half-built release when the install fails", function()
      local env = setup({ version = "1.0.0", fail_install = true })
      local result = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      t.eq(false, result.ok)
      t.eq({}, env.store:list_install_ids("claude"), "a failed install must not leave a release behind")
      env.cleanup()
    end)

    t.it("refuses when npm installs a different version than requested", function()
      local env = setup({ version = "1.0.0", installed_version = "6.6.6" })
      local result = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      t.eq(false, result.ok)
      t.match("6.6.6", result.value.message)
      t.eq("not_installed", env.store:state("claude").status)
      env.cleanup()
    end)

    t.it("refuses when the package ships no entrypoint", function()
      local env = setup({ version = "1.0.0", no_bin = true })
      local result = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      t.eq(false, result.ok)
      t.eq("not_installed", env.store:state("claude").status)
      env.cleanup()
    end)

    t.it("rejects ranges and paths before running npm", function()
      local env = setup({ version = "1.0.0" })
      for _, bad in ipairs({ "^1.0.0", ">=1", "latest-ish", "file:../../etc", "git+https://x", "-1.0.0", "" }) do
        local result = run(function(cb)
          env.installer:install("claude", { confirm = allow, version = bad }, cb)
        end)
        t.eq(false, result.ok, "expected " .. vim.inspect(bad) .. " to be refused")
      end
      t.eq(0, #env.runner.calls, "npm must not run for an invalid version")
      env.cleanup()
    end)

    t.it("refuses an agent the manager does not install", function()
      local env = setup({})
      local result = run(function(cb)
        env.installer:install("opencode", { confirm = allow }, cb)
      end)
      t.eq(false, result.ok)
      t.falsy(result.value.cancelled)
      t.eq("not_installed", env.store:state("opencode").status)
      env.cleanup()
    end)

    t.it("refuses update for an agent that is not installed", function()
      local env = setup({ version = "1.0.0" })
      local result = run(function(cb)
        env.installer:install("claude", { confirm = allow, action = "update" }, cb)
      end)
      t.eq(false, result.ok)
      t.match("not installed", result.value)
      env.cleanup()
    end)

    t.it("serialises two operations on the same agent", function()
      local env = setup({ version = "1.0.0" })
      local second
      -- Start one install; its confirm callback runs while the first is in
      -- flight, which is the same window a second click would use.
      env.installer:install("claude", {
        confirm = function(_, answer)
          second = run(function(cb)
            env.installer:install("claude", { confirm = allow }, cb)
          end)
          answer(true)
        end,
      }, function() end)
      t.eq(false, second.ok)
      t.match("already running", second.value)
      env.cleanup()
    end)

    t.it("uses the pi fork package for pi", function()
      local env = setup({ version = "0.4.0" })
      local result = run(function(cb)
        env.installer:install("pi", { confirm = allow }, cb)
      end)
      t.eq(true, result.ok, vim.inspect(result.value))
      local state = env.store:state("pi")
      t.eq("@geohar/pi-acp", state.install.package)
      env.cleanup()
    end)
  end)

  t.describe("manager uninstall", function()
    t.it("removes the pinned release and the pointer", function()
      local env = setup({ version = "1.0.0" })
      local installed = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      t.eq(true, installed.ok)
      local dir = installed.value.dir

      local result = run(function(cb)
        env.installer:uninstall("claude", { confirm = allow }, cb)
      end)
      t.eq(true, result.ok, vim.inspect(result.value))
      t.eq("not_installed", env.store:state("claude").status)
      t.falsy(vim.uv.fs_stat(dir), "the release directory must be gone")
      env.cleanup()
    end)

    t.it("does nothing when the user declines", function()
      local env = setup({ version = "1.0.0" })
      run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      local result = run(function(cb)
        env.installer:uninstall("claude", { confirm = deny }, cb)
      end)
      t.eq(false, result.ok)
      t.eq(true, result.value.cancelled)
      t.eq("installed", env.store:state("claude").status)
      env.cleanup()
    end)

    t.it("refuses while another instance is running that release", function()
      local env = setup({ version = "1.0.0" })
      local installed = run(function(cb)
        env.installer:install("claude", { confirm = allow }, cb)
      end)
      local lease = env.locks:lease("claude", installed.value.install_id)
      t.truthy(lease)
      local result = run(function(cb)
        env.installer:uninstall("claude", { confirm = allow }, cb)
      end)
      t.eq(false, result.ok)
      t.match("cannot remove", result.value.message)
      t.eq("installed", env.store:state("claude").status)
      env.locks:unlease(lease)
      env.cleanup()
    end)

    t.it("reports agents with no manager-owned install", function()
      local env = setup({})
      local result = run(function(cb)
        env.installer:uninstall("claude", { confirm = allow }, cb)
      end)
      t.eq(false, result.ok)
      t.match("no manager%-owned install", result.value)
      env.cleanup()
    end)
  end)

  t.describe("manager npm helpers", function()
    t.it("accepts exact versions and latest only", function()
      t.truthy(npm_mod.valid_version("1.2.3"))
      t.truthy(npm_mod.valid_version("1.2.3-beta.1"))
      t.truthy(npm_mod.valid_version("latest"))
      for _, bad in ipairs({ "^1.0.0", "~1.0.0", ">=2", "1.x", "beta", "file:../x", "-1.0.0", "" }) do
        t.falsy(npm_mod.valid_version(bad), "expected " .. vim.inspect(bad) .. " to be invalid")
      end
    end)

    t.it("rejects package names that could become flags or paths", function()
      t.truthy(npm_mod.valid_package("@geohar/pi-acp"))
      t.truthy(npm_mod.valid_package("pi-acp"))
      t.falsy(npm_mod.valid_package("--registry=http://evil"))
      t.falsy(npm_mod.valid_package("../../etc/passwd"))
      t.falsy(npm_mod.valid_package(""))
    end)

    t.it("checks the Node major version", function()
      t.truthy(npm_mod.node_satisfies("v22.1.0", 22))
      t.truthy(npm_mod.node_satisfies("v26.13.1", 22))
      t.falsy(npm_mod.node_satisfies("v20.11.0", 22))
      t.falsy(npm_mod.node_satisfies("garbage", 22))
      t.truthy(npm_mod.node_satisfies("", 0))
    end)

    t.it("launches a JS entrypoint through node, not a PATH shim", function()
      t.eq({ "/abs/dist/index.js", "acp" }, npm_mod.node_argv("/abs/dist/index.js", { "acp" }))
    end)

    t.it("declares the pi fork as installable with its real package", function()
      local entry = registry.get("pi")
      t.eq("@geohar/pi-acp", entry.package)
      t.eq("pi-acp", entry.bin)
      t.eq("dist/index.js", entry.entry)
    end)
  end)
end
