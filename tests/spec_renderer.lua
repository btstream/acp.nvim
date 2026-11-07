return function(t)
  local state = require("acp.session.state")
  local blocks = require("acp.ui.blocks")

  t.describe("renderer", function()
    local ctx = { icons = blocks.icon_set(true), width = 80, cwd = "/tmp", show_thoughts = false }

    t.it("renders a user message with a header and chips", function()
      local s = state.new("s", "/tmp")
      s:add_local_user("hello", { { label = "main.lua" } })
      local lines = blocks.render_block(s.blocks[1], ctx)
      t.match("You", lines[1].text)
      t.match("main.lua", lines[1].text)
      t.match("hello", lines[2].text)
    end)

    t.it("renders fenced code blocks", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "a", kind = "agent", text = "text\n```lua\nlocal x = 1\n```\n" })
      local lines = blocks.render_block(s.blocks[1], ctx)
      local joined = table.concat(
        vim.tbl_map(function(l)
          return l.text
        end, lines),
        "\n"
      )
      t.match("lua", joined)
      t.match("local x = 1", joined)
    end)

    t.it("renders a completed tool with a checkmark", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "t", kind = "tool", title = "Read file", status = "completed", detail = "contents" })
      local lines = blocks.render_block(s.blocks[1], ctx)
      t.match("Read file", lines[1].text)
      local ic = require("acp.ui.icons").get(true)
      t.match(vim.pesc(ic.tool_ok), lines[1].text)
      t.match("contents", lines[2].text)
    end)

    t.it("hides thoughts when disabled", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "th", kind = "thought", text = "secret reasoning" })
      local lines = blocks.render_block(s.blocks[1], ctx)
      t.eq(0, #lines)
      local shown = blocks.render_block(s.blocks[1], vim.tbl_extend("force", ctx, { show_thoughts = true }))
      t.truthy(#shown > 0)
    end)

    t.it("renders plan entries with status marks", function()
      local s = state.new("s", "/tmp")
      s:append({
        id = "p",
        kind = "plan",
        entries = {
          { content = "done item", status = "completed" },
          { content = "todo item", status = "pending" },
        },
      })
      local lines = blocks.render_block(s.blocks[1], ctx)
      t.match("done item", lines[2].text)
      t.match("done item", lines[2].text)
      t.match("todo item", lines[3].text)
    end)

    t.it("renders an expanded tool with locations", function()
      local s = state.new("s", "/tmp")
      s:append({
        id = "t",
        kind = "tool",
        title = "Edit",
        status = "completed",
        expanded = true,
        locations = { { path = "/tmp/src/a.lua", line = 12 } },
      })
      local lines = blocks.render_block(s.blocks[1], ctx)
      local joined = table.concat(
        vim.tbl_map(function(l)
          return l.text
        end, lines),
        "\n"
      )
      t.match("src/a.lua:12", joined)
    end)

    t.it("renders notices with severity", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "n", kind = "notice", title = "Heads up", text = "detail", severity = "warning" })
      local lines = blocks.render_block(s.blocks[1], ctx)
      t.match("Heads up", lines[1].text)
      t.eq("AcpNoticeWarn", lines[1].segments[1].group)
    end)
  end)
end
