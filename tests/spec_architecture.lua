return function(t)
  local stores = require("acp.app.stores")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. "lua/"

  ---Every `acp.*` module under lua/, keyed by dotted name.
  ---@return table<string, string>
  local function modules()
    local out = {}
    for _, path in ipairs(vim.fn.globpath(root, "**/*.lua", false, true)) do
      local rel = path:sub(#root + 1):gsub("%.lua$", ""):gsub("/", ".")
      out[rel] = path
    end
    return out
  end

  ---Static requires of a file. `v:lua.require'...'` strings are statusline
  ---expressions, not loads that happen at import time, so they are skipped.
  ---@param path string
  ---@return string[]
  local function deps(path)
    local out = {}
    local handle = io.open(path, "r")
    if not handle then
      return out
    end
    for line in handle:lines() do
      if not line:find("v:lua", 1, true) then
        for dep in line:gmatch("require%s*%(?%s*[\"']([%w%._%-]+)[\"']") do
          if dep:match("^acp%.") or dep == "acp" then
            out[#out + 1] = dep
          end
        end
      end
    end
    handle:close()
    return out
  end

  t.describe("controller size", function()
    t.it("stays a thin coordinator rather than collecting every feature", function()
      -- A budget, not a target: it catches "just one more branch" growth without
      -- forcing callers to contort the wiring. Raise it only with a note in
      -- docs/architecture.md explaining what earned the extra room.
      local budget = 700
      local count = 0
      local handle = io.open(root .. "acp/controller.lua", "r")
      if not handle then
        error("cannot find the controller")
      end
      for _ in handle:lines() do
        count = count + 1
      end
      handle:close()
      t.truthy(
        count <= budget,
        string.format(
          "acp/controller.lua is %d lines, over the %d-line budget: move the feature into app/* "
            .. "or raise the budget deliberately (and say why in docs/architecture.md)",
          count,
          budget
        )
      )
    end)
  end)

  t.describe("module graph", function()
    t.it("has no require cycles", function()
      local mods = modules()
      local state, stack, cycles = {}, {}, {}
      local function visit(name)
        if state[name] == "done" then
          return
        end
        if state[name] == "open" then
          local from = 1
          for index, open in ipairs(stack) do
            if open == name then
              from = index
              break
            end
          end
          local cycle = {}
          for index = from, #stack do
            cycle[#cycle + 1] = stack[index]
          end
          cycle[#cycle + 1] = name
          cycles[#cycles + 1] = table.concat(cycle, " -> ")
          return
        end
        state[name] = "open"
        stack[#stack + 1] = name
        for _, dep in ipairs(deps(mods[name])) do
          if mods[dep] and dep ~= name then
            visit(dep)
          end
        end
        stack[#stack] = nil
        state[name] = "done"
      end
      for name in pairs(mods) do
        visit(name)
      end
      t.eq({}, cycles, "require cycle(s): " .. table.concat(cycles, "; "))
    end)

    t.it("keeps protocol and session independent of the UI", function()
      local mods = modules()
      for name, path in pairs(mods) do
        if name:match("^acp%.protocol%.") or name:match("^acp%.session%.") then
          for _, dep in ipairs(deps(path)) do
            t.falsy(
              dep:match("^acp%.ui"),
              string.format("%s must not require %s: the lower layers cannot depend on the editor UI", name, dep)
            )
          end
        end
      end
    end)

    t.it("keeps app services off a concrete picker", function()
      local mods = modules()
      -- `app/presenter` is the single place allowed to import UI backends.
      local allowed = { ["acp.app.presenter"] = true, ["acp.app.connection"] = true }
      for name, path in pairs(mods) do
        if name:match("^acp%.app%.") and not allowed[name] then
          for _, dep in ipairs(deps(path)) do
            t.falsy(
              dep:match("^acp%.ui%.(picker|form|permission_details|session_picker|session_snacks|diff|icons)$"),
              string.format("%s must go through app/presenter, not require %s directly", name, dep)
            )
          end
        end
      end
    end)
  end)

  t.describe("state stores", function()
    t.it("partitions by owner and keeps the flat view working", function()
      local state = stores.new()
      state.client = "client-1"
      state.session = "session-1"
      state.chat = "chat-1"
      state.config = { agent = "opencode" }

      local split = stores.stores(state)
      t.eq("client-1", split.connection.client)
      t.eq("session-1", split.session.current)
      t.eq("chat-1", split.view.chat)
      -- `config` belongs to the plugin instance, not to a phase.
      t.eq("opencode", state.config.agent)

      -- The flat aliases are a view over the same data, not a copy.
      t.eq("client-1", state.client)
      t.eq("session-1", state.session)
      split.session.current = "session-2"
      t.eq("session-2", state.session)
    end)

    t.it("does not store the flat names on the object", function()
      local state = stores.new()
      state.client = "client-1"
      state.session = "session-1"
      -- A real split: the raw keys are absent, so nothing can read a stale copy.
      t.eq(nil, rawget(state, "client"))
      t.eq(nil, rawget(state, "session"))
      t.eq("client-1", rawget(state, "conn").client)
      t.eq("session-1", rawget(state, "sess").current)
    end)

    t.it("keeps the connection phase separate from the connection store", function()
      local state = stores.new()
      t.eq("stopped", state.connection)
      state.connection = "ready"
      t.eq("ready", stores.stores(state).connection.phase)
      t.eq("ready", state.connection)
    end)

    t.it("reports which store owns a field", function()
      t.eq("conn", stores.owner_of("client"))
      t.eq("sess", stores.owner_of("session"))
      t.eq("view", stores.owner_of("chat"))
      t.eq(nil, stores.owner_of("config"))
    end)

    t.it("lists every field under its store", function()
      local fields = stores.fields()
      local seen = {}
      for store, names in pairs(fields) do
        for _, name in ipairs(names) do
          t.eq(store, stores.owner_of(name), name .. " is listed under the wrong store")
          t.falsy(seen[name], "field listed twice: " .. name)
          seen[name] = true
        end
      end
      -- Every flat alias must be reachable from a real store.
      local split = stores.stores(stores.new())
      t.truthy(split.connection and split.session and split.view)
    end)

    t.it("initialises the defaults inside their stores", function()
      local state = stores.new()
      local split = stores.stores(state)
      t.eq("stopped", split.connection.phase)
      t.eq(false, split.connection.replaying)
      t.eq("table", type(split.session.all))
      t.eq("table", type(split.session.titles))
      t.eq("table", type(split.session.cwds))
      t.eq(0, vim.tbl_count(split.session.all))
    end)
  end)

  t.describe("client events", function()
    local Events = require("acp.app.events")

    local function harness()
      -- A real partitioned state: the event handlers address the stores.
      local state = stores.new()
      state.interactions = {}
      state.runtime = {}
      local calls = { chrome = 0, pruned = 0, blocks = {}, notified = {}, lost = 0 }
      state.interactions.resolved = function() end
      state.interactions.open = function() end
      state.runtime.apply = function()
        return state.session, true, false
      end
      local events = Events.new({
        state = function()
          return state
        end,
        refresh_chrome = function()
          calls.chrome = calls.chrome + 1
        end,
        notify = function(message)
          calls.notified[#calls.notified + 1] = message
        end,
        add_block = function(text)
          calls.blocks[#calls.blocks + 1] = text
        end,
        prune = function()
          calls.pruned = calls.pruned + 1
        end,
        on_exit = function()
          calls.lost = calls.lost + 1
          return true
        end,
      })
      return events, state, calls
    end

    t.it("routes starting and ready to the connection phase", function()
      local events, state, calls = harness()
      events:dispatch("starting", {})
      t.eq("starting", state.connection)
      events:dispatch("ready", {})
      t.eq("ready", state.connection)
      t.eq(2, calls.chrome)
    end)

    t.it("applies session updates through the runtime", function()
      local events, state, calls = harness()
      state.session = { id = "s", blocks = {} }
      state.sessions.s = state.session
      events:dispatch("session_update", { sessionId = "s", update = {} })
      t.eq(1, calls.pruned)
    end)

    t.it("adds a block and notifies on exit", function()
      local events, _, calls = harness()
      events:dispatch("exit", {})
      t.eq(1, calls.lost)
      t.eq(1, #calls.blocks)
      t.match("disconnected", calls.notified[1])
    end)

    t.it("ignores an unknown event instead of failing", function()
      local events = harness()
      events:dispatch("no_such_event", {})
    end)

    t.it("lets a service replace a handler", function()
      local events, _, calls = harness()
      local seen = 0
      events:register("ready", function()
        seen = seen + 1
      end)
      events:dispatch("ready", {})
      t.eq(1, seen)
      t.eq(0, calls.chrome)
    end)
  end)
end
