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
    t.it("advertises notices, form elicitation and terminal auth by default", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, {}))
      t.eq({
        session = { notices = {}, configOptions = { boolean = {} } },
        elicitation = { form = {} },
        auth = { terminal = true },
        _meta = { ["terminal-auth"] = true },
      }, caps)
    end)

    t.it("advertises boolean config options", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, {}))
      t.truthy(capabilities.supports(caps, "session.configOptions.boolean"))
      local off = connection.client_capabilities(
        config.merge(config.defaults, { capabilities = { boolean_config_options = false } })
      )
      t.falsy(capabilities.supports(off, "session.configOptions.boolean"))
    end)

    t.it("omits notices when disabled", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, { notices = false }))
      t.falsy(capabilities.supports(caps, "session.notices"))
      t.truthy(capabilities.supports(caps, "elicitation.form"))
    end)

    t.it("leaves unimplemented capabilities out", function()
      local caps = connection.client_capabilities(config.merge(config.defaults, {}))
      t.truthy(capabilities.supports(caps, "elicitation.form"))
      t.falsy(capabilities.supports(caps, "elicitation.url"))
      t.truthy(capabilities.supports(caps, "auth.terminal"))
      t.truthy(capabilities.supports(caps, "_meta.terminal-auth"))
      t.falsy(capabilities.supports(caps, "_meta.terminal_output"))
    end)

    t.it("honours the auth switch", function()
      local caps =
        connection.client_capabilities(config.merge(config.defaults, { capabilities = { auth_terminal = false } }))
      t.falsy(capabilities.supports(caps, "auth.terminal"))
      t.falsy(capabilities.supports(caps, "_meta.terminal-auth"))
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
