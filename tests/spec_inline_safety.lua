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

    t.it("refuses to read a binary file", function()
      local path = dir .. "/binary.dat"
      local fd = vim.uv.fs_open(path, "w", 420)
      vim.uv.fs_write(fd, "\0\1\2binary", 0)
      vim.uv.fs_close(fd)
      -- Garbled lines would be inserted into the buffer by the reload action.
      t.eq(nil, guard.read_lines(path))
    end)

    t.it("does not add a trailing blank line for a final newline", function()
      local path = dir .. "/eol.txt"
      vim.fn.writefile({ "a", "b" }, path)
      t.eq({ "a", "b" }, guard.read_lines(path))
    end)
  end)

  t.describe("inline source lock", function()
    local lock = require("acp.inline.lock")

    local function named_buf(name)
      local path = dir .. "/" .. name
      vim.fn.writefile({ "original" }, path)
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      return buf, path
    end

    t.it("blocks edits and disk writes until unlocked", function()
      local buf, path = named_buf("locked.txt")
      t.truthy(lock.lock(buf))
      t.falsy(vim.api.nvim_get_option_value("modifiable", { buf = buf }))
      t.falsy(pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { "edited" }))

      local notes = {}
      local notify = vim.notify
      vim.notify = function(message)
        notes[#notes + 1] = tostring(message)
      end
      vim.api.nvim_buf_call(buf, function()
        pcall(vim.cmd, "write")
      end)
      vim.notify = notify
      t.eq({ "original" }, vim.fn.readfile(path))
      t.match("locked until it finishes", table.concat(notes, "\n"))

      lock.unlock(buf)
      t.truthy(vim.api.nvim_get_option_value("modifiable", { buf = buf }))
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("write")
      end)
      t.eq({ "edited" }, vim.fn.readfile(path))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("restores a buffer that was already nomodifiable", function()
      local buf = named_buf("readonly.txt")
      vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
      t.truthy(lock.lock(buf))
      lock.unlock(buf)
      t.falsy(vim.api.nvim_get_option_value("modifiable", { buf = buf }))
      lock.unlock(buf) -- repeat is safe
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("tolerates a buffer wiped while locked", function()
      local buf = named_buf("wiped.txt")
      t.truthy(lock.lock(buf))
      vim.api.nvim_buf_delete(buf, { force = true })
      t.falsy(lock.locked(buf))
      t.truthy(pcall(lock.unlock, buf))
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

    t.it("never switches into plan mode", function()
      -- Only plan and an auto-approving mode exist: switching into plan would
      -- change what the agent is willing to do, so the guard must decline.
      local s = session_with_mode("claude", "bypassPermissions", {
        { value = "plan", name = "Plan" },
        { value = "bypassPermissions", name = "Bypass" },
      })
      local notified = {}
      local original = vim.notify
      vim.notify = function(message)
        notified[#notified + 1] = tostring(message)
      end
      local inv = { session = s, config = { inline = { guard_mode = "switch" } } }
      t.truthy(inline.guard_unsafe_mode(inv))
      vim.notify = original
      t.eq("bypassPermissions", s.controls.mode.current, "the guard entered plan mode")
      t.eq(nil, inv.previous_mode)
      t.match("no neutral mode", notified[#notified])
    end)

    t.it("prefers a neutral mode over a plan mode", function()
      local s = session_with_mode("claude", "auto", {
        { value = "plan", name = "Plan" },
        { value = "default", name = "Manual" },
        { value = "auto", name = "Auto" },
      })
      local original = vim.notify
      vim.notify = function() end
      local inv = { session = s, config = { inline = { guard_mode = "switch" } } }
      t.truthy(inline.guard_unsafe_mode(inv))
      vim.notify = original
      t.eq("default", s.controls.mode.current)
      t.eq("auto", inv.previous_mode)
    end)
  end)

  t.describe("inline transcript folding", function()
    local blocks = require("acp.ui.blocks")
    local ctx = {
      icons = blocks.icon_set(true),
      width = 80,
      cwd = "/proj",
      show_thoughts = false,
    }

    local function text_of(block)
      local out = {}
      for _, line in ipairs(blocks.render_block(block, ctx)) do
        out[#out + 1] = line.text
      end
      return table.concat(out, "\n")
    end

    t.it("shows the summary for a generated prompt", function()
      local s = state.new("s", "/proj")
      s:add_local_user("INLINE_BUFFER_EDIT: a very long instruction block", nil, {
        display_text = "inline: rename the function",
      })
      local rendered = text_of(s.blocks[1])
      t.match("inline: rename the function", rendered)
      t.falsy(rendered:find("INLINE_BUFFER_EDIT", 1, true), "the full prompt leaked into the collapsed view")
    end)

    t.it("shows the full prompt once expanded", function()
      local s = state.new("s", "/proj")
      local block = s:add_local_user("INLINE_BUFFER_EDIT: full text", nil, {
        display_text = "inline: summary",
      })
      block.expanded = true
      local rendered = text_of(block)
      t.match("INLINE_BUFFER_EDIT", rendered)
    end)

    t.it("leaves an ordinary user message alone", function()
      local s = state.new("s", "/proj")
      s:add_local_user("hello there", nil)
      local rendered = text_of(s.blocks[1])
      t.match("hello there", rendered)
    end)

    t.it("drops the summary when the agent replays the message", function()
      local s = state.new("s", "/proj")
      s:begin_turn()
      s:add_local_user("INLINE_BUFFER_EDIT: x", nil, { display_text = "inline: x" })
      -- The agent echoes the message back; that is the authoritative text.
      s:user_chunk("real user text", "m1")
      t.eq(nil, s.blocks[#s.blocks].display_text)
      t.match("real user text", text_of(s.blocks[#s.blocks]))
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
