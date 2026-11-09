-- Tests for fenced-code syntax highlighting and its background.
return function(t)
  local CodeHL = require("acp.ui.code_hl")
  local blocks = require("acp.ui.blocks")
  local state = require("acp.session.state")

  local function render(text)
    local s = state.new("s", "/tmp")
    s:append({ id = "a", kind = "agent", text = text })
    return blocks.render_block(s.blocks[1], {
      icons = blocks.icon_set(true),
      width = 80,
      cwd = "/tmp",
      show_thoughts = false,
    })
  end

  t.describe("language resolution", function()
    t.it("maps common aliases to parser names", function()
      t.eq("javascript", CodeHL.resolve_language("js"))
      t.eq("typescript", CodeHL.resolve_language("tsx"))
      t.eq("bash", CodeHL.resolve_language("sh"))
      t.eq("python", CodeHL.resolve_language("py"))
      t.eq("cpp", CodeHL.resolve_language("c++"))
    end)

    t.it("leaves unknown languages untouched", function()
      t.eq("lua", CodeHL.resolve_language("lua"))
      t.eq("wat", CodeHL.resolve_language("wat"))
    end)

    t.it("is case insensitive", function()
      t.eq("lua", CodeHL.resolve_language("LUA"))
      t.eq("javascript", CodeHL.resolve_language("JS"))
    end)
  end)

  t.describe("highlighting", function()
    t.it("produces ranges for a supported language", function()
      local ranges, ok = CodeHL.highlight("local x = 1\nreturn x", "lua")
      t.truthy(ok)
      t.truthy(ranges and #ranges > 0, "no ranges produced")
      for _, r in ipairs(ranges) do
        t.truthy(r.row >= 0, "negative row")
        t.truthy(r.group ~= nil, "missing group")
      end
    end)

    t.it("reports failure instead of raising for an unknown language", function()
      local ranges, ok = CodeHL.highlight("x", "definitely-not-a-language")
      t.falsy(ok)
      t.eq(nil, ranges)
    end)

    t.it("returns nothing for empty input", function()
      local ranges, ok = CodeHL.highlight("", "lua")
      t.falsy(ok)
      t.eq(nil, ranges)
    end)

    t.it("prefers language-specific groups when they exist", function()
      -- `@keyword` always exists; the language variant may too.
      local group = CodeHL.group_for("keyword", "lua")
      t.match("^@keyword", group)
    end)

    t.it("falls back to the plain capture name", function()
      local group = CodeHL.group_for("not.a.real.capture", "lua")
      t.eq("@not.a.real.capture", group)
    end)

    t.it("splits multi-row captures into per-row ranges", function()
      local code = "local s = [[\nline two\n]]"
      local ranges, ok = CodeHL.highlight(code, "lua")
      t.truthy(ok)
      local rows = {}
      for _, r in ipairs(ranges or {}) do
        rows[r.row] = true
      end
      t.truthy(rows[0], "first row missing")
    end)
  end)

  t.describe("code block rendering", function()
    t.it("gives every fence row a background", function()
      local lines = render("```lua\nlocal x = 1\n```")
      -- Language label and code line; the closing fence emits no row.
      local seen = 0
      for _, line in ipairs(lines) do
        if line.bg then
          seen = seen + 1
          t.eq("AcpCodeBlockBg", line.bg)
        end
      end
      t.eq(2, seen, "the language row and the code row should be painted")
    end)

    t.it("does not background prose outside the fence", function()
      local lines = render("before\n```lua\nx\n```\nafter")
      for _, line in ipairs(lines) do
        if line.text:find("before", 1, true) or line.text:find("after", 1, true) then
          t.eq(nil, line.bg, "prose outside the fence must not be painted")
        end
      end
    end)

    t.it("applies syntax groups to code rows", function()
      local lines = render("```lua\nlocal x = 1\nreturn x\n```")
      local groups = {}
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          groups[seg.group] = true
        end
      end
      t.truthy(groups["@keyword.lua"] or groups["@keyword"], "no keyword highlight")
    end)

    t.it("leaves code plain when the language is unknown", function()
      local lines = render("```notalang\nwhatever\n```")
      local saw_fence_only = true
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          if seg.group and seg.group:sub(1, 1) == "@" then
            saw_fence_only = false
          end
        end
      end
      t.truthy(saw_fence_only, "unknown language should not produce syntax groups")
    end)

    t.it("renders an unclosed fence without highlighting or raising", function()
      local lines = render("```lua\nlocal x = 1\n") -- no closing fence
      t.truthy(#lines > 0)
      local saw_syntax = false
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          if seg.group and seg.group:sub(1, 1) == "@" then
            saw_syntax = true
          end
        end
      end
      t.falsy(saw_syntax, "a partial block should not be highlighted")
    end)

    t.it("highlights once the fence closes while streaming", function()
      -- Streaming: the block grows one chunk at a time.
      local cache = {}
      local partial = "```lua\nlocal x = 1"
      local full = "```lua\nlocal x = 1\n```"
      blocks.render_text(partial, "AcpAssistant", 80, cache)
      local lines = blocks.render_text(full, "AcpAssistant", 80, cache)
      local saw_syntax = false
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          if seg.group and seg.group:sub(1, 1) == "@" then
            saw_syntax = true
          end
        end
      end
      t.truthy(saw_syntax, "highlighting should appear after the fence closes")
    end)

    t.it("renders the block without border characters", function()
      local lines = render("```lua\nlocal x = 1\n```")
      for _, line in ipairs(lines) do
        t.falsy(line.text:find("╭", 1, true), "code block should not draw a top border")
        t.falsy(line.text:find("╰", 1, true), "code block should not draw a bottom border")
        t.falsy(line.text:find("│", 1, true), "code block should not draw a side border")
      end
    end)

    t.it("labels the block with the fence language", function()
      local lines = render("```lua\nlocal x = 1\n```")
      local found
      for _, line in ipairs(lines) do
        if line.text:find("lua", 1, true) then
          found = line
        end
      end
      t.truthy(found, "language label missing")
      t.eq("AcpCodeBlockBg", found.bg, "the label row is part of the block surface")
    end)

    t.it("does not add a row for the closing fence", function()
      local with_close = render("```lua\nx\n```")
      local without = render("```lua\nx")
      -- The closing fence must not introduce a blank line the text did not
      -- have; an unterminated fence renders the same two rows.
      t.eq(#without, #with_close, "the closing fence added a row")
      local blank_rows = 0
      for _, line in ipairs(with_close) do
        if line.bg and vim.trim(line.text) == "" then
          blank_rows = blank_rows + 1
        end
      end
      t.eq(0, blank_rows, "the surface should end with the last code line")
    end)

    t.it("keeps syntax ranges inside the rendered line", function()
      local lines = render("```lua\nlocal x = 1\n```")
      for _, line in ipairs(lines) do
        local len = #line.text
        for _, seg in ipairs(line.segments or {}) do
          t.truthy(seg.s >= 0 and seg.s <= len, "segment starts outside the line")
          t.truthy(seg.e == -1 or seg.e <= len, "segment ends outside the line")
        end
      end
    end)

    t.it("matches a full render when streamed byte by byte", function()
      local full = "```lua\nlocal x = 1\nreturn x\n```"
      local cache = {}

      local function norm(lines)
        local out = {}
        for _, l in ipairs(lines) do
          local segs = {}
          for _, s in ipairs(l.segments or {}) do
            segs[#segs + 1] = string.format("%d:%d:%s", s.s, s.e, tostring(s.group))
          end
          out[#out + 1] = string.format("%q bg=%s [%s]", l.text, tostring(l.bg), table.concat(segs, " "))
        end
        return table.concat(out, "\n")
      end

      for i = 1, #full do
        blocks.render_text(full:sub(1, i), "AcpAssistant", 80, cache)
      end
      local streamed = blocks.render_text(full, "AcpAssistant", 80, cache)
      local fresh = blocks.render_text(full, "AcpAssistant", 80)
      t.eq(norm(fresh), norm(streamed), "streamed render diverged from a full render")
    end)

    t.it("does not duplicate syntax ranges on repeated renders", function()
      local cache = {}
      local text = "```lua\nlocal x = 1\n```"
      blocks.render_text(text, "AcpAssistant", 80, cache)
      local first = blocks.render_text(text, "AcpAssistant", 80, cache)
      local second = blocks.render_text(text, "AcpAssistant", 80, cache)
      local function count(lines)
        local n = 0
        for _, l in ipairs(lines) do
          for _, s in ipairs(l.segments or {}) do
            if s.group and s.group:sub(1, 1) == "@" then
              n = n + 1
            end
          end
        end
        return n
      end
      t.eq(count(first), count(second), "syntax ranges accumulated across renders")
    end)
  end)
end
