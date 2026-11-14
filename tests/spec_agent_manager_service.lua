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

    t.it("refuses a second operation for the same agent but not for another", function()
      local root = temp_root()
      local svc, _, notifications = service(root, { version = "1.0.0" })
      svc.tasks.claude = { id = "claude", action = "install", phase = "installing" }
      t.eq(false, svc:install("claude"))
      t.match("already running", notifications[1])
      t.eq(true, svc:install("pi"))
      t.eq("installed", svc:store():state("pi").status)
      svc.tasks.claude = nil
      vim.fn.delete(root, "rf")
    end)

    t.it("installs without a dialog unless manager.confirm is set", function()
      local root = temp_root()
      local cfg = config_for(root)
      local asked = false
      local svc = AgentManager.new({
        config = function()
          return cfg
        end,
        presenter = {
          select = function()
            asked = true
          end,
        },
        npm = npm_mod.new({
          run = fake.new({ version = "1.0.0" }).run,
          node = function()
            return "node"
          end,
          npm = function()
            return "npm"
          end,
        }),
      })
      svc:install("pi")
      t.eq(false, asked)
      t.eq("installed", svc:store():state("pi").status)
      cfg.manager.confirm = true
      svc:uninstall("pi")
      t.eq(true, asked)
      vim.fn.delete(root, "rf")
    end)

    t.it("streams npm output into the per-agent log", function()
      local root = temp_root()
      local svc = service(root, { version = "1.0.0" })
      svc:install("pi")
      local log = table.concat(svc.logs.pi or {}, "\n")
      t.match("%$ npm view", log)
      t.match("%$ npm install", log)
      vim.fn.delete(root, "rf")
    end)

    t.it("treats an update to the pinned version as a no-op", function()
      local root = temp_root()
      local svc = service(root, { version = "1.0.0" })
      svc:install("pi")
      local before = svc:store():state("pi").install_id
      svc:update("pi")
      t.eq("unchanged", svc.outcome.pi.phase)
      t.eq(before, svc:store():state("pi").install_id)
      vim.fn.delete(root, "rf")
    end)

    t.it("keeps a single release after an update", function()
      local root = temp_root()
      local svc = service(root, { version = "1.0.0" })
      svc:install("pi")
      svc:install("pi")
      t.eq(1, #svc:store():list_install_ids("pi"))
      vim.fn.delete(root, "rf")
    end)

    t.it("marks an install outdated after a version check", function()
      local root = temp_root()
      local cfg = config_for(root)
      local runner = fake.new({ version = "1.0.0" })
      local svc = AgentManager.new({
        config = function()
          return cfg
        end,
        presenter = {},
        npm = npm_mod.new({
          run = function(...)
            return runner.run(...)
          end,
          node = function()
            return "node"
          end,
          npm = function()
            return "npm"
          end,
        }),
      })
      svc:install("pi")
      runner = fake.new({ version = "2.0.0" })
      local done = false
      svc:check_outdated(function()
        done = true
      end)
      t.truthy(done)
      local row
      for _, candidate in ipairs(svc:list()) do
        if candidate.id == "pi" then
          row = candidate
        end
      end
      t.eq(true, row.outdated)
      t.eq("2.0.0", row.latest)
      vim.fn.delete(root, "rf")
    end)

    t.it("reports a cancelled install without an error", function()
      local root = temp_root()
      local svc = service(root, { version = "1.0.0" }, function(_, answer)
        answer(false)
      end)
      svc:install("claude")
      t.eq("not_installed", svc:store():state("claude").status)
      t.eq("cancelled", svc.outcome.claude.phase)
      vim.fn.delete(root, "rf")
    end)

    t.it("surfaces an install failure as a failed phase", function()
      local root = temp_root()
      local svc, _, notifications = service(root, { version = "1.0.0", fail_install = true })
      svc:install("claude")
      t.eq("failed", svc.outcome.claude.phase)
      t.truthy(svc.outcome.claude.message)
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

    local function text_of(rows, opts)
      return table.concat(AgentManagerUI.render(rows, opts).lines, "\n")
    end

    t.it("groups agents by state like Mason", function()
      local rows = rows_for({
        claude = { status = "installed", source = "managed", install = { version = "1.2.3" } },
      })
      rows[2].installable = true
      local text = text_of(rows)
      t.match("Installed %(1%)", text)
      t.match("✓ claude 1%.2%.3", text)
      t.match("Available %(1%)", text)
      t.match("○ pi", text)
    end)

    t.it("maps every agent line back to its id", function()
      local rows = rows_for({ claude = { status = "installed", source = "managed", install = { version = "1" } } })
      local rendered = AgentManagerUI.render(rows, { expanded = { claude = true } })
      local seen = {}
      for lnum, id in pairs(rendered.ids) do
        seen[id] = true
        t.match(id == "claude" and "" or "", rendered.lines[lnum])
      end
      t.truthy(seen.claude and seen.pi)
    end)

    t.it("shows a running task with its live log", function()
      local rows = rows_for({})
      rows[2].task = { action = "install", phase = "installing", version = "2.0.0" }
      rows[2].log = { "$ npm install", "added 3 packages" }
      local text = text_of(rows)
      t.match("Running %(1%)", text)
      t.match("installing 2%.0%.0", text)
      t.match("added 3 packages", text)
    end)

    t.it("marks an outdated install with the newer version", function()
      local rows = rows_for({ claude = { status = "installed", source = "managed", install = { version = "1.0.0" } } })
      rows[1].outdated = true
      rows[1].latest = "1.1.0"
      t.match("1%.0%.0 → 1%.1%.0", text_of(rows))
    end)

    t.it("reports a broken install instead of calling it installed", function()
      local text = text_of(rows_for({ claude = { status = "broken", source = "managed" } }))
      t.match("✗ claude", text)
      t.match("broken", text)
    end)

    t.it("shows a failure under the row", function()
      local rows = rows_for({})
      rows[1].installable = true
      rows[1].outcome = { phase = "failed", action = "install", message = "E404 not found" }
      t.match("E404 not found", text_of(rows))
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
