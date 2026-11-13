-- The manager service and its window: the decisions and the rendering.
--
-- The transaction itself is covered by spec_agent_install; this file checks that
-- the service wires it to the config, that listing never installs anything, and
-- that the window renders state without owning decisions.
return function(t)
  local AgentManager = require("acp.app.agent_manager")
  local AgentManagerUI = require("acp.ui.agent_manager")
  local Resolve = require("acp.manager.resolve")
  local Registry = require("acp.manager.registry")
  local Config = require("acp.config")
  local fake = require("tests.fake_npm")
  local npm_mod = require("acp.manager.npm")

  local function temp_root()
    local dir = string.format("/tmp/opencode/acp-svc-%d", vim.uv.hrtime())
    vim.fn.mkdir(dir, "p")
    return dir
  end

  local function config_for(root)
    return Config.validate(Config.merge(Config.defaults, { manager = { root = root } }))
  end

  local runner_calls = 0

  local function service(root, fake_opts, confirm)
    local cfg = config_for(root)
    local runner = fake.new(fake_opts or { version = "1.0.0" })
    local raw_run = runner.run
    runner.run = function(...)
      runner_calls = runner_calls + 1
      return raw_run(...)
    end
    local changes = 0
    local notifications = {}
    local svc = AgentManager.new({
      config = function()
        return cfg
      end,
      notify = function(message)
        notifications[#notifications + 1] = message
      end,
      presenter = {},
      npm = npm_mod.new({
        run = runner.run,
        node = function()
          return "node"
        end,
        npm = function()
          return "npm"
        end,
      }),
      confirm = confirm or function(_, answer)
        answer(true)
      end,
      on_changed = function()
        changes = changes + 1
      end,
    })
    return svc, cfg, notifications, function()
      return changes
    end
  end

  t.describe("agent manager service", function()
    t.it("lists every registry agent without installing or connecting", function()
      local root = temp_root()
      local svc = service(root)
      local rows = svc:list()
      t.eq(#Registry.ids(), #rows)
      local ids = {}
      for _, row in ipairs(rows) do
        ids[row.id] = true
        t.eq("not_installed", row.status)
      end
      t.truthy(ids.claude and ids.pi and ids.opencode)
      -- Listing reads the store only; no npm command may be issued.
      t.eq(0, runner_calls, "listing must not run npm")
      -- Nothing on disk either.
      t.eq({}, svc:store():list_install_ids("pi"))
      vim.fn.delete(root, "rf")
    end)

    t.it("marks the configured agent as current", function()
      local root = temp_root()
      local cfg = Config.merge(Config.defaults, { agent = "pi", manager = { root = root } })
      local runner = fake.new({ version = "1.0.0" })
      local svc = AgentManager.new({
        config = function()
          return cfg
        end,
        presenter = {},
        npm = npm_mod.new({
          run = runner.run,
          node = function()
            return "node"
          end,
          npm = function()
            return "npm"
          end,
        }),
      })
      for _, row in ipairs(svc:list()) do
        t.eq(row.id == "pi", row.current)
      end
      vim.fn.delete(root, "rf")
    end)

    t.it("installs through the service and reports managed afterwards", function()
      local root = temp_root()
      local svc, cfg = service(root, { version = "0.4.0" })
      t.eq(true, svc:install("pi"))
      t.eq(false, svc:busy())
      local rows = svc:list()
      local pi_row
      for _, row in ipairs(rows) do
        if row.id == "pi" then
          pi_row = row
        end
      end
      t.eq("installed", pi_row.status)
      t.eq("managed", pi_row.source)
      t.eq("@geohar/pi-acp", pi_row.install.package)
      -- The launch spec now points at the managed release, not npx.
      local spec = assert(Resolve.resolve(cfg, "pi", cfg.launch_origin, svc:store()))
      t.eq("managed", spec.source)
      vim.fn.delete(root, "rf")
    end)

    t.it("notifies and refuses a second concurrent operation", function()
      local root = temp_root()
      local svc, _, notifications = service(root, { version = "1.0.0" })
      svc.task = { id = "claude", action = "install" }
      t.eq(false, svc:install("pi"))
      t.match("already running", notifications[1])
      svc.task = nil
      vim.fn.delete(root, "rf")
    end)

    t.it("reports a cancelled install without an error", function()
      local root = temp_root()
      local svc = service(root, { version = "1.0.0" }, function(_, answer)
        answer(false)
      end)
      svc:install("claude")
      t.eq("not_installed", svc:store():state("claude").status)
      t.eq("cancelled", svc.progress.phase)
      vim.fn.delete(root, "rf")
    end)

    t.it("surfaces an install failure as a failed phase", function()
      local root = temp_root()
      local svc, _, notifications = service(root, { version = "1.0.0", fail_install = true })
      svc:install("claude")
      t.eq("failed", svc.progress.phase)
      t.truthy(svc.progress.message)
      local joined = table.concat(notifications, "\n")
      t.match("failed", joined)
      vim.fn.delete(root, "rf")
    end)

    t.it("asks for confirmation with the details a user needs", function()
      local root = temp_root()
      local seen
      local svc = service(root, { version = "2.5.0" }, function(details, answer)
        seen = details
        answer(false)
      end)
      svc:install("claude")
      t.truthy(seen)
      t.eq("claude", seen.id)
      t.eq("@agentclientprotocol/claude-agent-acp", seen.package)
      t.eq("2.5.0", seen.version)
      t.eq(root, seen.root)
      t.truthy(seen.homepage)
      vim.fn.delete(root, "rf")
    end)

    t.it("rebuilds its store when the root changes", function()
      local first = temp_root()
      local second = temp_root()
      local cfg = config_for(first)
      local svc = AgentManager.new({
        config = function()
          return cfg
        end,
        presenter = {},
        npm = npm_mod.new({
          run = fake.new({ version = "1.0.0" }).run,
          node = function()
            return "node"
          end,
          npm = function()
            return "npm"
          end,
        }),
        confirm = function(_, answer)
          answer(true)
        end,
      })
      svc:install("pi")
      t.eq("installed", svc:store():state("pi").status)
      cfg = config_for(second)
      t.eq("not_installed", svc:store():state("pi").status, "a new root must not see the old install")
      vim.fn.delete(first, "rf")
      vim.fn.delete(second, "rf")
    end)

    t.it("closes leases it holds", function()
      local root = temp_root()
      local svc = service(root)
      local lease = svc:locks():lease("pi", "rel-x")
      t.truthy(lease)
      svc:close()
      local busy = svc:locks():install_in_use("pi", "rel-x")
      t.falsy(busy)
      vim.fn.delete(root, "rf")
    end)
  end)

  t.describe("agent manager window", function()
    local function rows_for(states)
      local out = {}
      for _, id in ipairs({ "claude", "pi" }) do
        local state = states[id] or { status = "not_installed" }
        out[#out + 1] = {
          id = id,
          title = id,
          package = "pkg",
          status = state.status,
          source = state.source or "external",
          command = "npx",
          install = state.install,
          available = state.available ~= false,
          requires = {},
        }
      end
      return out
    end

    t.it("renders one row per agent with its state", function()
      local lines = AgentManagerUI.render(
        rows_for({
          claude = { status = "installed", source = "managed", install = { version = "1.2.3" } },
          pi = { status = "not_installed" },
        }),
        nil,
        "claude"
      )
      local text = table.concat(lines, "\n")
      t.match("claude", text)
      t.match("installed  1%.2%.3", text)
      t.match("pi", text)
    end)

    t.it("distinguishes a managed install from an external one", function()
      local lines = AgentManagerUI.render(
        rows_for({
          claude = { status = "installed", source = "managed", install = { version = "1.0.0" } },
          pi = { status = "not_installed", source = "external" },
        }),
        nil,
        "claude"
      )
      local text = table.concat(lines, "\n")
      t.match("managed  installed", text)
      t.match("external", text)
    end)

    t.it("shows the progress line while a task runs", function()
      local lines = AgentManagerUI.render(rows_for({}), { id = "pi", phase = "installing", version = "2.0.0" }, "pi")
      t.match("installing 2%.0%.0", table.concat(lines, "\n"))
    end)

    t.it("reports a broken install instead of calling it installed", function()
      local lines =
        AgentManagerUI.render(rows_for({ claude = { status = "broken", source = "managed" } }), nil, "claude")
      t.match("broken", table.concat(lines, "\n"))
    end)

    t.it("never opens a window until asked", function()
      local ui = AgentManagerUI.new({
        manager = {
          list = function()
            return rows_for({})
          end,
        },
        config = function()
          return {}
        end,
        on_use = function() end,
      })
      t.eq(false, ui:is_open())
    end)
  end)
end
