return function(t)
  local capabilities = require("acp.protocol.capabilities")
  local config = require("acp.config")
  local connection = require("acp.app.connection")

  t.describe("module layout", function()
    t.it("keeps ui/form independent of the app layer", function()
      local path = vim.fn.fnamemodify("lua/acp/ui/form.lua", ":p")
      local source = table.concat(vim.fn.readfile(path), "\n")
      t.falsy(source:find('require("acp.app.', 1, true), "ui/form.lua requires an app module")
    end)
  end)

  t.describe("client capabilities", function()
    t.it("advertises notices and form elicitation by default", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, {}))
      t.eq({ session = { notices = {} }, elicitation = { form = {} } }, caps)
    end)

    t.it("omits notices when disabled", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, { notices = false }))
      t.eq({ elicitation = { form = {} } }, caps)
    end)

    t.it("leaves unimplemented capabilities out", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, {}))
      t.truthy(capabilities.supports(caps, "elicitation.form"))
      t.falsy(capabilities.supports(caps, "elicitation.url"))
      t.falsy(capabilities.supports(caps, "auth.terminal"))
      t.falsy(capabilities.supports(caps, "_meta.terminal_output"))
    end)

    t.it("resolves dotted capability paths", function()
      local caps = {
        prompt = { image = true },
        session = { list = {} },
        loadSession = true,
        off = false,
        nil_value = vim.NIL,
      }
      t.truthy(capabilities.supports(caps, "prompt.image"))
      -- An advertised object means the capability exists.
      t.truthy(capabilities.supports(caps, "session.list"))
      t.truthy(capabilities.supports(caps, "loadSession"))
      t.falsy(capabilities.supports(caps, "off"))
      t.falsy(capabilities.supports(caps, "nil_value"))
      t.falsy(capabilities.supports(caps, "prompt.audio"))
      t.falsy(capabilities.supports(nil, "prompt.image"))
      t.falsy(capabilities.supports({ prompt = "image" }, "prompt.image"))
    end)

    t.it("keeps protocol/client independent of the ui layer", function()
      local path = vim.fn.fnamemodify("lua/acp/protocol/client.lua", ":p")
      local source = table.concat(vim.fn.readfile(path), "\n")
      t.falsy(source:find('require("acp.ui', 1, true), "protocol/client.lua requires a ui module")
    end)
  end)
end
