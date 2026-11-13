-- The launch spec must survive into the running client.
--
-- The terminal login reads `client.launch`, so a managed install has to be
-- recorded there; otherwise the login would fall back to the configured command
-- and could talk to a different version.
return function(t)
  local Client = require("acp.protocol.client")

  t.describe("client launch spec", function()
    t.it("keeps the launch spec it was started with", function()
      local launch = {
        command = "node",
        args = { "/data/acp/agents/pi/releases/v1/index.js" },
        source = "managed",
        install_id = "v1",
        version = "0.4.0",
      }
      local client = Client.new({
        agent = { command = "node", args = launch.args },
        cwd = "/tmp",
        client_capabilities = {},
        launch = launch,
      })
      t.eq("managed", client.launch.source)
      t.eq("v1", client.launch.install_id)
      t.eq("0.4.0", client.launch.version)
    end)

    t.it("leaves launch nil for an external client", function()
      local client = Client.new({
        agent = { command = "opencode", args = { "acp" } },
        cwd = "/tmp",
        client_capabilities = {},
      })
      t.eq(nil, client.launch)
    end)
  end)
end
