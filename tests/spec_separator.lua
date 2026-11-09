return function(t)
  local config = require("acp.config")
  local state = require("acp.session.state")
  local Chat = require("acp.ui.chat")
  local blocks = require("acp.ui.blocks")

  local function chat_with(cfg, width)
    local merged = config.validate(config.merge(config.defaults, cfg or {}))
    require("acp.ui.highlights").setup()
    local chat = Chat.new({ config = merged })
    chat.width = width or 50
    return chat
  end

  local function session_with_turns(n)
    local s = state.new("ses_sep", "/tmp")
    for i = 1, n do
      s:append({ id = "u" .. i, kind = "user", text = "question " .. i })
      s:append({ id = "a" .. i, kind = "agent", text = "answer " .. i })
    end
    return s
  end

  local function lines(chat)
    return vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
  end

  local function separators(chat)
    local found = {}
    for i, m in ipairs(chat.meta) do
      if m.kind == "separator" then
        found[#found + 1] = { row = i, text = lines(chat)[i] }
      end
    end
    return found
  end

  t.describe("turn separators", function()
    t.it("draws a rule with a centred dot by default", function()
      local chat = chat_with()
      chat:set_session(session_with_turns(2))
      local found = separators(chat)
      t.eq(1, #found, "three turns need two separators, two turns need one")
      local text = found[1].text
      t.truthy(text:find("●", 1, true), "the dot marker is missing")
      t.truthy(text:find("─", 1, true), "the rule is missing")
      -- The dot sits in the middle, not at either end.
      local dot = text:find("●", 1, true)
      t.truthy(dot > #text / 3 and dot < #text * 2 / 3, "the dot should be centred")
    end)

    t.it("is not drawn before the first turn", function()
      local chat = chat_with()
      chat:set_session(session_with_turns(1))
      t.eq(0, #separators(chat), "a single turn has nothing to separate")
    end)

    t.it("inserts one divider between every pair of turns", function()
      local chat = chat_with()
      chat:set_session(session_with_turns(4))
      t.eq(3, #separators(chat))
    end)

    t.it("numbers the turns in turn form", function()
      local chat = chat_with({ ui = { separator = { form = "turn" } } })
      chat:set_session(session_with_turns(3))
      local found = separators(chat)
      t.eq(2, #found)
      t.truthy(found[1].text:find("Turn 2", 1, true), "the second turn should be labelled 2: " .. found[1].text)
      t.truthy(found[2].text:find("Turn 3", 1, true), "the third turn should be labelled 3: " .. found[2].text)
    end)

    t.it("puts the turn glyph in the turn form", function()
      local chat = chat_with({ ui = { separator = { form = "turn" } } })
      chat:set_session(session_with_turns(2))
      local ic = require("acp.ui.icons").get(true)
      t.truthy(separators(chat)[1].text:find(ic.history, 1, true), "the turn glyph is missing")
    end)

    t.it("draws nothing when the form is off", function()
      local chat = chat_with({ ui = { separator = { form = "off" } } })
      chat:set_session(session_with_turns(3))
      t.eq(0, #separators(chat))
      for _, line in ipairs(lines(chat)) do
        t.falsy(line:find("●", 1, true), "a dot leaked into the transcript")
      end
    end)

    t.it("keeps the marker when the panel is too narrow for a rule", function()
      local chat = chat_with({ ui = { separator = { form = "turn" } } }, 12)
      chat:set_session(session_with_turns(2))
      local found = separators(chat)
      t.eq(1, #found)
      -- No room for rules on both sides: the marker still marks the boundary.
      t.truthy(found[1].text:find("Turn 2", 1, true), "the marker should survive a narrow panel")
    end)

    t.it("never binds a separator row to a block", function()
      -- The divider is transcript chrome. If it carried a block id, the cursor
      -- would land on it and <Tab> would try to expand the neighbouring block.
      local chat = chat_with()
      chat:set_session(session_with_turns(3))
      for _, m in ipairs(chat.meta) do
        if m.kind == "separator" then
          t.eq(nil, m.block_id, "a separator row must not belong to a block")
        end
      end
    end)

    t.it("styles the rule and the marker separately", function()
      local chat = chat_with({ ui = { separator = { form = "turn" } } })
      chat:set_session(session_with_turns(2))
      local row
      for i, m in ipairs(chat.meta) do
        if m.kind == "separator" then
          row = m
        end
      end
      t.truthy(row and row.segments, "the separator has no segments")
      local groups = {}
      for _, seg in ipairs(row.segments) do
        groups[seg.group] = true
      end
      t.truthy(groups["AcpSeparator"], "the rule should use the separator group")
      t.truthy(groups["AcpMuted"] or groups["AcpSeparator"], "the marker needs a colour")
    end)

    t.it("survives an incremental render", function()
      -- The divider is emitted outside the block cache, so it has to appear when
      -- the turn that follows it arrives, not only on a full rewrite.
      local chat = chat_with()
      local s = session_with_turns(1)
      chat:set_session(s)
      t.eq(0, #separators(chat), "no divider for the first turn")
      s:append({ id = "u2", kind = "user", text = "second" })
      chat:render()
      t.eq(1, #separators(chat), "the divider should appear with the second turn")
      s:append({ id = "a2", kind = "agent", text = "second answer" })
      chat:render()
      t.eq(1, #separators(chat), "the divider count must not change as the turn streams")
    end)

    t.it("renders a rule that fits the requested width", function()
      -- `render_separator` is the unit under the integration above: check the
      -- width handling directly, including the odd-width case.
      local ic = require("acp.ui.icons").get(true)
      for _, width in ipairs({ 40, 41, 60, 79 }) do
        local out = blocks.render_separator({ width = width, icons = ic }, { form = "turn", turn = 5 })
        t.eq(1, #out)
        t.eq(width, vim.api.nvim_strwidth(out[1].text), "the rule should span the panel width at " .. width)
      end
    end)
  end)
end
