return function(t)
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")
  local agents = require("acp.agents")
  local blocks = require("acp.ui.blocks")

  local function ctx(overrides)
    return vim.tbl_extend("force", {
      icons = blocks.icon_set(true),
      width = 80,
      cwd = "/proj",
      show_thoughts = false,
    }, overrides or {})
  end

  local function text_of(lines)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = line.text
    end
    return table.concat(out, "\n")
  end

  local function tool_session(profile)
    local s = state.new("s", "/proj")
    if profile then
      s.profile = agents.get({ profile = profile })
    end
    return s
  end

  t.describe("terminal output metadata", function()
    t.it("accumulates terminal_output and terminal_exit from _meta", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "bash_1",
        title = "ls",
        kind = "execute",
        content = { { type = "terminal", terminalId = "bash_1" } },
        _meta = { terminal_info = { terminal_id = "bash_1", cwd = "/proj" } },
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "bash_1",
        _meta = { terminal_output = { terminal_id = "bash_1", data = "a.ts\nb.ts\n" } },
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "bash_1",
        status = "completed",
        _meta = { terminal_exit = { terminal_id = "bash_1", exit_code = 0 } },
      })
      local block = s.tools.bash_1
      t.eq("a.ts\nb.ts\n", block.terminal_output)
      t.eq(0, block.terminal_exit)
      t.eq("/proj", block.terminal_cwd)
      block.expanded = true
      local rendered = text_of(blocks.render_block(block, ctx()))
      t.match("a%.ts", rendered)
      t.match("exited with 0", rendered)
    end)

    t.it("appends deltas instead of replacing the buffer", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "ls",
        status = "in_progress",
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "t1",
        _meta = { terminal_output_delta = { terminal_id = "t1", data = "one\n" } },
      })
      reducer.apply(s, {
        sessionUpdate = "tool_call_update",
        toolCallId = "t1",
        _meta = { terminal_output_delta = { terminal_id = "t1", data = "two\n" } },
      })
      t.eq("one\ntwo\n", s.tools.t1.terminal_output)
    end)

    t.it("shows a non-zero exit code as an error", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "false",
        status = "completed",
        _meta = { terminal_exit = { terminal_id = "t1", exit_code = 2 } },
      })
      local block = s.tools.t1
      block.expanded = true
      local lines = blocks.render_block(block, ctx())
      local found
      for _, line in ipairs(lines) do
        if line.text:find("exited with 2", 1, true) then
          found = line
        end
      end
      t.truthy(found)
      local group
      for _, seg in ipairs(found.segments or {}) do
        if seg.group then
          group = seg.group
        end
      end
      t.eq("AcpToolError", group)
    end)

    t.it("does not print a bare terminal id", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "ls",
        status = "completed",
        content = { { type = "terminal", terminalId = "t1" } },
      })
      -- nil, not "": the card uses nil to mean "nothing renderable here".
      t.eq(nil, s.tools.t1.detail)
    end)

    t.it("hints at hidden output on a collapsed card", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "ls",
        status = "completed",
        _meta = { terminal_output = { terminal_id = "t1", data = "a.ts\nb.ts" } },
      })
      local header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.match("2 lines", header)
      t.falsy(s.tools.t1.expanded, "an execute card must not auto-expand")
      -- Expanding replaces the count with the output itself.
      s.tools.t1.expanded = true
      local expanded_header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.falsy(expanded_header:find("2 lines", 1, true), "the hint survived expansion")
    end)

    t.it("singularises a one-line hint", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "pwd",
        status = "completed",
        _meta = { terminal_output = { terminal_id = "t1", data = "/proj" } },
      })
      local header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.match("1 line", header)
      t.falsy(header:find("1 lines", 1, true))
    end)

    t.it("adds the exit code for a collapsed failure", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "false",
        status = "failed",
        _meta = {
          terminal_output = { terminal_id = "t1", data = "boom" },
          terminal_exit = { terminal_id = "t1", exit_code = 2 },
        },
      })
      local header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.match("exit 2", header)
    end)

    t.it("keeps the hint inside a narrow panel", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "grep -rn something --include=*.lua .",
        status = "completed",
        _meta = { terminal_output = { terminal_id = "t1", data = "x\ny\nz" } },
      })
      for _, width in ipairs({ 80, 40, 22 }) do
        local header = blocks.render_block(s.tools.t1, ctx({ width = width }))[1].text
        t.truthy(vim.api.nvim_strwidth(header) <= width, string.format("header overflowed %d: %s", width, header))
      end
    end)

    t.it("adds no hint when the card has nothing to show", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Read a.lua",
        status = "completed",
      })
      local header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.falsy(header:find("line", 1, true), "a payload-less card claimed to hide lines")
    end)

    t.it("does not hint on a diff card the user collapsed", function()
      local s = tool_session("claude")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "edit",
        title = "Edit a.lua",
        status = "completed",
        content = { { type = "diff", path = "/proj/a.lua", oldText = "a\nb", newText = "a\nc" } },
      })
      -- A diff has no text summary, so `detail` is nil. It is still content:
      -- the card must auto-expand, and a hand-collapsed one must not claim to
      -- be hiding body lines it would not have shown differently.
      t.truthy(s.tools.t1.expanded, "a diff card stopped auto-expanding")
      local header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.falsy(header:find("line", 1, true), "a diff card grew a line hint")
    end)

    t.it("still auto-expands a diff and hides the hint", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "write",
        title = "Write a.lua",
        status = "completed",
        rawInput = { path = "a.lua", content = "local a = 1\n" },
      })
      t.truthy(s.tools.t1.expanded)
      local header = blocks.render_block(s.tools.t1, ctx())[1].text
      t.falsy(header:find("line", 1, true))
    end)

    t.it("falls back to rawOutput when the only content is a terminal", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Read",
        status = "completed",
        content = { { type = "terminal", terminalId = "x" } },
        rawOutput = "OUT",
      })
      local block = s.tools.t1
      block.expanded = true
      local rendered = text_of(blocks.render_block(block, ctx()))
      t.match("OUT", rendered)
    end)

    t.it("prefers terminal output over rawOutput", function()
      local s = tool_session("pi")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "execute",
        title = "ls",
        status = "completed",
        rawOutput = "RAW",
        _meta = { terminal_output = { terminal_id = "t1", data = "TERM" } },
      })
      local block = s.tools.t1
      block.expanded = true
      local rendered = text_of(blocks.render_block(block, ctx()))
      t.match("TERM", rendered)
      t.falsy(rendered:find("RAW", 1, true), "rawOutput duplicated the terminal output")
    end)
  end)

  t.describe("tool card details", function()
    t.it("shows rawOutput when there is no other content", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Read",
        status = "completed",
        rawOutput = "line one\nline two",
      })
      local block = s.tools.t1
      block.expanded = true
      local rendered = text_of(blocks.render_block(block, ctx()))
      t.match("line one", rendered)
    end)

    t.it("does not duplicate rawOutput when content already renders it", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Read",
        status = "completed",
        content = { { type = "content", content = { type = "text", text = "the text" } } },
        rawOutput = "the text",
      })
      local block = s.tools.t1
      block.expanded = true
      local rendered = text_of(blocks.render_block(block, ctx()))
      t.eq(1, select(2, rendered:gsub("the text", "")))
    end)

    t.it("renders resource and resource_link content", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Read",
        status = "completed",
        content = {
          { type = "resource", resource = { uri = "file:///a.lua", text = "one\ntwo" } },
          { type = "resource_link", uri = "file:///b.lua", name = "b.lua" },
        },
      })
      local detail = s.tools.t1.detail or ""
      t.match("file:///a%.lua", detail)
      t.match("%[b%.lua%]", detail)
    end)

    t.it("does not render an empty pair of backticks for a resource without a uri", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Read",
        status = "completed",
        content = { { type = "resource", resource = { text = "hello" } } },
      })
      local detail = s.tools.t1.detail or ""
      t.falsy(detail:find("``", 1, true), "rendered empty backticks")
      t.match("%[resource%]", detail)
    end)

    t.it("strips backticks from a tool title", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "edit",
        title = "`src/a.lua`",
        status = "completed",
      })
      local rendered = text_of(blocks.render_block(s.tools.t1, ctx()))
      t.match("src/a%.lua", rendered)
      t.falsy(rendered:find("`", 1, true), "backticks survived in the header")
    end)

    t.it("reconstructs every hunk of a MultiEdit", function()
      local diff = require("acp.ui.diff")
      local s = tool_session("claude")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "edit",
        title = "MultiEdit",
        status = "completed",
        rawInput = {
          file_path = "/proj/a.lua",
          edits = {
            { oldString = "a", newString = "A" },
            { oldString = "b", newString = "B" },
          },
        },
      })
      local entries = diff.from_block(s.tools.t1)
      t.eq(2, #entries)
      t.eq("a", entries[1].oldText)
      t.eq("B", entries[2].newText)
      t.eq("/proj/a.lua", entries[1].path)
    end)

    t.it("renders audio content as a placeholder", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        kind = "read",
        title = "Listen",
        status = "completed",
        content = { { type = "content", content = { type = "audio" } } },
      })
      t.match("%[audio%]", s.tools.t1.detail or "")
      local ok = reducer.apply(s, {
        sessionUpdate = "agent_message_chunk",
        content = { type = "audio" },
      })
      t.truthy(ok)
      local agent_block = s.blocks[#s.blocks]
      t.match("%[audio%]", agent_block.text or "")
    end)
  end)

  t.describe("plans", function()
    t.it("reuses one plan block across interleaved messages", function()
      local s = tool_session()
      s:begin_turn()
      reducer.apply(s, { sessionUpdate = "plan", entries = { { content = "one", status = "pending" } } })
      reducer.apply(s, {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "working" },
      })
      reducer.apply(s, {
        sessionUpdate = "plan",
        entries = { { content = "one", status = "completed" }, { content = "two", status = "pending" } },
      })
      local plans = 0
      for _, block in ipairs(s.blocks) do
        if block.kind == "plan" then
          plans = plans + 1
        end
      end
      t.eq(1, plans, "the plan was appended again after an agent message")
      t.eq(2, #s.blocks[1].entries)
    end)

    t.it("starts a new plan in the next turn", function()
      local s = tool_session()
      s:begin_turn()
      reducer.apply(s, { sessionUpdate = "plan", entries = { { content = "first" } } })
      s:begin_turn()
      reducer.apply(s, { sessionUpdate = "plan", entries = { { content = "second" } } })
      local plans = 0
      for _, block in ipairs(s.blocks) do
        if block.kind == "plan" then
          plans = plans + 1
        end
      end
      t.eq(2, plans)
    end)

    t.it("shows a high priority entry", function()
      local s = tool_session()
      reducer.apply(s, {
        sessionUpdate = "plan",
        entries = { { content = "urgent", status = "pending", priority = "high" } },
      })
      local rendered = text_of(blocks.render_block(s.blocks[1], ctx()))
      t.match("%(high%)", rendered)
    end)

    t.it("starts a fresh plan after a replay is committed", function()
      local Runtime = require("acp.session.runtime")
      local runtime = Runtime.new(require("acp.config").defaults.memory, {}, nil)
      local staged = runtime:stage("s", "/proj")
      reducer.apply(staged, { sessionUpdate = "plan", entries = { { content = "replayed" } } })
      t.eq(0, staged.blocks[1].turn)
      runtime:commit(staged)
      -- A live plan must not be folded into the replayed one, even before a
      -- turn counter is bumped.
      reducer.apply(staged, { sessionUpdate = "plan", entries = { { content = "live" } } })
      local plans = 0
      for _, block in ipairs(staged.blocks) do
        if block.kind == "plan" then
          plans = plans + 1
        end
      end
      t.eq(2, plans)
    end)
  end)

  t.describe("stop reasons", function()
    t.it("explains the reasons that end a turn early", function()
      t.truthy(state.stop_reason_notice("max_tokens"))
      t.truthy(state.stop_reason_notice("max_turn_requests"))
      t.truthy(state.stop_reason_notice("refusal"))
      t.eq(nil, state.stop_reason_notice("end_turn"))
      t.eq(nil, state.stop_reason_notice("cancelled"))
      t.eq(nil, state.stop_reason_notice(nil))
    end)

    t.it("appends one notice per truncated turn", function()
      local s = tool_session()
      s:begin_turn()
      s:finish_turn("max_tokens")
      local notices = 0
      for _, block in ipairs(s.blocks) do
        if block.kind == "notice" then
          notices = notices + 1
        end
      end
      t.eq(1, notices)
      -- Settlement can close the same turn twice; the transcript must not grow.
      s:finish_turn("max_tokens")
      notices = 0
      for _, block in ipairs(s.blocks) do
        if block.kind == "notice" then
          notices = notices + 1
        end
      end
      t.eq(1, notices)
    end)

    t.it("does not repeat the notice when a late update lands between settlements", function()
      local s = tool_session()
      s:begin_turn()
      s:finish_turn("max_tokens")
      -- ACP allows final updates after session/cancel, so a block can arrive
      -- between the two finish_turn calls. Deduplicating by "last block" would
      -- then append a second notice for the same turn.
      reducer.apply(s, { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "late" } })
      s:finish_turn("max_tokens")
      local notices = 0
      for _, block in ipairs(s.blocks) do
        if block.kind == "notice" then
          notices = notices + 1
        end
      end
      t.eq(1, notices)
    end)

    t.it("shows a new notice for a later truncated turn", function()
      local s = tool_session()
      s:begin_turn()
      s:finish_turn("max_tokens")
      s:begin_turn()
      s:finish_turn("refusal")
      local notices = 0
      for _, block in ipairs(s.blocks) do
        if block.kind == "notice" then
          notices = notices + 1
        end
      end
      t.eq(2, notices)
    end)

    t.it("stays silent for a normal turn", function()
      local s = tool_session()
      s:begin_turn()
      s:finish_turn("end_turn")
      t.eq(0, #s.blocks)
    end)
  end)

  t.describe("misc presentation", function()
    t.it("keeps notice ids monotonic across trimming", function()
      local s = tool_session()
      -- Do not mutate `s.limits`: `state.new` falls back to the shared config
      -- default, and changing it would leak into every later test.
      reducer.apply(s, { sessionUpdate = "notice", description = "first" })
      local first = s.blocks[#s.blocks].id
      reducer.apply(s, { sessionUpdate = "notice", description = "second" })
      local second = s.blocks[#s.blocks].id
      t.truthy(first ~= second, "notice ids were reused")
    end)

    t.it("records the agent's updatedAt", function()
      local s = tool_session()
      reducer.apply(s, { sessionUpdate = "session_info_update", updatedAt = "2026-01-01T00:00:00Z" })
      t.eq("2026-01-01T00:00:00Z", s.updated_at)
    end)
  end)
end
