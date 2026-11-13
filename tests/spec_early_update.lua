return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")
  local Runtime = require("acp.session.runtime")
  local config = require("acp.config")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

  local function setup(env, overrides)
    acp.setup(vim.tbl_deep_extend("force", {
      agent = "opencode",
      agents = {
        opencode = {
          command = "python3",
          args = { root .. "tests/mock_agent.py" },
          env = env,
        },
      },
      permissions = { prompt = "native" },
    }, overrides or {}))
    controller.open()
    return controller.state()
  end

  t.describe("session creation buffer", function()
    t.it("applies updates that arrive before session/new returns", function()
      local S = setup({ ACP_MOCK_EARLY_UPDATE = "1" })
      vim.wait(8000, function()
        return S.session ~= nil
      end, 20)
      t.truthy(S.session)
      local found
      for _, command in ipairs(S.session.commands or {}) do
        if command.name == "early" then
          found = command
        end
      end
      t.truthy(found, "early available_commands_update was dropped")
      t.eq(nil, S.runtime.creating)
      controller.hide()
    end)

    t.it("drops the buffer when creation fails", function()
      -- Auth is exercised separately; disabling it here keeps the plain
      -- failure path (and keeps the suite from starting a login terminal).
      local S = setup({ ACP_MOCK_AUTH_REQUIRED = "1", ACP_MOCK_AUTH_MARKER = "/tmp/opencode/never-created" }, {
        capabilities = { auth_terminal = false },
      })
      vim.wait(8000, function()
        return S.runtime.creating == nil
      end, 20)
      vim.fn.delete("/tmp/opencode/never-created")
      local session, changed, buffered = S.runtime:apply("sess_unknown", {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "x" },
      })
      t.eq(nil, session)
      t.eq(false, changed)
      t.eq(false, buffered)
      controller.hide()
    end)

    t.it("bounds the buffered updates", function()
      local runtime = Runtime.new(config.defaults.memory, {}, config.defaults.ui.thoughts)
      local token = runtime:expect_create()
      for i = 1, 400 do
        runtime:apply("sess_future", {
          sessionUpdate = "notice",
          title = "n" .. i,
          description = string.rep("x", 16),
        })
      end
      t.truthy(#runtime.creating.updates <= 256)
      t.truthy(runtime.creating.dropped > 0)
      local session = runtime:commit_create(token, "sess_future", "/tmp", {})
      t.truthy(session)
      t.eq(nil, runtime.creating)
      t.truthy(#session.blocks > 0)
      -- The newest notice survived the trim.
      local last = session.blocks[#session.blocks]
      t.eq("n400", last.title)
    end)
  end)
end
