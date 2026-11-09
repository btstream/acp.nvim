-- Tests for the tool card rendering (phase 3).
return function(t)
  local blocks = require("acp.ui.blocks")
  local state = require("acp.session.state")

  local function ctx(overrides)
    return vim.tbl_extend("force", {
      icons = blocks.icon_set(true),
      width = 60,
      cwd = "/proj",
      show_thoughts = false,
    }, overrides or {})
  end

  local function render(block, overrides)
    return blocks.render_block(block, ctx(overrides))
  end

  local function joined(lines)
    local out = {}
    for _, l in ipairs(lines) do
      out[#out + 1] = l.text
    end
    return table.concat(out, "\n")
  end

  t.describe("tool labels", function()
    local cases = {
      { kind = "execute", expect = "Run Command" },
      { kind = "edit", expect = "Write" },
      { kind = "read", expect = "Read" },
      { kind = "search", expect = "Search" },
      { kind = "fetch", expect = "Fetch" },
      { kind = "think", expect = "Thinking" },
    }
    for _, case in ipairs(cases) do
      t.it("maps " .. case.kind, function()
        local s = state.new("s", "/proj")
        s:append({ id = "t", kind = "tool", tool_kind = case.kind, status = "completed" })
        local lines = render(s.blocks[1])
        t.match(case.expect, lines[1].text)
      end)
    end

    t.it("humanises an unknown kind", function()
      local s = state.new("s", "/proj")
      s:append({ id = "t", kind = "tool", tool_kind = "switch_mode", status = "completed" })
      t.match("Switch Mode", render(s.blocks[1])[1].text)
    end)

    t.it("falls back to Tool without a kind", function()
      local s = state.new("s", "/proj")
      s:append({ id = "t", kind = "tool", status = "completed" })
      t.match("Tool", render(s.blocks[1])[1].text)
    end)
  end)

  t.describe("tool cards", function()
    t.it("shows the agent title next to the label", function()
      local s = state.new("s", "/proj")
      s:append({ id = "t", kind = "tool", tool_kind = "execute", title = "cargo build", status = "completed" })
      local text = render(s.blocks[1])[1].text
      t.match("Run Command", text)
      t.match("cargo build", text)
    end)

    t.it("does not repeat a title equal to the label", function()
      local s = state.new("s", "/proj")
      s:append({ id = "t", kind = "tool", tool_kind = "execute", title = "Run Command", status = "completed" })
      local text = render(s.blocks[1])[1].text
      local _, count = text:gsub("Run Command", "")
      t.eq(1, count, "label repeated in the header")
    end)

    t.it("collapses to a header and one preview line", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "execute",
        title = "grep",
        status = "completed",
        detail = "line one\nline two\nline three",
      })
      local lines = render(s.blocks[1])
      t.truthy(lines[1].text:find("Run Command", 1, true))
      t.eq(nil, lines[1].bg, "the header is not part of the card")
      -- One preview line follows, without a card background.
      t.match("line one", lines[2].text)
      t.falsy(joined(lines):find("line two", 1, true), "collapsed tool should not show every line")
    end)

    t.it("expands into a padded card", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "execute",
        title = "cargo fetch",
        status = "completed",
        expanded = true,
        detail = "compiling\nfinished",
      })
      local lines = render(s.blocks[1])
      t.eq(nil, lines[1].bg, "the header is not part of the card")

      -- Every card row shares the background and is padded on the left.
      local body = {}
      for _, line in ipairs(lines) do
        if line.bg then
          body[#body + 1] = line
        end
      end
      t.truthy(#body >= 4, "card should have a top pad, content and a bottom pad")
      for _, line in ipairs(body) do
        t.eq("AcpCardBg", line.bg)
        t.match("^  ", line.text, "card rows need a left margin")
      end
      t.match("compiling", joined(lines):find("compiling") and "compiling" or "")
      t.match("finished", joined(lines):find("finished") and "finished" or "")
    end)

    t.it("keeps status and subagent metadata in the header", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "read",
        status = "failed",
        child = { title = "sub" },
        expanded = true,
        detail = "boom",
      })
      local text = render(s.blocks[1])[1].text
      t.match("failed", text)
      t.match("sub", text)
    end)

    t.it("shows failed raw output inside the card", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "failed",
        expanded = true,
        detail = "write failed",
        raw_output = "permission denied",
      })
      local text = joined(render(s.blocks[1]))
      t.match("write failed", text)
      t.match("permission denied", text)
    end)

    t.it("lists locations inside the card", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "completed",
        expanded = true,
        detail = "changed",
        locations = { { path = "/proj/src/a.lua", line = 3 } },
      })
      local lines = render(s.blocks[1])
      local found
      for _, line in ipairs(lines) do
        if line.text:find("src/a.lua:3", 1, true) then
          found = line
        end
      end
      t.truthy(found, "location missing from the card")
      t.eq("AcpCardBg", found.bg)
      t.truthy(found.location, "location metadata must survive for jumping")
    end)

    t.it("does not open a card with nothing to show", function()
      local s = state.new("s", "/proj")
      s:append({ id = "t", kind = "tool", tool_kind = "execute", status = "completed", expanded = true })
      for _, line in ipairs(render(s.blocks[1])) do
        t.eq(nil, line.bg, "an empty card should not be painted")
      end
    end)

    t.it("keeps every card row a single line", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "execute",
        status = "completed",
        expanded = true,
        detail = "a\nb\nc",
      })
      for _, line in ipairs(render(s.blocks[1])) do
        t.falsy(line.text:find("\n"), "card row contains a newline")
      end
    end)
  end)

  t.describe("padding helper", function()
    t.it("pads to a display width", function()
      t.eq("ab  ", blocks.pad_to("ab", 4))
    end)

    t.it("never truncates", function()
      t.eq("abcd", blocks.pad_to("abcd", 2))
    end)

    t.it("measures multibyte text by cell width", function()
      -- "中文" is 4 cells but 6 bytes.
      t.eq("中文", blocks.pad_to("中文", 4))
      t.eq(#blocks.pad_to("中文", 6), 6 + (6 - 4))
    end)
  end)
end
