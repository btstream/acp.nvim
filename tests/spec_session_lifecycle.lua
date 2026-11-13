return function(t)
  local acp = require("acp")
  local controller = require("acp.controller")

  local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
  local mock = root .. "tests/mock_agent.py"

  local function setup(profile, env)
    acp.setup({
      agent = profile,
      agents = {
        [profile] = {
          command = "python3",
          args = { mock },
          env = vim.tbl_extend("force", { ACP_MOCK_PROFILE = profile }, env or {}),
          profile = profile,
        },
      },
      permissions = { prompt = "native" },
    })
    controller.open()
    local S = controller.state()
    vim.wait(8000, function()
      return S.session ~= nil
    end, 20)
    return S
  end

  ---Read a log file written by the mock, trimmed into non-empty lines.
  local function lines(path)
    local out = {}
    local handle = io.open(path, "r")
    if not handle then
      return out
    end
    for line in handle:lines() do
      if line ~= "" then
        out[#out + 1] = line
      end
    end
    handle:close()
    return out
  end

  local function tempname(tag)
    return string.format("/tmp/opencode/acp-%s-%d.log", tag, vim.uv.hrtime())
  end

  local function transcript(S)
    local parts = {}
    for _, block in ipairs(S.session and S.session.blocks or {}) do
      if block.text then
        parts[#parts + 1] = block.text
      end
    end
    return table.concat(parts, "\n")
  end

  t.describe("session resume fallback", function()
    t.it("resumes instead of creating when the agent cannot load history", function()
      local log = tempname("resume")
      local S = setup("resumeonly", { ACP_MOCK_LOG = log })
      local caps = require("acp.protocol.capabilities").agent(S.client)
      t.falsy(caps.loadSession, "the resume-only profile must not advertise loadSession")
      t.truthy(caps.sessionCapabilities and caps.sessionCapabilities.resume, "resume must be advertised")

      local original = S.session
      controller.load_session("sess_old")
      vim.wait(6000, function()
        return S.session and S.session.id == "sess_old"
      end, 20)

      t.truthy(S.session, "no session became active")
      t.eq("sess_old", S.session.id)
      t.truthy(S.session ~= original, "the previous session object was reused")

      -- Resume must not replay: the mock's load path sends "old question".
      local text = transcript(S)
      t.falsy(text:find("old question", 1, true), "history was replayed during resume")
      t.falsy(text:find("old answer", 1, true), "history was replayed during resume")

      -- The wire proves which method was used.
      local methods = {}
      for _, line in ipairs(lines(log)) do
        local method = line:match('"method"%s*:%s*"([^"]+)"')
        if method then
          methods[#methods + 1] = method
        end
      end
      local seen = {}
      for _, method in ipairs(methods) do
        seen[method] = true
      end
      t.truthy(seen["session/resume"], "session/resume was never sent")
      t.falsy(seen["session/load"], "session/load was sent to an agent that cannot load")
      controller.hide()
    end)

    t.it("starts a new session when the agent can neither load nor resume", function()
      local log = tempname("no-load")
      local S = setup("generic", { ACP_MOCK_LOG = log })
      local notifications = {}
      local original_notify = vim.notify
      vim.notify = function(message)
        notifications[#notifications + 1] = tostring(message)
      end
      controller.load_session("sess_old")
      vim.wait(4000, function()
        return table.concat(notifications, "\n"):find("cannot load sessions", 1, true) ~= nil
      end, 20)
      vim.notify = original_notify

      t.match("cannot load sessions", table.concat(notifications, "\n"))
      -- The mock names every session `sess_mock`, so the wire is the proof that
      -- neither load nor resume was attempted.
      local methods = {}
      for _, line in ipairs(lines(log)) do
        local method = line:match('"method"%s*:%s*"([^"]+)"')
        if method then
          methods[method] = true
        end
      end
      t.falsy(methods["session/load"], "session/load was sent to an agent without it")
      t.falsy(methods["session/resume"], "session/resume was sent to an agent without it")
      t.truthy(methods["session/new"], "no new session was created")
      controller.hide()
    end)
  end)

  t.describe("session close", function()
    t.it("closes the previous session when switching away", function()
      local log = tempname("close-switch")
      local S = setup("opencode", { ACP_MOCK_CLOSE_LOG = log })
      local first = S.session.id

      controller.load_session("sess_old")
      vim.wait(6000, function()
        return S.session and S.session.id == "sess_old"
      end, 20)

      -- The mock records closes in order; switching away must release `first`.
      local closed = lines(log)
      t.eq(1, #closed)
      t.eq(first, closed[1])
      controller.hide()
    end)

    t.it("closes a session before deleting it", function()
      local log = tempname("close-delete")
      local S = setup("opencode", { ACP_MOCK_CLOSE_LOG = log })
      t.truthy(S.session)

      local done
      local catalog = S.catalog
      local sessions_service = require("acp.app.sessions")
      t.truthy(catalog)
      t.truthy(sessions_service)

      -- Go through the service the controller uses, so the delete flow is the
      -- real one.
      local service = S.sessions_service
      service:delete("sess_old", function(ok)
        done = ok
      end)
      vim.wait(6000, function()
        return done ~= nil
      end, 20)

      t.eq(true, done)
      local closed = lines(log)
      t.truthy(#closed >= 1, "session/close was never sent")
      t.eq("sess_old", closed[1])
      controller.hide()
    end)

    t.it("does not close when the agent has no close capability", function()
      local log = tempname("close-none")
      local S = setup("pi", { ACP_MOCK_CLOSE_LOG = log })
      local service = S.sessions_service
      local done
      service:delete("sess_old", function(ok)
        done = ok
      end)
      vim.wait(6000, function()
        return done ~= nil
      end, 20)
      t.eq(true, done)
      t.eq(0, #lines(log), "session/close must not be sent to an agent without it")
      controller.hide()
    end)
    t.it("does not close a session that is still running", function()
      local log = tempname("close-running")
      local S = setup("opencode", { ACP_MOCK_CLOSE_LOG = log })
      controller.submit("slow", {})
      vim.wait(4000, function()
        return S.session and S.session.status == "running"
      end, 20)
      t.eq("running", S.session.status, "the turn never started")
      local running = S.session.id

      controller.load_session("sess_old")
      vim.wait(6000, function()
        return S.session and S.session.id == "sess_old"
      end, 20)

      t.eq(0, #lines(log), "switching away from a running session must not close it")
      -- The abandoned turn keeps running in the background.
      t.eq("running", S.runtime.sessions[running] and S.runtime.sessions[running].status)
      controller.hide()
    end)
  end)
end
