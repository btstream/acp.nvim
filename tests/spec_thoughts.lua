-- Tests for collapsing agent reasoning (phase 4).
return function(t)
  local blocks = require("acp.ui.blocks")
  local state = require("acp.session.state")

  local function ctx(overrides)
    return vim.tbl_extend("force", {
      icons = blocks.icon_set(true),
      width = 60,
      cwd = "/proj",
      show_thoughts = false,
      thoughts = { default_expanded = false, show_collapsed_header = true },
    }, overrides or {})
  end

  local function thought(text, status)
    local s = state.new("s", "/proj")
    s:append({ id = "th", kind = "thought", text = text, status = status })
    return s.blocks[1]
  end

  local function text_of(lines)
    local out = {}
    for _, l in ipairs(lines) do
      out[#out + 1] = l.text
    end
    return table.concat(out, "\n")
  end

  t.describe("thought folding", function()
    t.it("shows a header and hides the body by default", function()
      local lines = blocks.render_block(thought("hidden reasoning"), ctx())
      t.match("Thought", lines[1].text)
      t.falsy(text_of(lines):find("hidden reasoning", 1, true), "body leaked while collapsed")
    end)

    t.it("marks the collapsed header with a right chevron", function()
      local ic = blocks.icon_set(true)
      local lines = blocks.render_block(thought("x"), ctx())
      t.truthy(lines[1].text:find(ic.chevron_right, 1, true), "collapsed header should point right")
    end)

    t.it("expands when the block was toggled", function()
      local block = thought("visible reasoning")
      block.expanded = true
      local lines = blocks.render_block(block, ctx())
      t.truthy(text_of(lines):find("visible reasoning", 1, true))
    end)

    t.it("uses a down chevron when expanded", function()
      local ic = blocks.icon_set(true)
      local block = thought("x")
      block.expanded = true
      local lines = blocks.render_block(block, ctx())
      t.truthy(lines[1].text:find(ic.chevron_down, 1, true), "expanded header should point down")
    end)

    t.it("honours default_expanded", function()
      local lines = blocks.render_block(
        thought("auto shown"),
        ctx({
          thoughts = { default_expanded = true, show_collapsed_header = true },
        })
      )
      t.truthy(text_of(lines):find("auto shown", 1, true), "default_expanded was ignored")
    end)

    t.it("lets an explicit toggle override the default", function()
      local block = thought("toggled off")
      block.expanded = false
      local lines = blocks.render_block(
        block,
        ctx({
          thoughts = { default_expanded = true, show_collapsed_header = true },
        })
      )
      t.falsy(text_of(lines):find("toggled off", 1, true), "toggle did not override default_expanded")
    end)

    t.it("hides everything when the header is disabled", function()
      local lines = blocks.render_block(
        thought("gone"),
        ctx({
          thoughts = { default_expanded = false, show_collapsed_header = false },
        })
      )
      t.eq(0, #lines)
    end)

    t.it("still expands with the header disabled once toggled", function()
      local block = thought("shown after toggle")
      block.expanded = true
      local lines = blocks.render_block(
        block,
        ctx({
          thoughts = { default_expanded = false, show_collapsed_header = false },
        })
      )
      t.truthy(text_of(lines):find("shown after toggle", 1, true))
    end)

    t.it("keeps the legacy show_thoughts switch working", function()
      local block = thought("legacy shown")
      local lines = blocks.render_block(block, ctx({ show_thoughts = true }))
      t.truthy(text_of(lines):find("legacy shown", 1, true))
      -- The legacy switch must not rewrite the block's own toggle.
      t.eq(nil, block.expanded, "show_thoughts should not mutate the block")
    end)

    t.it("puts expanded reasoning on the same surface as a tool card", function()
      local block = thought("visible reasoning")
      block.expanded = true
      local lines = blocks.render_block(block, ctx())
      local bg_lines = 0
      for _, line in ipairs(lines) do
        if line.bg then
          bg_lines = bg_lines + 1
          t.eq("AcpCardBg", line.bg, "thoughts and tool cards must share a surface")
        end
      end
      t.truthy(bg_lines >= 2, "expanded reasoning should have a padded surface")
    end)

    t.it("does not paint the collapsed header", function()
      local lines = blocks.render_block(thought("hidden"), ctx())
      t.eq(nil, lines[1].bg, "the collapsed header is not part of the surface")
    end)

    t.it("keeps the thought label background-free", function()
      local highlights = require("acp.ui.highlights")
      highlights.setup()

      -- A background here would paint a solid block behind the label, and the
      -- collapsed header deliberately sits directly on the transcript.
      local hl = vim.api.nvim_get_hl(0, { name = "AcpThought", link = false })
      t.truthy(hl.fg ~= nil, "AcpThought should resolve to a foreground")
      t.eq(nil, hl.bg, "AcpThought must not paint a background")

      local ic = blocks.icon_set(true)
      local lines = blocks.render_block(thought("x"), ctx())
      local header = lines[1]
      local caret_end = #ic.chevron_right
      t.eq("AcpSeparator", header.segments[1].group, "the caret must keep its own colour")
      t.eq(0, header.segments[1].s)
      t.eq(caret_end, header.segments[1].e)
      t.eq("AcpThought", header.segments[2].group, "icon and label take the thought colour")
      t.eq(caret_end + 1, header.segments[2].s)
    end)

    t.it("renders inline markup inside an expanded thought", function()
      local block = thought("uses `code` and **bold**")
      block.expanded = true
      local lines = blocks.render_block(block, ctx())
      local groups, concealed = {}, 0
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          if seg.conceal then
            concealed = concealed + 1
          elseif seg.group then
            groups[seg.group] = true
          end
        end
      end
      t.truthy(concealed > 0, "markup should be concealed inside a thought")
      t.truthy(groups["AcpMdCode"], "inline code missing inside a thought")
      t.truthy(groups["AcpBold"], "bold missing inside a thought")
    end)

    t.it("keeps every rendered row a single line", function()
      local block = thought("a\nb\nc")
      block.expanded = true
      for _, line in ipairs(blocks.render_block(block, ctx())) do
        t.falsy(line.text:find("\n"), "thought row contains a newline")
      end
    end)
  end)

  t.describe("streaming thoughts", function()
    t.it("finishes thoughts on updates to existing tools and plans", function()
      local reducer = require("acp.session.reducer")
      for _, kind in ipairs({ "tool", "plan" }) do
        local s = state.new("s", "/proj")
        s:begin_turn()
        reducer.apply(
          s,
          kind == "tool" and { sessionUpdate = "tool_call", toolCallId = "t" }
            or { sessionUpdate = "plan", entries = {} }
        )
        local block = s:append_text("thought", "reasoning", "m")
        reducer.apply(
          s,
          kind == "tool" and { sessionUpdate = "tool_call_update", toolCallId = "t", status = "completed" }
            or { sessionUpdate = "plan", entries = { { content = "next", status = "pending" } } }
        )
        t.eq(nil, block.status)
        t.eq(false, block.expanded)
        t.match("Thought", blocks.render_block(block, ctx())[1].text)
      end
    end)

    t.it("closes immediately on cancellation and keeps late thought chunks closed", function()
      local s = state.new("s", "/proj")
      s:begin_turn()
      local block = s:append_text("thought", "reasoning", "m")
      t.truthy(s:cancel_turn())
      t.eq(nil, block.status)
      t.eq(false, block.expanded)
      s:append_text("thought", " late", "m")
      t.eq(1, #s.blocks)
      t.eq("reasoning late", block.text)
      t.eq(nil, block.status)
      local second = s:append_text("thought", "another", "m2")
      t.eq(nil, second.status)
      t.eq(false, second.expanded)
    end)

    t.it("does not scan finished thought history on append", function()
      local s = state.new("s", "/proj")
      for i = 1, 200 do
        s:append({ id = "th" .. i, kind = "thought", text = "old" })
      end
      local original, calls = s.finish_thought, 0
      s.finish_thought = function(self, block)
        calls = calls + 1
        return original(self, block)
      end
      s:append({ id = "agent", kind = "agent", text = "answer" })
      t.eq(1, calls)
    end)

    t.it("shows the body live and labels it Thinking", function()
      local block = thought("live reasoning", "streaming")
      local lines = blocks.render_block(block, ctx())
      t.match("Thinking", lines[1].text)
      t.truthy(text_of(lines):find("live reasoning", 1, true), "live reasoning was hidden")
    end)

    t.it("collapses and relabels to Thought when finished", function()
      local s = state.new("s", "/proj")
      s:append_text("thought", "reasoning", "m")
      local block = s.blocks[1]
      t.truthy(block.expanded)
      s:finish_thought(block)
      t.eq(nil, block.status)
      t.eq(false, block.expanded)
      local lines = blocks.render_block(block, ctx())
      t.match("Thought", lines[1].text)
      t.falsy(text_of(lines):find("reasoning", 1, true))
    end)

    t.it("finishes the thought when agent text starts", function()
      local s = state.new("s", "/proj")
      s:append_text("thought", "reasoning", "m")
      local block = s.blocks[1]
      s:append_text("agent", "answer", "a")
      t.eq(nil, block.status)
      t.eq(false, block.expanded)
    end)

    t.it("finishes the thought when the message id changes", function()
      local s = state.new("s", "/proj")
      s:append_text("thought", "first", "m1")
      local first = s.blocks[1]
      local second = s:append_text("thought", "second", "m2")
      t.eq(nil, first.status)
      t.eq(false, first.expanded)
      t.truthy(second.expanded)
    end)

    t.it("finishes every thought at the end of a turn", function()
      local s = state.new("s", "/proj")
      s:begin_turn()
      s:append_text("thought", "reasoning", "m")
      local block = s.blocks[1]
      s:finish_turn("end_turn")
      t.eq(nil, block.status)
      t.eq(false, block.expanded)
    end)

    t.it("can stay collapsed while streaming when configured", function()
      local s = state.new("s", "/proj")
      s.thoughts = { expand_while_streaming = false, collapse_on_finish = true }
      s:append_text("thought", "quiet", "m")
      t.eq(nil, s.blocks[1].expanded)
      local lines = blocks.render_block(
        s.blocks[1],
        ctx({
          thoughts = { expand_while_streaming = false, show_collapsed_header = true },
        })
      )
      t.falsy(text_of(lines):find("quiet", 1, true))
    end)

    t.it("can stay open after finishing when configured", function()
      local s = state.new("s", "/proj")
      s.thoughts = { expand_while_streaming = true, collapse_on_finish = false }
      s:append_text("thought", "kept", "m")
      local block = s.blocks[1]
      s:finish_thought(block)
      t.truthy(block.expanded)
    end)

    t.it("respects a manual collapse during streaming", function()
      local s = state.new("s", "/proj")
      s:append_text("thought", "reasoning", "m")
      local block = s.blocks[1]
      s:toggle(block)
      t.eq(false, block.expanded)
      s:append_text("thought", " more", "m")
      t.eq(false, block.expanded)
      s:finish_thought(block)
      t.eq(false, block.expanded)
    end)

    t.it("keeps the header while streaming even when collapsed headers are off", function()
      local block = thought("live", "streaming")
      local lines = blocks.render_block(
        block,
        ctx({
          thoughts = { expand_while_streaming = false, show_collapsed_header = false },
        })
      )
      t.truthy(#lines > 0)
      t.match("Thinking", lines[1].text)
    end)

    t.it("leaves history collapsed after a replay finishes", function()
      local s = state.new("s", "/proj")
      s.historical = true
      s:begin_turn()
      s:append_text("thought", "old reasoning", "m")
      s:finish_turn("end_turn")
      t.eq(nil, s.blocks[1].status)
      t.eq(false, s.blocks[1].expanded)
    end)
  end)

  t.describe("thought toggling", function()
    local Chat = require("acp.ui.chat")
    local config = require("acp.config")

    t.it("is handled by toggle_current", function()
      local cfg = config.validate(config.merge(config.defaults, {}))
      local chat = Chat.new({ config = cfg })
      local s = state.new("s", "/proj")
      s:append({ id = "th", kind = "thought", text = "reasoning" })
      chat:set_session(s)
      chat:render(true)

      -- Put the cursor on the thought header.
      local win = chat.win
      if not win or not vim.api.nvim_win_is_valid(win) then
        chat.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(chat.win, chat.buf)
      end
      vim.api.nvim_win_set_cursor(chat.win, { 1, 0 })

      t.truthy(chat:toggle_current(), "toggle_current ignored the thought block")
      t.eq(true, s.blocks[1].expanded)
      t.truthy(chat:toggle_current())
      t.eq(false, s.blocks[1].expanded)
    end)
  end)
end
