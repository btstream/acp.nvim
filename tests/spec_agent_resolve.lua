-- Launch resolution: which command actually runs, and why.
--
-- The interesting cases are the ones a value comparison cannot decide: a user
-- who writes the same command as the preset, a user who only overrides `env`,
-- and a managed install that is missing or broken.
return function(t)
  local Config = require("acp.config")
  local Resolve = require("acp.manager.resolve")
  local store_mod = require("acp.manager.store")

  local function merged(raw)
    local cfg = Config.merge(Config.defaults, raw or {})
    cfg.launch_origin = Resolve.provenance(raw)
    return Config.validate(cfg)
  end

  ---A store over a temp root, optionally with a release pinned.
  local function store_with(releases)
    local root = string.format("/tmp/opencode/acp-resolve-%d", vim.uv.hrtime())
    vim.fn.mkdir(root, "p")
    local store = store_mod.new({
      root = function()
        return root
      end,
    })
    for _, id in ipairs(releases or {}) do
      local release = string.format("v1.0.0-%d", vim.uv.hrtime())
      local dir = assert(store:release_dir(id, release))
      vim.fn.mkdir(dir .. "/node_modules/@geohar/pi-acp/dist", "p")
      local fh = assert(io.open(dir .. "/node_modules/@geohar/pi-acp/dist/index.js", "wb"))
      fh:write("#!/usr/bin/env node\n")
      fh:close()
      assert(store:write_receipt(id, {
        installId = release,
        package = "@geohar/pi-acp",
        version = "1.0.0",
        entry = "node_modules/@geohar/pi-acp/dist/index.js",
        runtime = "node",
      }))
      assert(store:write_pointer(id, release))
    end
    return store, root
  end

  t.describe("launch provenance", function()
    t.it("only records the fields the user actually wrote", function()
      local prov = Resolve.provenance({
        agents = {
          pi = { env = { KEY = "1" } },
          claude = { command = "claude-agent-acp" },
          custom = { args = { "--acp" } },
        },
      })
      t.eq({ command = false, args = false, env = true }, prov.pi)
      t.eq({ command = true, args = false, env = false }, prov.claude)
      t.eq({ command = false, args = true, env = false }, prov.custom)
    end)

    t.it("treats a value identical to the preset as user-written", function()
      -- The whole reason value comparison is wrong: this is a deliberate
      -- override that happens to look like the default.
      local raw = { agents = { pi = { command = "npx", args = { "-y", "@geohar/pi-acp" } } } }
      local cfg = merged(raw)
      local spec = assert(Resolve.resolve(cfg, "pi", cfg.launch_origin))
      t.eq("external", spec.source, "an explicit command must not be replaced by a managed install")
    end)

    t.it("does not treat an env-only override as a launch override", function()
      local cfg = merged({ agents = { pi = { env = { TOKEN = "x" } } } })
      local prov = cfg.launch_origin.pi
      t.eq(false, prov.command)
      t.eq(true, prov.env)
    end)

    t.it("defaults to the external preset when nothing is managed", function()
      local cfg = merged({})
      local store, root = store_with({})
      local spec = assert(Resolve.resolve(cfg, "pi", cfg.launch_origin, store))
      t.eq("external", spec.source)
      t.eq("npx", spec.command)
      t.eq({ "-y", "@geohar/pi-acp" }, spec.args)
      vim.fn.delete(root, "rf")
    end)
  end)

  t.describe("launch resolution", function()
    t.it("runs a managed release through node, overriding the preset", function()
      local store, root = store_with({ "pi" })
      local cfg = merged({})
      local spec = assert(Resolve.resolve(cfg, "pi", cfg.launch_origin, store))
      t.eq("managed", spec.source)
      t.eq("node", spec.command)
      t.eq(1, #spec.args)
      t.match("node_modules/@geohar/pi%-acp/dist/index%.js$", spec.args[1])
      t.eq("1.0.0", spec.version)
      t.truthy(spec.install_id)
      vim.fn.delete(root, "rf")
    end)

    t.it("an explicit command still wins over a managed install", function()
      local store, root = store_with({ "pi" })
      local cfg = merged({ agents = { pi = { command = "/opt/custom-pi" } } })
      local spec = assert(Resolve.resolve(cfg, "pi", cfg.launch_origin, store))
      t.eq("external", spec.source)
      t.eq("/opt/custom-pi", spec.command)
      vim.fn.delete(root, "rf")
    end)

    t.it("managed refuses instead of falling back when nothing is installed", function()
      local store, root = store_with({})
      local cfg = merged({ agents = { pi = { source = "managed" } } })
      local spec, err = Resolve.resolve(cfg, "pi", cfg.launch_origin, store)
      t.falsy(spec)
      t.match("not installed", err)
      vim.fn.delete(root, "rf")
    end)

    t.it("managed refuses a broken install rather than running another version", function()
      local store, root = store_with({ "pi" })
      local state = store:state("pi")
      vim.fn.delete(state.dir .. "/node_modules/@geohar/pi-acp/dist/index.js")
      local cfg = merged({ agents = { pi = { source = "managed" } } })
      local spec, err = Resolve.resolve(cfg, "pi", cfg.launch_origin, store)
      t.falsy(spec)
      t.match("unusable", err)
      vim.fn.delete(root, "rf")
    end)

    t.it("rejects managed together with an explicit command", function()
      local cfg = merged({
        agents = { pi = { source = "managed", command = "/opt/pi" } },
      })
      local spec, err = Resolve.resolve(cfg, "pi", cfg.launch_origin)
      t.falsy(spec)
      t.match("both", err)
    end)

    t.it("external never consults the manager", function()
      local store, root = store_with({ "pi" })
      local cfg = merged({ agents = { pi = { source = "external" } } })
      local spec = assert(Resolve.resolve(cfg, "pi", cfg.launch_origin, store))
      t.eq("external", spec.source)
      t.eq("npx", spec.command)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports an unknown agent instead of inventing one", function()
      local cfg = merged({})
      local spec, err = Resolve.resolve(cfg, "nope", cfg.launch_origin)
      t.falsy(spec)
      t.match("not configured", err)
    end)

    t.it("describes an unavailable agent without raising", function()
      local store, root = store_with({})
      local cfg = merged({ agents = { pi = { source = "managed" } } })
      local info = Resolve.describe(cfg, "pi", cfg.launch_origin, store)
      t.eq(false, info.available)
      t.truthy(info.error)
      t.eq("pi", info.id)
      vim.fn.delete(root, "rf")
    end)
  end)

  t.describe("manager configuration", function()
    t.it("defaults the root under the data directory", function()
      local cfg = merged({})
      local root = Resolve.manager_root(cfg)
      t.match("acp/agents$", root)
      t.truthy(root:find(vim.fn.stdpath("data"), 1, true) == 1)
    end)

    t.it("honours a configured root", function()
      local cfg = merged({ manager = { root = "/tmp/somewhere/agents" } })
      t.eq("/tmp/somewhere/agents", Resolve.manager_root(cfg))
    end)

    t.it("rejects a command line masquerading as an executable", function()
      t.raises(function()
        merged({ manager = { npm = "npm install --global" } })
      end, "single executable")
    end)

    t.it("rejects an unknown install source", function()
      t.raises(function()
        merged({ agents = { pi = { source = "somewhere" } } })
      end, "source must be auto, managed or external")
    end)

    t.it("accepts the three documented sources", function()
      for _, source in ipairs({ "auto", "managed", "external" }) do
        local cfg = merged({ agents = { pi = { source = source } } })
        t.eq(source, cfg.agents.pi.source)
      end
    end)

    t.it("validates the timeout and log budget", function()
      t.raises(function()
        merged({ manager = { install_timeout = 10 } })
      end, "manager.install_timeout")
      t.raises(function()
        merged({ manager = { max_log_bytes = 10 } })
      end, "manager.max_log_bytes")
    end)
  end)

  t.describe("launch spec and terminal login", function()
    t.it("keeps the managed release for the login command", function()
      local Auth = require("acp.app.auth")
      local launch = {
        command = "node",
        args = { "/data/acp/agents/pi/releases/v1/node_modules/@geohar/pi-acp/dist/index.js" },
        env = { PI_HOME = "/x" },
        source = "managed",
      }
      local spec = Auth.terminal_spec({ args = { "--terminal-login" }, env = { EXTRA = "1" } }, {}, launch)
      t.eq("node", spec.command)
      t.eq(2, #spec.args)
      t.match("index%.js$", spec.args[1])
      t.eq("--terminal-login", spec.args[2])
      t.eq("1", spec.env.EXTRA)
      t.eq("/x", spec.env.PI_HOME)
      t.eq("managed", spec.source)
    end)

    t.it("falls back to the configured agent when there is no live client", function()
      local Auth = require("acp.app.auth")
      local spec = Auth.terminal_spec({ args = { "--login" } }, { command = "npx", args = { "-y", "pkg" } })
      t.eq("npx", spec.command)
      t.eq({ "-y", "pkg", "--login" }, spec.args)
    end)
  end)

  t.describe("agent switch keeps provenance", function()
    t.it("a re-setup from the merged config does not turn presets into overrides", function()
      local store, root = store_with({ "pi" })
      local controller = require("acp.controller")
      controller.setup({ agent = "opencode", manager = { root = root } })
      local first = Config.current
      t.eq(false, first.launch_origin.pi ~= nil and first.launch_origin.pi.command)
      -- What pick_agent does: copy the merged config and change the agent.
      local copy = vim.deepcopy(first)
      copy.agent = "pi"
      controller.setup(copy, { discard_queued = true })
      local spec = assert(Resolve.resolve(Config.current, "pi", Config.current.launch_origin, store))
      t.eq("managed", spec.source)
      controller.setup({ agent = "opencode" }, { discard_queued = true })
      vim.fn.delete(root, "rf")
    end)
  end)
end
