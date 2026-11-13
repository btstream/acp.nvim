return function(t)
  local state = require("acp.session.state")
  local context = require("acp.context")
  local capabilities = require("acp.protocol.capabilities")

  t.describe("session pagination", function()
    local Catalog = require("acp.app.catalog")

    ---A catalog whose task calls go straight to `client`, with no coroutine.
    local function catalog_with(list_sessions)
      local client = { list_sessions = list_sessions }
      local titles, cwds = {}, {}
      return Catalog.new({
        titles = function()
          return titles
        end,
        cwds = function()
          return cwds
        end,
        client = function()
          return client
        end,
        connection = function()
          return "ready"
        end,
        run = function(_, _, _, fn, _, on_finally)
          local task = {
            status = "running",
            call = function(_, name, ...)
              return client[name](client, ...)
            end,
          }
          fn(task)
          if on_finally then
            on_finally(task, true)
          end
          return task
        end,
        on_changed = function() end,
        notify = function() end,
      })
    end

    t.it("follows nextCursor until the agent stops returning one", function()
      local pages = {
        { sessions = { { sessionId = "a", cwd = "/w" } }, nextCursor = "c1" },
        { sessions = { { sessionId = "b", cwd = "/w" } }, nextCursor = "c2" },
        { sessions = { { sessionId = "c", cwd = "/w" } } },
      }
      local asked = {}
      local catalog = catalog_with(function(_, scoped, cursor)
        asked[#asked + 1] = { scoped = scoped, cursor = cursor }
        return true, pages[#asked]
      end)
      local got
      catalog:list("/w", function(ok, sessions)
        got = { ok = ok, sessions = sessions }
      end)
      t.truthy(got)
      t.eq(true, got.ok)
      t.eq(3, #got.sessions)
      t.eq({ "a", "b", "c" }, { got.sessions[1].sessionId, got.sessions[2].sessionId, got.sessions[3].sessionId })
      t.eq(3, #asked)
      t.eq(nil, asked[1].cursor)
      t.eq("c1", asked[2].cursor)
      t.eq("c2", asked[3].cursor)
      t.eq("/w", asked[1].scoped)
    end)

    t.it("stops when an agent echoes the same cursor forever", function()
      local calls = 0
      local catalog = catalog_with(function()
        calls = calls + 1
        return true, { sessions = { { sessionId = "s" .. calls } }, nextCursor = "same" }
      end)
      local got
      catalog:list("/w", function(ok, sessions)
        got = { ok = ok, sessions = sessions }
      end)
      -- Page one establishes the cursor, page two sees it repeat and stops.
      t.eq(2, calls)
      t.eq(2, #got.sessions)
    end)

    t.it("resets the cursor when falling back to an unscoped list", function()
      local asked = {}
      local catalog = catalog_with(function(_, scoped, cursor)
        asked[#asked + 1] = { scoped = scoped, cursor = cursor }
        if scoped then
          return true, { sessions = {}, nextCursor = "scoped-more" }
        end
        if cursor == nil then
          return true, { sessions = { { sessionId = "elsewhere", cwd = "/other" } }, nextCursor = "all-more" }
        end
        return true, { sessions = {} }
      end)
      local got
      catalog:list("/w", function(ok, sessions)
        got = { ok = ok, sessions = sessions }
      end)
      t.eq(4, #asked)
      -- Two scoped pages (both empty), then the unscoped list restarts at nil.
      t.eq("/w", asked[1].scoped)
      t.eq("/w", asked[2].scoped)
      t.eq("scoped-more", asked[2].cursor)
      t.eq(nil, asked[3].scoped)
      t.eq(nil, asked[3].cursor)
      t.eq(nil, asked[4].scoped)
      t.eq("all-more", asked[4].cursor)
      t.eq(1, #got.sessions)
      t.eq("elsewhere", got.sessions[1].sessionId)
    end)

    t.it("reports a failed page instead of returning a partial list", function()
      local asked = 0
      local catalog = catalog_with(function()
        asked = asked + 1
        if asked == 2 then
          return false, { code = -32603, message = "boom" }
        end
        return true, { sessions = { { sessionId = "a" } }, nextCursor = "c1" }
      end)
      local got
      catalog:list("/w", function(ok, sessions)
        got = { ok = ok, sessions = sessions }
      end)
      t.eq(false, got.ok)
      t.eq(0, #got.sessions)
      t.eq(2, asked)
    end)
  end)

  t.describe("mcp servers", function()
    local mod = require("acp.protocol.client")

    ---A real client with the transport filtering wired in, and no process.
    local function client_with(caps, declared)
      local client = mod.new({
        agent = { command = "noop" },
        cwd = "/tmp",
        client_capabilities = {},
        mcp_servers = declared,
      })
      client.capabilities = { mcpCapabilities = caps }
      return client
    end

    t.it("always keeps stdio", function()
      local c = client_with({}, { { type = "stdio", command = "srv" } })
      t.eq(1, #c:mcp_servers())
    end)

    t.it("drops http and sse the agent does not advertise", function()
      local c = client_with({}, {
        { type = "stdio", command = "srv" },
        { type = "http", url = "https://x" },
        { type = "sse", url = "https://y" },
      })
      local kept = c:mcp_servers()
      t.eq(1, #kept)
      t.eq("stdio", kept[1].type)
    end)

    t.it("keeps the transports the agent advertises", function()
      local c = client_with({ http = true, sse = true }, {
        { type = "http", url = "https://x" },
        { type = "sse", url = "https://y" },
      })
      t.eq(2, #c:mcp_servers())
    end)

    t.it("returns an empty list when nothing is configured", function()
      t.eq({}, client_with({}):mcp_servers())
    end)
  end)

  t.describe("prompt capability degradation", function()
    local function cfg()
      return {
        context = {
          images = { enabled = true, max_bytes = 3 * 1024 * 1024, max_per_message = 4, path_mode = "inline" },
        },
      }
    end

    t.it("keeps an image block when the agent advertises image support", function()
      -- A missing file is reported, which proves the block builder ran.
      local att = { kind = "image", inline = true, label = "a.png", path = "/tmp/opencode/nope.png" }
      local blocks, err = context.to_prompt("hi", { att }, cfg(), {
        supports = function()
          return true
        end,
      })
      t.truthy(blocks)
      t.truthy(err, "expected the missing file to be reported")
    end)

    t.it("degrades to a resource_link when images are unsupported", function()
      local att = {
        kind = "image",
        inline = true,
        label = "a.png",
        path = "/tmp/opencode/nope.png",
        uri = "file:///tmp/a.png",
      }
      local blocks = context.to_prompt("hi", { att }, cfg(), {
        supports = function()
          return false
        end,
      })
      local link
      for _, block in ipairs(blocks) do
        if block.type == "resource_link" then
          link = block
        end
      end
      t.truthy(link, "the image was not degraded: " .. vim.inspect(blocks))
      t.eq("file:///tmp/a.png", link.uri)
    end)
  end)

  t.describe("capability probing", function()
    t.it("grants loadSession when the double implements it", function()
      local double = {
        has_session_capability = function()
          return false
        end,
        load_session = function()
          return true, {}
        end,
      }
      t.truthy(capabilities.supports(capabilities.agent(double), "loadSession"))
    end)

    t.it("uses the predicate for the session subset", function()
      local double = {
        has_session_capability = function(_, name)
          return name == "resume"
        end,
      }
      local caps = capabilities.agent(double)
      t.truthy(capabilities.supports(caps, "sessionCapabilities.resume"))
      t.falsy(capabilities.supports(caps, "sessionCapabilities.delete"))
    end)
  end)
end
