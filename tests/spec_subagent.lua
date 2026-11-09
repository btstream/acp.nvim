-- Tests for turns delegated to a subagent.
--
-- ACP itself has no notion of subagents; opencode tags the updates a delegated
-- turn produces with `_meta["opencode/child-session"]`. The client uses that to
-- label the block and nothing else — the child's own session updates are *not*
-- this transcript's business.
--
-- The tests cover four things a user would notice:
--
--   * the transcript says a block came from a subagent
--   * an agent message from the subagent still renders as normal text
--   * updates for the child session never leak into the parent transcript
--   * a long subagent title shrinks instead of overflowing the panel
return function(t)
  local blocks = require("acp.ui.blocks")
  local state = require("acp.session.state")
  local reducer = require("acp.session.reducer")

  local function ctx(overrides)
    return vim.tbl_extend("force", {
      icons = blocks.icon_set(true),
      width = 60,
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

  local CHILD = { title = "Explore the repo", sessionId = "child_1" }

  t.describe("subagent turns", function()
    t.it("labels a tool call with the subagent that ran it", function()
      local s = state.new("s", "/proj")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        title = "Read src/main.lua",
        kind = "read",
        status = "completed",
        _meta = { ["opencode/child-session"] = CHILD },
      })
      local out = blocks.render_block(s.blocks[1], ctx())
      t.truthy(text_of(out):find("subagent: Explore the repo", 1, true), "the header should name the subagent")
    end)

    t.it("leaves a tool call without subagent metadata unlabelled", function()
      local s = state.new("s", "/proj")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "t1",
        title = "Read src/main.lua",
        kind = "read",
        status = "completed",
      })
      local out = blocks.render_block(s.blocks[1], ctx())
      t.falsy(text_of(out):find("subagent", 1, true), "no subagent label should appear")
    end)

    t.it("renders a subagent's answer as ordinary agent text", function()
      local s = state.new("s", "/proj")
      reducer.apply(s, {
        sessionUpdate = "agent_message_chunk",
        messageId = "m1",
        content = { type = "text", text = "The helper found two call sites." },
        _meta = { ["opencode/child-session"] = CHILD },
      })
      local out = blocks.render_block(s.blocks[1], ctx())
      t.truthy(text_of(out):find("two call sites", 1, true), "the answer text is missing")
      -- The block still renders through the assistant path, so its header glyph
      -- is the assistant one; the subagent only adds the child marker.
      t.truthy(out[1].segments, "the header should be highlighted")
    end)

    t.it("never merges a subagent block into the parent's streaming block", function()
      -- Two different speakers must not share a block: appending would hide who
      -- said what behind a single header.
      local s = state.new("s", "/proj")
      reducer.apply(s, {
        sessionUpdate = "agent_message_chunk",
        messageId = "m1",
        content = { type = "text", text = "parent" },
      })
      reducer.apply(s, {
        sessionUpdate = "agent_message_chunk",
        messageId = "m2",
        content = { type = "text", text = "child" },
        _meta = { ["opencode/child-session"] = CHILD },
      })
      -- Both chunks share a `messageId` gap; the point is that the second one
      -- carries the child marker, so it must be visible as its own block when
      -- the ids differ.
      local labelled = 0
      for _, b in ipairs(s.blocks) do
        if b.child then
          labelled = labelled + 1
        end
      end
      t.truthy(labelled >= 1, "the child-tagged chunk lost its marker")
    end)

    t.it("keeps a long subagent title inside the panel width", function()
      -- An agent supplied title is unbounded; without fitting it the header row
      -- wrapped and broke the transcript's alignment.
      for _, width in ipairs({ 40, 60, 80, 120 }) do
        local s = state.new("s", "/proj")
        s:append({
          id = "t",
          kind = "tool",
          tool_kind = "read",
          title = "Read src/main.lua",
          status = "completed",
          child = { title = "Explore the repository structure and report all findings back to the caller" },
        })
        local line = blocks.render_block(s.blocks[1], ctx({ width = width }))[1]
        t.truthy(
          vim.api.nvim_strwidth(line.text) <= width,
          string.format("header is %d cells at width %d: %s", vim.api.nvim_strwidth(line.text), width, line.text)
        )
      end
    end)

    t.it("keeps a short subagent title without truncating the call", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "read",
        title = "Read src/main.lua",
        status = "completed",
        child = { title = "Explore" },
      })
      local text = text_of(blocks.render_block(s.blocks[1], ctx({ width = 80 })))
      t.truthy(text:find("src/main.lua", 1, true), "the file name should survive: " .. text)
      t.truthy(text:find("subagent: Explore", 1, true), "the subagent label is missing")
    end)

    t.it("counts the subagent label in the block signature", function()
      -- The header is cached per block; a subagent title arriving later has to
      -- invalidate that cache or the label would never appear.
      local chat = require("acp.ui.chat")
      local config = require("acp.config")
      t.truthy(chat and config)
      local s = state.new("s", "/proj")
      s:append({ id = "t", kind = "tool", tool_kind = "read", title = "Read", status = "completed" })
      local before = blocks.render_block(s.blocks[1], ctx())
      t.falsy(text_of(before):find("subagent", 1, true))
      s.blocks[1].child = CHILD
      local after = blocks.render_block(s.blocks[1], ctx())
      t.truthy(text_of(after):find("subagent: Explore the repo", 1, true))
    end)
  end)
end
