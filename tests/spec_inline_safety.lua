return function(t)
  local guard = require("acp.inline.guard")
  local state = require("acp.session.state")
  local agents = require("acp.agents")

  local dir = "/tmp/opencode/acp-inline-guard"
  vim.fn.mkdir(dir, "p")

  local function write(name, text)
    local path = dir .. "/" .. name
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
    return path
  end

  t.describe("inline disk guard", function()
    t.it("reports no change when the file is untouched", function()
      local path = write("untouched.txt", "a\nb")
      local snap = guard.capture(path)
      t.truthy(snap)
      local changed = guard.changed(snap)
      t.falsy(changed)
    end)

    t.it("detects a direct write by the agent", function()
      local path = write("direct.txt", "original")
      local snap = guard.capture(path)
      vim.fn.writefile({ "REWRITTEN" }, path)
      local changed, reason = guard.changed(snap)
      t.truthy(changed)
      t.match("changed", reason)
    end)

    t.it("detects a same-second rewrite by content", function()
      local path = write("samesec.txt", "original")
      local snap = guard.capture(path)
      -- Same size, likely same mtime second: the hash is what catches it.
      vim.fn.writefile({ "ORIGINAL" }, path)
      t.truthy(guard.changed(snap))
    end)

    t.it("detects a file the agent created behind our back", function()
      local path = dir .. "/created-later.txt"
      vim.fn.delete(path)
      local snap = guard.capture(path)
      t.truthy(snap)
      vim.fn.writefile({ "made by the agent" }, path)
      t.truthy(guard.changed(snap))
    end)

    t.it("tolerates a missing snapshot", function()
      local changed = guard.changed(nil)
      t.falsy(changed)
    end)

    t.it("reads the file back for the diff action", function()
      local path = write("readable.txt", "one\ntwo")
      t.eq({ "one", "two" }, guard.read_lines(path))
      t.eq(nil, guard.read_lines(dir .. "/nope.txt"))
    end)
  end)

  t.describe("inline mode guard", function()
    local inline = require("acp.inline")

    local function session_with_mode(profile_name, mode, options)
      local s = state.new("s", "/tmp")
      s.profile = agents.get({ profile = profile_name })
      s:configure({
        configOptions = {
          {
            id = "mode",
            category = "mode",
            type = "select",
            currentValue = mode,
            options = options,
          },
        },
      })
      return s
    end

    t.it("recognises an auto-approving mode", function()
      local s = session_with_mode("claude", "acceptEdits", {
        { value = "default", name = "Manual" },
        { value = "acceptEdits", name = "Accept edits" },
      })
      local unsafe, id = inline.unsafe_mode(s)
      t.truthy(unsafe)
      t.eq("acceptEdits", id)
    end)

    t.it("treats a safe mode as safe", function()
      local s = session_with_mode("claude", "default", {
        { value = "default", name = "Manual" },
        { value = "acceptEdits", name = "Accept edits" },
      })
      t.falsy((inline.unsafe_mode(s)))
    end)

    t.it("says nothing when the guard is off", function()
      local s = session_with_mode("claude", "bypassPermissions", {
        { value = "bypassPermissions", name = "Bypass" },
      })
      local notified = {}
      local original = vim.notify
      vim.notify = function(message)
        notified[#notified + 1] = tostring(message)
      end
      local inv = { session = s, config = { inline = { guard_mode = "off" } } }
      t.truthy(inline.guard_unsafe_mode(inv))
      vim.notify = original
      t.eq(0, #notified)
    end)

    t.it("warns once in ask mode", function()
      local s = session_with_mode("claude", "acceptEdits", {
        { value = "default", name = "Manual" },
        { value = "acceptEdits", name = "Accept edits" },
      })
      local notified = {}
      local original = vim.notify
      vim.notify = function(message)
        notified[#notified + 1] = tostring(message)
      end
      local inv = { session = s, config = { inline = { guard_mode = "ask" } } }
      t.truthy(inline.guard_unsafe_mode(inv))
      vim.notify = original
      t.eq(1, #notified)
      t.match("without asking", notified[1])
      -- The mode is not changed.
      t.eq("acceptEdits", s.controls.mode.current)
    end)

    t.it("switches to a safe mode and restores it in switch mode", function()
      local s = session_with_mode("claude", "bypassPermissions", {
        { value = "default", name = "Manual" },
        { value = "bypassPermissions", name = "Bypass" },
      })
      local calls = {}
      local client = {
        set_mode = function(_, session_id, mode_id)
          calls[#calls + 1] = mode_id
          return true, {}
        end,
      }
      local original = vim.notify
      vim.notify = function() end
      local inv = {
        session = s,
        client = client,
        config = { inline = { guard_mode = "switch" } },
      }
      t.truthy(inline.guard_unsafe_mode(inv))
      vim.notify = original
      -- `previous_mode` is what to restore: the unsafe mode we switched away from.
      t.eq("bypassPermissions", inv.previous_mode)
      t.eq("default", s.controls.mode.current)
    end)

    t.it("does not guard an agent without a mode control", function()
      local s = state.new("s", "/tmp")
      s.profile = agents.get({}, "generic")
      t.falsy((inline.unsafe_mode(s)))
      local original = vim.notify
      vim.notify = function() end
      local inv = { session = s, config = { inline = { guard_mode = "ask" } } }
      t.truthy(inline.guard_unsafe_mode(inv))
      vim.notify = original
    end)
  end)

  t.describe("inline tool kinds", function()
    local inline = require("acp.inline")
    local permissions = require("acp.app.permissions")

    local function decide_allows(kind, inline_config)
      local s = state.new("s", "/tmp")
      s.profile = agents.get({}, "claude")
      local inv = {
        session = s,
        config = { inline = inline_config },
        copy = "/tmp/opencode/acp-inline-guard/copy.txt",
      }
      -- `decide` is private; the policy is the public path.
      local interaction = {
        type = "permission",
        session_id = s.id,
        request = {
          toolCall = { kind = kind, locations = { { path = "/proj/other.txt" } } },
          options = {
            { optionId = "allow", kind = "allow_once" },
            { optionId = "reject", kind = "reject_once" },
          },
        },
      }
      return inline._decide_for_test(inv, interaction.request)
    end

    t.it("covers only execute with allow_commands", function()
      t.eq("allow", decide_allows("execute", { allow_commands = true }))
      -- A refused kind still gets an explicit reject, not silence.
      t.eq("reject", decide_allows("delete", { allow_commands = true }))
      t.eq("reject", decide_allows("move", { allow_commands = true }))
      t.eq("reject", decide_allows("something_new", { allow_commands = true }))
      t.eq("reject", decide_allows("execute", { allow_commands = false }))
    end)

    t.it("opens other kinds through allow_kinds", function()
      t.eq("allow", decide_allows("delete", { allow_commands = false, allow_kinds = { "delete" } }))
      t.eq("allow", decide_allows("move", { allow_commands = false, allow_kinds = { "move" } }))
      t.eq("reject", decide_allows("something_new", { allow_commands = false, allow_kinds = { "delete" } }))
    end)

    t.it("leaves questions to the user", function()
      local question = {
        type = "permission",
        request = {
          toolCall = { kind = "other", rawInput = { method = "select" } },
          options = { { optionId = "a", kind = "allow_once" }, { optionId = "b", kind = "allow_once" } },
        },
      }
      t.truthy(permissions.question(question))
    end)
  end)
end
