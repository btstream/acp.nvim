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

  t.describe("card toggling", function()
    local config = require("acp.config")
    local Chat = require("acp.ui.chat")
    local ns = vim.api.nvim_create_namespace("acp_chat")
    local ns_bg = vim.api.nvim_create_namespace("acp_chat_bg")

    ---Snapshot every extmark so two renders can be compared exactly.
    local function snapshot(chat)
      local function dump(space)
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, space, 0, -1, { details = true })) do
          out[#out + 1] = string.format("%d:%d-%s:%s", m[2], m[3], tostring(m[4].end_col), tostring(m[4].hl_group))
        end
        table.sort(out)
        return table.concat(out, ",")
      end
      return dump(ns) .. "|" .. dump(ns_bg)
    end

    local function fresh(s, cfg)
      local ref = Chat.new({ config = cfg })
      ref:set_session(s)
      ref:render(true)
      return snapshot(ref)
    end

    t.it("keeps later blocks highlighted after repeated toggles", function()
      local cfg = config.validate(config.merge(config.defaults, {}))
      local s = state.new("s", "/proj")
      s:append({ id = "u", kind = "user", text = "hello" })
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "execute",
        title = "cmd",
        status = "completed",
        expanded = false,
        detail = "line one\nline two\nline three",
      })
      s:append({ id = "a", kind = "agent", text = "follow-up **bold** and `code`" })
      s:append({
        id = "t2",
        kind = "tool",
        tool_kind = "read",
        title = "src/x.lua",
        status = "completed",
        expanded = false,
        detail = "read x",
      })

      local chat = Chat.new({ config = cfg })
      chat:set_session(s)
      chat:render(true)

      for i = 1, 6 do
        s.blocks[2].expanded = not s.blocks[2].expanded
        chat:render(true)
        t.eq(fresh(s, cfg), snapshot(chat), "extmarks diverged after toggle " .. i)
      end
    end)

    t.it("does not drop highlights of blocks after a growing card", function()
      local cfg = config.validate(config.merge(config.defaults, {}))
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "execute",
        status = "completed",
        expanded = false,
        detail = "a\nb",
      })
      s:append({ id = "a", kind = "agent", text = "text after the card" })

      local chat = Chat.new({ config = cfg })
      chat:set_session(s)
      chat:render(true)

      s.blocks[1].expanded = true
      chat:render(true)

      -- The agent block still needs its inline highlight.
      local found = false
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, ns, 0, -1, { details = true })) do
        local line = vim.api.nvim_buf_get_lines(chat.buf, m[2], m[2] + 1, false)[1] or ""
        if line:find("text after the card", 1, true) and m[4].hl_group then
          found = true
        end
      end
      t.truthy(found, "the block after the card lost its highlight")
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
