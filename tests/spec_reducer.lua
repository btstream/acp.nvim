return function(t)
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")

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
      s.config_options = {
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
      }
      local model, mode = reducer.toolbar_labels(s)
      t.eq("Two", model)
      t.eq("Code", mode)
    end)
  end)
end
