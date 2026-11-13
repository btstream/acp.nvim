-- Store, lock and registry: the parts of the agent manager that never touch the
-- network. Everything here runs against a throwaway directory.
return function(t)
  local store_mod = require("acp.manager.store")
  local lock_mod = require("acp.manager.lock")
  local registry = require("acp.manager.registry")

  local counter = 0
  local function temp_root()
    counter = counter + 1
    local dir = string.format("/tmp/opencode/acp-manager-%d-%d", vim.uv.hrtime(), counter)
    vim.fn.mkdir(dir, "p")
    return dir
  end

  local function new_store(root)
    return store_mod.new({
      root = function()
        return root
      end,
    })
  end

  ---Write a release the way the installer will, without running npm.
  local function fake_release(root, id, install_id, opts)
    opts = opts or {}
    local store = new_store(root)
    local dir = assert(store:release_dir(id, install_id))
    vim.fn.mkdir(dir .. "/dist", "p")
    local entry = opts.entry or "dist/index.js"
    local fh = assert(io.open(dir .. "/" .. entry, "wb"))
    fh:write("#!/usr/bin/env node\n")
    fh:close()
    local receipt = {
      installId = install_id,
      package = opts.package or "pkg",
      version = opts.version or "1.0.0",
      entry = entry,
      bin = "bin",
      runtime = "node",
      platform = "linux",
      arch = "x64",
    }
    assert(store:write_receipt(id, receipt))
    if opts.point ~= false then
      assert(store:write_pointer(id, install_id))
    end
    return store
  end

  t.describe("manager registry", function()
    t.it("maps the pi fork to its scoped package, not the upstream name", function()
      local pi = registry.get("pi")
      t.truthy(pi)
      t.eq("@geohar/pi-acp", pi.package)
      t.eq("https://github.com/georgeharker/pi-acp", pi.homepage)
      t.falsy(pi.package == "pi-acp", "must not use the unscoped upstream package")
    end)

    t.it("only reports installable for verified entries", function()
      local ok = registry.installable("claude")
      t.truthy(ok)
      local pi_ok = registry.installable("pi")
      t.truthy(pi_ok)
      local opencode_ok, reason = registry.installable("opencode")
      t.falsy(opencode_ok)
      t.truthy(reason)
      local missing_ok, missing_reason = registry.installable("nope")
      t.falsy(missing_ok)
      t.match("unknown agent", missing_reason)
    end)

    t.it("refuses to resolve a package for an agent it does not install", function()
      t.eq(nil, registry.package_of("opencode"))
      t.eq("@geohar/pi-acp", registry.package_of("pi"))
    end)

    t.it("records the Node requirement the adapters actually need", function()
      t.eq(22, registry.get("claude").node_major)
      -- pi's package.json says >=20 but its README requires 22+.
      t.eq(22, registry.get("pi").node_major)
    end)
  end)

  t.describe("manager store", function()
    t.it("rejects ids and paths that could escape the root", function()
      local root = temp_root()
      local store = new_store(root)
      t.falsy(store_mod.valid_id("../etc"))
      t.falsy(store_mod.valid_id("a/b"))
      t.falsy(store_mod.valid_id(""))
      t.falsy(store_mod.valid_id(".hidden"))
      t.truthy(store_mod.valid_id("claude"))
      t.truthy(store_mod.valid_id("pi-2"))

      local dir, err = store:agent_dir("../escape")
      t.falsy(dir)
      t.truthy(err)
      vim.fn.delete(root, "rf")
    end)

    t.it("refuses dangerous roots", function()
      local ok, reason = store_mod.check_root("/")
      t.falsy(ok)
      t.match("filesystem root", reason)
      local home = vim.uv.os_homedir()
      if home then
        local home_ok = store_mod.check_root(home)
        t.falsy(home_ok)
      end
      t.falsy(store_mod.check_root(vim.fn.getcwd()))
      t.truthy(store_mod.check_root(temp_root()))
    end)

    t.it("compares path containment by component, not by string prefix", function()
      t.truthy(store_mod.contains("/a/agents", "/a/agents/claude"))
      t.truthy(store_mod.contains("/a/agents", "/a/agents"))
      t.falsy(store_mod.contains("/a/agents", "/a/agents-evil/x"))
      t.falsy(store_mod.contains("/a/agents", "/a"))
      t.falsy(store_mod.contains("/a/agents", "/a/agents/../escape"))
    end)

    t.it("reports not_installed for an empty root", function()
      local root = temp_root()
      local state = new_store(root):state("claude")
      t.eq("not_installed", state.status)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports installed once a pointer and receipt agree", function()
      local root = temp_root()
      local store = fake_release(root, "claude", "rel-1")
      local state = store:state("claude")
      t.eq("installed", state.status)
      t.eq("rel-1", state.install_id)
      t.eq("1.0.0", state.install.version)
      t.eq("installed", state.status)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports broken when the entrypoint disappeared", function()
      local root = temp_root()
      local store = fake_release(root, "claude", "rel-1")
      local dir = assert(store:release_dir("claude", "rel-1"))
      vim.fn.delete(dir .. "/dist/index.js")
      local state = store:state("claude")
      t.eq("broken", state.status)
      t.match("entrypoint is missing", state.error)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports broken for a hand-edited receipt that escapes the release", function()
      local root = temp_root()
      local store = fake_release(root, "claude", "rel-1")
      local dir = assert(store:release_dir("claude", "rel-1"))
      assert(store_mod.write_json_atomic(dir .. "/receipt.json", {
        schemaVersion = 1,
        agentId = "claude",
        installId = "rel-1",
        package = "pkg",
        version = "1.0.0",
        entry = "../../../usr/bin/env",
      }))
      local state = store:state("claude")
      t.eq("broken", state.status)
      t.match("escapes the release directory", state.error)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports broken rather than trusting an unknown schema", function()
      local root = temp_root()
      local store = fake_release(root, "claude", "rel-1")
      local dir = assert(store:release_dir("claude", "rel-1"))
      assert(store_mod.write_json_atomic(dir .. "/receipt.json", { schemaVersion = 99, installId = "rel-1" }))
      local state = store:state("claude")
      t.eq("broken", state.status)
      t.match("schemaVersion", state.error)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports broken for an unreadable pointer instead of falling back", function()
      local root = temp_root()
      local store = fake_release(root, "claude", "rel-1")
      local dir = assert(store:agent_dir("claude"))
      local fh = assert(io.open(dir .. "/current.json", "wb"))
      fh:write("{not json")
      fh:close()
      local state = store:state("claude")
      t.eq("broken", state.status)
      t.match("not valid JSON", state.error)
      vim.fn.delete(root, "rf")
    end)

    t.it("keeps agents independent", function()
      local root = temp_root()
      fake_release(root, "claude", "rel-a", { version = "1.0.0" })
      fake_release(root, "pi", "rel-b", { version = "2.0.0" })
      local store = new_store(root)
      t.eq("1.0.0", store:state("claude").install.version)
      t.eq("2.0.0", store:state("pi").install.version)
      t.eq({ "rel-a" }, store:list_install_ids("claude"))
      t.eq({ "rel-b" }, store:list_install_ids("pi"))
      vim.fn.delete(root, "rf")
    end)
  end)

  t.describe("manager lock", function()
    t.it("serialises two callers for the same agent", function()
      local root = temp_root()
      local locks = lock_mod.new({
        root = function()
          return root
        end,
      })
      local first = locks:acquire("claude")
      t.truthy(first)
      local second, err = locks:acquire("claude")
      t.falsy(second)
      t.match("another instance", err)
      locks:release(first)
      local third = locks:acquire("claude")
      t.truthy(third, "the lock must be reusable after release")
      locks:release(third)
      vim.fn.delete(root, "rf")
    end)

    t.it("lets different agents proceed at the same time", function()
      local root = temp_root()
      local locks = lock_mod.new({
        root = function()
          return root
        end,
      })
      local a = locks:acquire("claude")
      local b = locks:acquire("pi")
      t.truthy(a)
      t.truthy(b)
      locks:release(a)
      locks:release(b)
      vim.fn.delete(root, "rf")
    end)

    t.it("treats a dead-pid, old lock as abandoned", function()
      local root = temp_root()
      local locks = lock_mod.new({
        root = function()
          return root
        end,
      })
      local dir = root .. "/.locks/claude"
      vim.fn.mkdir(dir, "p")
      assert(lock_mod.write_json_atomic(dir .. "/owner.json", {
        host = lock_mod.hostname(),
        pid = 999999,
        -- Ten minutes old: past STALE_MS, so the holder is not coming back.
        heartbeat = vim.uv.now() - 10 * 60 * 1000,
      }))
      local handle = locks:acquire("claude")
      t.truthy(handle, "an abandoned lock must be reclaimable")
      locks:release(handle)
      vim.fn.delete(root, "rf")
    end)

    t.it("does not steal a lock whose age cannot be established", function()
      -- A record with no heartbeat could be a crash mid-write; reclaiming it
      -- could start a second installer in the same directory.
      local live, reason = lock_mod.alive({
        host = lock_mod.hostname(),
        pid = 999999,
        heartbeat = 0,
      }, "/x")
      t.truthy(live)
      t.match("is gone", reason)
    end)

    t.it("does not steal a lock from another host", function()
      local live = lock_mod.alive({
        host = "some-other-host",
        pid = 1,
        heartbeat = 0,
      }, "/x")
      t.truthy(live)
    end)

    t.it("refuses a lock whose pid belongs to another user", function()
      -- pid 1 exists on every machine but cannot be signalled by us.
      local live, reason = lock_mod.alive({
        host = lock_mod.hostname(),
        pid = 1,
        heartbeat = 0,
      }, "/x")
      if vim.uv.os_getuid and vim.uv.os_getuid() ~= 0 then
        t.truthy(live)
        t.match("cannot be signalled", reason)
      end
    end)

    t.it("records a lease that blocks installation of that release", function()
      local root = temp_root()
      local locks = lock_mod.new({
        root = function()
          return root
        end,
      })
      local lease = locks:lease("claude", "rel-1")
      t.truthy(lease)
      local busy, reason = locks:install_in_use("claude", "rel-1")
      t.truthy(busy)
      t.match("in use", reason)
      local other, other_reason = locks:install_in_use("claude", "rel-2")
      t.falsy(other, other_reason)
      locks:unlease(lease)
      local released = locks:install_in_use("claude", "rel-1")
      t.falsy(released)
      vim.fn.delete(root, "rf")
    end)

    t.it("cleans up stale leases left by a crash", function()
      local root = temp_root()
      local locks = lock_mod.new({
        root = function()
          return root
        end,
      })
      local dir = root .. "/.leases/claude"
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/lease-999999.json"
      assert(lock_mod.write_json_atomic(path, {
        host = lock_mod.hostname(),
        pid = 999999,
        installId = "rel-old",
        heartbeat = vim.uv.now() - 10 * 60 * 1000,
      }))
      local live = locks:live_leases("claude")
      t.eq(0, #live)
      t.falsy(vim.uv.fs_stat(path), "the stale lease file must be removed")
      vim.fn.delete(root, "rf")
    end)

    t.it("close releases every lease this instance holds", function()
      local root = temp_root()
      local locks = lock_mod.new({
        root = function()
          return root
        end,
      })
      locks:lease("claude", "rel-1")
      locks:lease("pi", "rel-2")
      locks:close()
      t.falsy(locks:install_in_use("claude", "rel-1"))
      t.falsy(locks:install_in_use("pi", "rel-2"))
      vim.fn.delete(root, "rf")
    end)
  end)
end
