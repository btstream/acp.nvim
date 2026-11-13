-- Regression tests for the performance and robustness optimisations.
return function(t)
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")
  local blocks = require("acp.ui.blocks")
  local icons = require("acp.ui.icons")
  local toolbar = require("acp.ui.toolbar")
  local framing = require("acp.transport.framing")
  local jsonrpc = require("acp.transport.jsonrpc")
  local config = require("acp.config")
  local log = require("acp.log")

  t.describe("streaming text buffer", function()
    t.it("joins chunks transparently through block.text", function()
      local s = state.new("s", "/tmp")
      s:append_text("agent", "Hel")
      s:append_text("agent", "lo")
      s:append_text("agent", " world")
      t.eq("Hello world", s.blocks[1].text)
    end)

    t.it("honours an explicit assignment after streaming", function()
      local s = state.new("s", "/tmp")
      local block = s:append_text("agent", "old")
      s:append_text("agent", " text")
      block.text = "replaced"
      t.eq("replaced", block.text)
      s:append_text("agent", "!")
      t.eq("replaced!", block.text)
    end)

    t.it("keeps a single chunk intact", function()
      local s = state.new("s", "/tmp")
      s:append_text("agent", "only")
      t.eq("only", s.blocks[1].text)
    end)
  end)

  t.describe("streaming markdown rendering", function()
    t.it("matches a full re-render while text grows", function()
      local full = "line one\nline two\n`code` here\nline four"
      local cache = {}
      local expected = blocks.render_text(full, "AcpX", 80)
      for i = 1, #full do
        local got = blocks.render_text(full:sub(1, i), "AcpX", 80, cache)
        local ref = blocks.render_text(full:sub(1, i), "AcpX", 80)
        t.eq(vim.inspect(ref), vim.inspect(got), "mismatch at byte " .. i)
      end
      local final = blocks.render_text(full, "AcpX", 80, cache)
      t.eq(vim.inspect(expected), vim.inspect(final))
    end)

    t.it("never mutates cached lines through indentation", function()
      local lines = blocks.render_text("a\nb", "AcpX", 80)
      local indented = blocks.indent_lines(lines, "  ")
      t.eq("a", lines[1].text, "source line was mutated")
      t.eq("  a", indented[1].text)
      t.eq(2, indented[1].segments[1].s)
    end)
  end)

  t.describe("transcript cache invalidation", function()
    t.it("re-renders a plan when only entry content changes", function()
      local s = state.new("s", "/tmp")
      reducer.apply(s, { sessionUpdate = "plan", entries = { { content = "one", status = "pending" } } })
      local chat = require("acp.ui.chat").new({ config = config.validate(config.merge(config.defaults, {})) })
      chat:set_session(s)
      local first = table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n")
      reducer.apply(s, { sessionUpdate = "plan", entries = { { content = "two", status = "pending" } } })
      chat:render()
      local second = table.concat(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), "\n")
      t.truthy(first:find("one"), "first render missed the entry")
      t.truthy(second:find("two"), "plan entry change was not re-rendered")
    end)
  end)

  t.describe("block trimming", function()
    t.it("drops the oldest blocks past the cap", function()
      local s = state.new("s", "/tmp")
      for i = 1, 2500 do
        s:append({ id = "b" .. i, kind = "agent", text = "x" })
      end
      t.truthy(#s.blocks <= 2000, "transcript grew past the cap: " .. #s.blocks)
      t.eq("b2500", s.blocks[#s.blocks].id)
    end)

    t.it("forgets tool mappings for trimmed blocks", function()
      local s = state.new("s", "/tmp")
      local tool = s:append({ id = "tool:old", kind = "tool" })
      s.tools["old"] = tool
      for i = 1, 2100 do
        s:append({ id = "b" .. i, kind = "agent" })
      end
      t.falsy(s.tools["old"], "trimmed tool is still tracked")
    end)
  end)

  t.describe("icon set reuse", function()
    t.it("returns the same table across calls", function()
      t.truthy(icons.get(true) == icons.get(true))
      t.truthy(icons.get(false) == icons.get(false))
      t.falsy(icons.get(true) == icons.get(false))
    end)
  end)

  t.describe("toolbar truncation", function()
    t.it("keeps the display width within the budget", function()
      local cases = { "abcdefghij", "中文测试内容", "mixed 中文 text" }
      for _, case in ipairs(cases) do
        local out = toolbar.truncate(case, 5)
        t.truthy(vim.api.nvim_strwidth(out) <= 5, "overflow for " .. case .. ": " .. out)
      end
    end)

    t.it("leaves short strings untouched", function()
      t.eq("abc", toolbar.truncate("abc", 10))
      t.eq("", toolbar.truncate("abc", 0))
    end)
  end)

  t.describe("protocol framing", function()
    t.it("reassembles a message split across chunks", function()
      local decoder = framing.new_decoder(1024)
      local lines = {}
      for _, chunk in ipairs({ '{"a":', "1}", '\n{"b"', ":2}\n" }) do
        decoder:feed(chunk, function(line)
          lines[#lines + 1] = line
        end)
      end
      t.eq(2, #lines)
      t.eq('{"a":1}', lines[1])
      t.eq('{"b":2}', lines[2])
    end)

    t.it("fails once a message exceeds the cap", function()
      local decoder = framing.new_decoder(16)
      t.falsy(decoder:feed(string.rep("x", 32), function() end))
      t.falsy(decoder:feed("\n", function() end), "decoder stayed usable after failing")
    end)

    t.it("drops the buffer after a raising handler", function()
      local decoder = framing.new_decoder(1024)
      local seen = {}
      decoder:feed("a\nb\n", function(line)
        seen[#seen + 1] = line
        error("handler blew up")
      end)
      t.eq({ "a", "b" }, seen, "remaining lines were lost after the handler raised")
    end)
  end)

  t.describe("jsonrpc cancellation", function()
    t.it("removes cancelled requests from pending", function()
      local sent = {}
      local rpc = jsonrpc.new({
        send = function(payload)
          sent[#sent + 1] = payload
          return true
        end,
      })
      local id = rpc:request("x", {}, function() end)
      t.eq(1, rpc:pending_count())
      rpc:cancel(id)
      t.eq(0, rpc:pending_count(), "cancelled request still pending")
    end)

    t.it("ignores a late response for a cancelled request", function()
      local rpc = jsonrpc.new({
        send = function()
          return true
        end,
      })
      local calls = 0
      local id = rpc:request("x", {}, function()
        calls = calls + 1
      end)
      rpc:cancel(id)
      rpc:handle({ jsonrpc = "2.0", id = id, result = {} })
      t.eq(0, calls)
    end)

    t.it("still resolves pending requests on close", function()
      local rpc = jsonrpc.new({
        send = function()
          return true
        end,
      })
      local saw_error = false
      rpc:request("x", {}, function(ok)
        saw_error = not ok
      end)
      rpc:close("bye")
      t.truthy(saw_error, "pending request was not rejected on close")
      t.eq(0, rpc:pending_count())
    end)
  end)

  t.describe("config validation", function()
    t.it("rejects NaN", function()
      local merged = config.merge(config.defaults, { layout = { width = 0 / 0 } })
      t.raises(function()
        config.validate(merged)
      end, "NaN")
    end)

    t.it("rejects a bad transport limit", function()
      local merged = config.merge(config.defaults, { transport = { max_line_bytes = 10 } })
      t.raises(function()
        config.validate(merged)
      end, "max_line_bytes")
    end)

    t.it("does not share structure with the defaults", function()
      local merged = config.merge(config.defaults, {})
      merged.agents.opencode.args[1] = "mutated"
      t.eq({ "acp" }, config.defaults.agents.opencode.args)
    end)

    t.it("does not alias the user's tables", function()
      local mine = { agents = { opencode = { command = "x", args = { "y" } } } }
      local merged = config.merge(config.defaults, mine)
      merged.agents.opencode.args[1] = "changed"
      t.eq({ "y" }, mine.agents.opencode.args)
    end)
  end)

  t.describe("log redaction", function()
    t.it("scans bare assignments and CLI flags", function()
      t.falsy(log.redact("api_key=abc"):find("abc", 1, true), "api_key value leaked")
      t.falsy(log.redact("-token abc"):find("abc", 1, true), "short flag value leaked")
      t.falsy(log.redact("--api-key abc"):find("abc", 1, true), "--api-key value leaked")
      t.falsy(log.redact('{"apiKey":"abc"}'):find("abc", 1, true), "JSON apiKey leaked")
    end)

    t.it("leaves ordinary text alone", function()
      t.eq("nothing secret here", log.redact("nothing secret here"))
    end)
  end)

  t.describe("incremental transcript rendering", function()
    -- The renderer writes only the changed range of the buffer. It must stay
    -- byte-identical to a full re-render no matter which block changed.
    local cfg = config.validate(config.merge(config.defaults, {}))
    local Chat = require("acp.ui.chat")

    local function full_render(s)
      local ref = Chat.new({ config = cfg })
      ref:set_session(s)
      return vim.api.nvim_buf_get_lines(ref.buf, 0, -1, false)
    end

    t.it("matches a full render through appends, rewrites and removals", function()
      local s = state.new("s", "/tmp")
      local chat = Chat.new({ config = cfg })
      chat:set_session(s)

      local steps = {
        function()
          s:append({ id = "a", kind = "user", text = "first" })
        end,
        function()
          s:append({ id = "b", kind = "agent", text = "reply one" })
        end,
        function()
          s.blocks[2].text = "reply one extended considerably"
        end,
        function()
          s:append({ id = "c", kind = "agent", text = "second" })
        end,
        function()
          s.blocks[1].text = "first CHANGED"
        end,
        function()
          table.remove(s.blocks)
        end,
        function()
          s:append({ id = "d", kind = "agent", text = "after removal" })
        end,
        function()
          s.blocks[1].text = "first changed again, and much longer this time"
        end,
        function()
          table.remove(s.blocks, 2)
        end,
      }

      for i, step in ipairs(steps) do
        step()
        chat:render()
        local got = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
        t.eq(vim.inspect(full_render(s)), vim.inspect(got), "mismatch at step " .. i)
      end
    end)
  end)

  t.describe("stale prompt events", function()
    -- Regression: `send_now` settles a turn and immediately dispatches the next
    -- queued one. The `prompt_finished` event arrives later (it goes through
    -- `vim.schedule`), so without a turn check it marked the *new* turn idle.
    -- The next prompt then reached the agent while it still had one active and
    -- failed with "Session already has an active ACP prompt".
    local controller = require("acp.controller")

    t.it("ignores a prompt_finished event for an earlier turn", function()
      local s = state.new("s", "/tmp")
      local S = controller.state()
      local previous = S.config
      S.config = config.validate(config.merge(config.defaults, {}))
      S.sess.all[s.id] = s
      S.sess.current = s

      s:begin_turn() -- turn 1
      s:finish_turn("end_turn")
      local turn_of_next = s:begin_turn() -- turn 2, freshly started

      -- The event for turn 1 lands late.
      controller.on_client_event("prompt_finished", {
        session_id = s.id,
        ok = true,
        result = { stopReason = "end_turn" },
        turn = 1,
      })

      t.eq("running", s.status, "a stale event settled a running turn")
      t.eq(turn_of_next, s.turn)

      S.sess.all[s.id] = nil
      S.sess.current = nil
      S.config = previous
    end)

    t.it("still settles the event for the current turn", function()
      local s = state.new("s", "/tmp")
      local S = controller.state()
      local previous = S.config
      S.config = config.validate(config.merge(config.defaults, {}))
      S.sess.all[s.id] = s
      S.sess.current = s

      local turn = s:begin_turn()
      controller.on_client_event("prompt_finished", {
        session_id = s.id,
        ok = true,
        result = { stopReason = "end_turn" },
        turn = turn,
      })
      t.eq("idle", s.status)

      S.sess.all[s.id] = nil
      S.sess.current = nil
      S.config = previous
    end)
  end)

  t.describe("session switching", function()
    local cfg = config.validate(config.merge(config.defaults, {}))
    local Chat = require("acp.ui.chat")

    local function lines(chat)
      return vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
    end

    t.it("replaces the transcript instead of appending to the old one", function()
      local a = state.new("A", "/tmp")
      a:append({ id = "a1", kind = "user", text = "OLD SESSION" })
      local b = state.new("B", "/tmp")
      b:append({ id = "b1", kind = "agent", text = "NEW SESSION" })

      local chat = Chat.new({ config = cfg })
      chat:set_session(a)
      t.truthy(table.concat(lines(chat), "\n"):find("OLD SESSION", 1, true))

      chat:set_session(b)
      local text = table.concat(lines(chat), "\n")
      t.truthy(text:find("NEW SESSION", 1, true), "new session content missing")
      t.falsy(text:find("OLD SESSION", 1, true), "previous session leaked into the transcript")
    end)

    t.it("survives switching back and forth", function()
      local a = state.new("A", "/tmp")
      a:append({ id = "a1", kind = "user", text = "AAA" })
      local b = state.new("B", "/tmp")
      b:append({ id = "b1", kind = "agent", text = "BBB" })
      local chat = Chat.new({ config = cfg })

      chat:set_session(a)
      chat:set_session(b)
      chat:set_session(a)
      local text = table.concat(lines(chat), "\n")
      t.truthy(text:find("AAA", 1, true))
      t.falsy(text:find("BBB", 1, true), "stale session content kept")

      chat:set_session(b)
      text = table.concat(lines(chat), "\n")
      t.truthy(text:find("BBB", 1, true))
      t.falsy(text:find("AAA", 1, true), "stale session content kept")
    end)

    t.it("clears the transcript for an empty session", function()
      local a = state.new("A", "/tmp")
      a:append({ id = "a1", kind = "user", text = "AAA" })
      local chat = Chat.new({ config = cfg })
      chat:set_session(a)
      chat:set_session(state.new("E", "/tmp"))
      local text = table.concat(lines(chat), "\n")
      t.truthy(text:find("Start a conversation", 1, true))
      t.falsy(text:find("AAA", 1, true), "stale content kept for an empty session")
    end)

    t.it("clears the transcript when the session is dropped", function()
      local a = state.new("A", "/tmp")
      a:append({ id = "a1", kind = "user", text = "AAA" })
      local chat = Chat.new({ config = cfg })
      chat:set_session(a)
      chat:set_session(nil)
      chat:render(true)
      local text = table.concat(lines(chat), "\n")
      t.falsy(text:find("AAA", 1, true), "transcript survived its session")
    end)
  end)

  t.describe("reducer idempotence", function()
    t.it("reports no change for an identical command list", function()
      local s = state.new("s", "/tmp")
      local update = { sessionUpdate = "available_commands_update", availableCommands = { { name = "x" } } }
      t.truthy(reducer.apply(s, update))
      t.falsy(reducer.apply(s, update), "identical update reported a change")
    end)

    t.it("reports no change for an empty agent chunk", function()
      local s = state.new("s", "/tmp")
      t.falsy(reducer.apply(s, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "" } }))
      t.eq(0, #s.blocks)
    end)

    t.it("drops a tool update without an id", function()
      local s = state.new("s", "/tmp")
      t.falsy(reducer.apply(s, { sessionUpdate = "tool_call_update", status = "completed" }))
      t.eq(0, #s.blocks, "a placeholder block was created")
    end)
  end)
end
