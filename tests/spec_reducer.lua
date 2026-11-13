return function(t)
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")
  local presenter = require("acp.ui.presenter")

  t.describe("reducer", function()
    t.it("streams agent chunks into one block", function()
      local s = state.new("s1", "/tmp")
      s:begin_turn()
      reducer.apply(s, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Hel" } })
      reducer.apply(s, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "lo" } })
      t.eq(1, #s.blocks)
      t.eq("Hello", s.blocks[1].text)
    end)

    t.it("starts a new block when the message id changes", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(
        s,
        { sessionUpdate = "agent_message_chunk", messageId = "a", content = { type = "text", text = "one" } }
      )
      reducer.apply(
        s,
        { sessionUpdate = "agent_message_chunk", messageId = "b", content = { type = "text", text = "two" } }
      )
      t.eq(2, #s.blocks)
    end)

    t.it("replaces the optimistic user message on replay", function()
      local s = state.new("s1", "/tmp")
      s:begin_turn()
      s:add_local_user("local")
      reducer.apply(
        s,
        { sessionUpdate = "user_message_chunk", messageId = "u1", content = { type = "text", text = "real" } }
      )
      t.eq(1, #s.blocks)
      t.eq("real", s.blocks[1].text)
      t.falsy(s.blocks[1].optimistic)
    end)

    t.it("updates a tool block in place", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        title = "Read file",
        kind = "read",
        status = "pending",
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        status = "completed",
        content = { { type = "content", content = { type = "text", text = "ok" } } },
      })
      t.eq(1, #s.blocks)
      t.eq("completed", s.blocks[1].status)
      t.eq("Read file", s.blocks[1].title)
      t.eq("ok", s.blocks[1].detail)
    end)

    t.it("creates a placeholder for unknown tool updates", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, { sessionUpdate = "tool_call_update", toolCallId = "zz", status = "in_progress" })
      t.eq(1, #s.blocks)
      t.eq("in_progress", s.blocks[1].status)
    end)

    t.it("drops a failed update without leaving a half-applied block", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        title = "Read file",
        kind = "read",
        status = "pending",
      })
      local before = {
        title = s.blocks[1].title,
        status = s.blocks[1].status,
        content = s.blocks[1].content,
        bytes = s.bytes,
        version = s.version,
      }
      -- A string content reaches ipairs() in the detail builder and throws
      -- after the title and status were already assigned.
      local applied = reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        title = "Changed",
        status = "completed",
        content = "not a list",
      })
      t.falsy(applied)
      t.eq(before.title, s.blocks[1].title)
      t.eq(before.status, s.blocks[1].status)
      t.eq(before.content, s.blocks[1].content)
      t.eq(before.bytes, s.bytes)
      t.eq(before.version, s.version)
      -- The session is still usable afterwards.
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        status = "completed",
        content = { { type = "content", content = { type = "text", text = "ok" } } },
      })
      t.eq("completed", s.blocks[1].status)
      t.eq("ok", s.blocks[1].detail)
    end)

    t.it("rolls back the side effects of a no-op update", function()
      local s = state.new("s1", "/tmp")
      s:begin_turn()
      reducer.apply(s, {
        sessionUpdate = "agent_thought_chunk",
        messageId = "m1",
        content = { type = "text", text = "thinking" },
      })
      local thought = s.blocks[1]
      t.eq("streaming", thought.status)
      -- A tool update without an id closes the thought first, then reports no
      -- change; the thought must stay open.
      t.falsy(reducer.apply(s, { sessionUpdate = "tool_call_update", status = "pending" }))
      t.eq("streaming", thought.status)
      t.eq(thought, s.active_thought)
    end)

    t.it("keeps diff content out of the summary text", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        title = "edit",
        kind = "edit",
        status = "in_progress",
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        status = "completed",
        content = {
          { type = "content", content = { type = "text", text = "Edited f.lua (1 replacement)" } },
          { type = "diff", path = "/tmp/f.lua", oldText = "a\n", newText = "b\n" },
        },
      })
      local block = s.blocks[1]
      t.eq("Edited f.lua (1 replacement)", block.detail)
      t.falsy(block.detail:find("diff:", 1, true), "the diff was flattened into a path line")
    end)

    t.it("still summarises a path-only diff", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        kind = "edit",
        status = "in_progress",
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        content = { { type = "diff", path = "/tmp/f.lua" } },
      })
      t.match("diff: /tmp/f%.lua", s.blocks[1].detail)
    end)

    t.it("opens a file edit card once it has content", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, { sessionUpdate = "tool_call", toolCallId = "c1", kind = "edit", status = "pending" })
      -- The first call carries no payload: an open card would be empty.
      t.falsy(s.blocks[1].expanded, "an empty card was opened")

      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        status = "in_progress",
        rawInput = { path = "/tmp/f.lua", oldString = "a", newString = "b" },
      })
      t.truthy(s.blocks[1].expanded, "the card did not open when the change arrived")
    end)

    t.it("leaves other tools collapsed", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        kind = "execute",
        status = "in_progress",
        rawInput = { command = "ls" },
      })
      t.falsy(s.blocks[1].expanded, "a shell call was opened")
    end)

    t.it("keeps a card closed after the user collapses it", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        kind = "edit",
        status = "in_progress",
        rawInput = { path = "/tmp/f.lua", oldString = "a", newString = "b" },
      })
      local block = s.blocks[1]
      t.truthy(block.expanded)
      s:toggle(block)
      t.falsy(block.expanded)
      t.truthy(block.toggled, "the manual toggle was not recorded")

      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "c1",
        status = "completed",
        rawInput = { path = "/tmp/f.lua", oldString = "a", newString = "c" },
      })
      t.falsy(block.expanded, "an update reopened a card the user closed")
    end)

    t.it("keeps history collapsed", function()
      local s = state.new("s1", "/tmp")
      s.historical = true
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "c1",
        kind = "edit",
        status = "completed",
        rawInput = { path = "/tmp/f.lua", oldString = "a", newString = "b" },
      })
      t.falsy(s.blocks[1].expanded, "a replayed session opened its cards")
    end)

    t.it("opens new diffs after a history replay is committed", function()
      local Runtime = require("acp.session.runtime")
      local runtime = Runtime.new(state.new("box", "/tmp").limits, {})
      local staged = runtime:stage("s1", "/tmp")
      reducer.apply(staged, {
        sessionUpdate = "tool_call",
        toolCallId = "old",
        kind = "edit",
        status = "completed",
        rawInput = { path = "/tmp/old.lua", oldString = "a", newString = "b" },
      })
      t.falsy(staged.blocks[1].expanded)
      t.truthy(runtime:commit(staged))
      t.falsy(staged.historical)
      reducer.apply(staged, {
        sessionUpdate = "tool_call",
        toolCallId = "new",
        kind = "edit",
        status = "completed",
        rawInput = { path = "/tmp/new.lua", oldString = "c", newString = "d" },
      })
      t.falsy(staged.blocks[1].expanded, "the replayed card must stay closed")
      t.truthy(staged.blocks[2].expanded, "a live diff must open")
    end)

    t.it("records plans, usage and config options", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, { sessionUpdate = "plan", entries = { { content = "a", status = "pending" } } })
      reducer.apply(s, { sessionUpdate = "usage_update", used = 10, size = 100 })
      reducer.apply(s, { sessionUpdate = "config_option_update", configOptions = { { id = "model" } } })
      t.eq(1, #s.blocks)
      t.eq(10, s.usage.used)
      t.eq(1, #s.config_options)
    end)

    t.it("handles compaction markers and summaries", function()
      local s = state.new("s1", "/tmp")
      reducer.apply(s, { sessionUpdate = "compaction_update", compactionId = "c1", status = "in_progress" })
      reducer.apply(
        s,
        { sessionUpdate = "compaction_summary_chunk", compactionId = "c1", content = { type = "text", text = "sum" } }
      )
      reducer.apply(s, { sessionUpdate = "compaction_update", compactionId = "c1", status = "completed" })
      t.eq(1, #s.blocks)
      t.eq("completed", s.blocks[1].status)
      t.eq("sum", s.blocks[1].text)
    end)

    t.it("marks streaming blocks as finished", function()
      local s = state.new("s1", "/tmp")
      s:begin_turn()
      reducer.apply(s, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "x" } })
      s:finish_turn("end_turn")
      t.falsy(s.blocks[1].status)
      t.eq("idle", s.status)
    end)

    t.it("marks active tools cancelled on cancel", function()
      local s = state.new("s1", "/tmp")
      s:begin_turn()
      reducer.apply(s, { sessionUpdate = "tool_call", toolCallId = "c", title = "t", status = "in_progress" })
      s:finish_turn("cancelled")
      t.eq("cancelled", s.blocks[1].status)
    end)

    t.it("resolves toolbar labels from config options", function()
      local s = state.new("s1", "/tmp")
      s:configure({
        configOptions = {
          {
            id = "model",
            category = "model",
            type = "select",
            currentValue = "m2",
            options = { { value = "m1", name = "One" }, { value = "m2", name = "Two" } },
          },
          {
            id = "mode",
            category = "mode",
            type = "select",
            currentValue = "code",
            options = { { value = "code", name = "Code" } },
          },
        },
      })
      local model, mode = presenter.toolbar_labels(s)
      t.eq("Two", model)
      t.eq("Code", mode)
    end)

    t.it("drops the provider prefix from the toolbar model", function()
      local s = state.new("s", "/tmp")
      s:configure({
        configOptions = {
          {
            id = "model",
            category = "model",
            type = "select",
            currentValue = "commandcode/deepseek-v4.1-flash",
            options = {
              { value = "commandcode/deepseek-v4.1-flash", name = "commandcode/DeepSeek V4.1 Flash" },
            },
          },
        },
      })
      local model = presenter.toolbar_labels(s)
      t.eq("DeepSeek V4.1 Flash", model)
    end)

    t.it("keeps a name that has no provider prefix", function()
      local s = state.new("s", "/tmp")
      s:configure({
        configOptions = {
          {
            id = "model",
            category = "model",
            type = "select",
            currentValue = "openai/gpt-5",
            options = { { value = "openai/gpt-5", name = "GPT-5" } },
          },
        },
      })
      local model = presenter.toolbar_labels(s)
      t.eq("GPT-5", model)
    end)

    t.it("shortens only the first provider segment", function()
      t.eq("b/c", presenter.short_model_name("a/b/c"))
      t.eq("DeepSeek V4.1 Flash", presenter.short_model_name("commandcode/DeepSeek V4.1 Flash"))
      t.eq("GPT-5", presenter.short_model_name("GPT-5"))
      t.eq(nil, presenter.short_model_name(nil))
      t.eq("", presenter.short_model_name(""))
    end)
  end)
end
