return function(t)
  local state = require("acp.session.state")
  local blocks = require("acp.ui.blocks")
  local Chat = require("acp.ui.chat")
  local config = require("acp.config")

  local ctx = {
    icons = blocks.icon_set(true),
    width = 80,
    cwd = "/tmp",
    show_thoughts = true,
  }

  ---Every rendered line must be a single line: a buffer line cannot contain a
  ---newline, and agent supplied text often does.
  local function assert_single_line(rendered, label)
    for i, line in ipairs(rendered) do
      t.falsy(line.text:find("[\r\n]"), string.format("%s line %d contains a newline: %q", label, i, line.text))
    end
  end

  t.describe("newline sanitising", function()
    t.it("folds newlines in tool titles", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "t", kind = "tool", title = "Read\nfile", status = "completed" })
      assert_single_line(blocks.render_block(s.blocks[1], ctx), "tool")
    end)

    t.it("folds newlines in plan entries", function()
      local s = state.new("s", "/tmp")
      s:append({
        id = "p",
        kind = "plan",
        entries = { { content = "line one\nline two", status = "pending" } },
      })
      assert_single_line(blocks.render_block(s.blocks[1], ctx), "plan")
    end)

    t.it("folds newlines in notices", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "n", kind = "notice", title = "Warn\nhere", text = "body", severity = "warning" })
      assert_single_line(blocks.render_block(s.blocks[1], ctx), "notice")
    end)

    t.it("folds newlines in tool locations and child titles", function()
      local s = state.new("s", "/tmp")
      s:append({
        id = "t",
        kind = "tool",
        title = "T",
        status = "completed",
        expanded = true,
        locations = { { path = "/tmp/a\nb.lua", line = 3 } },
        child = { title = "child\nsession" },
      })
      assert_single_line(blocks.render_block(s.blocks[1], ctx), "tool locations")
    end)

    t.it("keeps multi-line system notices readable", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "sys", kind = "system", text = "first line\nsecond line" })
      local rendered = blocks.render_block(s.blocks[1], ctx)
      assert_single_line(rendered, "system")
      t.truthy(#rendered >= 2, "a multi-line notice should stay multi-line")
      t.match("first line", rendered[1].text)
      t.match("second line", rendered[2].text)
    end)

    t.it("renders a session with newlines without raising", function()
      local cfg = config.validate(config.merge(config.defaults, {}))
      local chat = Chat.new({ config = cfg })
      local s = state.new("s", "/tmp")
      s:append({ id = "t", kind = "tool", title = "Read\nfile", status = "completed" })
      s:append({
        id = "p",
        kind = "plan",
        entries = { { content = "one\ntwo", status = "pending" } },
      })
      s:append({ id = "n", kind = "notice", title = "Warn\nhere", text = "x" })
      chat:set_session(s)
      chat:render()
      local lines = vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
      for i, line in ipairs(lines) do
        t.falsy(line:find("[\r\n]"), string.format("buffer line %d contains a newline", i))
      end
      t.truthy(#lines > 0)
    end)

    t.it("keeps the transcript buffer usable after a bad render", function()
      local cfg = config.validate(config.merge(config.defaults, {}))
      local chat = Chat.new({ config = cfg })
      local s = state.new("s", "/tmp")
      s:append({ id = "t", kind = "tool", title = "a\nb", status = "completed" })
      chat:set_session(s)
      local ok = pcall(function()
        chat:render()
      end)
      t.truthy(ok, "render raised an error")
      t.falsy(vim.bo[chat.buf].modifiable, "the transcript must stay read-only")
    end)
  end)
end
