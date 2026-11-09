-- Tests for the inline Markdown scanner. Delimiters are concealed rather than
-- deleted, so every assertion also checks that the returned ranges stay within
-- the untouched text.
return function(t)
  local markdown = require("acp.ui.markdown")

  ---Collect the visible text of a line: concealed ranges removed.
  ---@param line string
  ---@param segments table[]
  ---@return string
  local function visible(line, segments)
    local hide = {}
    for _, seg in ipairs(segments) do
      if seg.conceal then
        for i = seg.s + 1, seg.e do
          hide[i] = true
        end
      end
    end
    local out = {}
    for i = 1, #line do
      if not hide[i] then
        out[#out + 1] = line:sub(i, i)
      end
    end
    return table.concat(out)
  end

  ---Group of the segment covering byte `i` (0-based), or nil.
  ---Later segments win, mirroring how overlapping extmarks stack at equal
  ---priority (the markup segment is emitted after the base range).
  local function group_at(segments, i)
    local found
    for _, seg in ipairs(segments) do
      if not seg.conceal and i >= seg.s and i < seg.e then
        found = seg.group
      end
    end
    return found
  end

  local function find(text)
    return text
  end

  t.describe("inline markdown", function()
    t.it("leaves plain text alone", function()
      local line = find("just some words")
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq(line, visible(line, segs))
      t.eq("AcpAssistant", group_at(segs, 0))
    end)

    t.it("handles empty input", function()
      t.eq(1, #markdown.parse_inline("", "AcpAssistant"))
    end)

    t.it("conceals bold delimiters and styles the body", function()
      local line = "a **bold** word"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("a bold word", visible(line, segs))
      t.eq("AcpBold", group_at(segs, line:find("bold") - 1))
    end)

    t.it("conceals italic delimiters", function()
      local line = "an *italic* word"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("an italic word", visible(line, segs))
      t.eq("AcpItalic", group_at(segs, line:find("italic") - 1))
    end)

    t.it("prefers ** over * when both are possible", function()
      local line = "**strong**"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("strong", visible(line, segs))
      t.eq("AcpBold", group_at(segs, 2))
    end)

    t.it("handles strikethrough", function()
      local line = "~~gone~~"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("gone", visible(line, segs))
      t.eq("AcpStrike", group_at(segs, 2))
    end)

    t.it("conceals backticks and styles inline code", function()
      local line = "run `ls -la` now"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("run ls -la now", visible(line, segs))
      t.eq("AcpMdCode", group_at(segs, line:find("ls") - 1))
    end)

    t.it("does not parse markup inside inline code", function()
      local line = "`a **b** c`"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("a **b** c", visible(line, segs))
      -- The whole code span keeps the code group.
      t.eq("AcpMdCode", group_at(segs, 2))
      for _, seg in ipairs(segs) do
        t.falsy(seg.group == "AcpBold", "bold inside code must not be applied")
      end
    end)

    t.it("renders a link as its label", function()
      local line = "see [docs](https://example.com) here"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("see docs here", visible(line, segs))
      t.eq("AcpMdLink", group_at(segs, line:find("docs") - 1))
    end)

    t.it("leaves an unclosed delimiter as text", function()
      local line = "a **b"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("a **b", visible(line, segs))
    end)

    t.it("leaves an unclosed backtick as text", function()
      local line = "run `ls"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("run `ls", visible(line, segs))
    end)

    t.it("does not italicise snake_case identifiers", function()
      local line = "call some_function_name now"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("call some_function_name now", visible(line, segs))
      t.eq("AcpAssistant", group_at(segs, line:find("some_function") - 1))
    end)

    t.it("does not italicise arithmetic", function()
      local line = "2*3*4 equals 24"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("2*3*4 equals 24", visible(line, segs))
    end)

    t.it("keeps offsets correct around multibyte text", function()
      local line = "中文 **粗体** 结束"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      t.eq("中文 粗体 结束", visible(line, segs))
      local byte = line:find("粗")
      t.eq("AcpBold", group_at(segs, byte - 1))
    end)

    t.it("finds segments in source order", function()
      local line = "**a** and `b`"
      local segs = markdown.parse_inline(line, "AcpAssistant")
      local last_conceal = -1
      for _, seg in ipairs(segs) do
        if seg.conceal then
          t.truthy(seg.s >= last_conceal, "segments are out of order")
          last_conceal = seg.s
        end
      end
    end)

    t.it("reports conceal presence", function()
      t.truthy(markdown.has_conceal(markdown.parse_inline("**x**", "A")))
      t.falsy(markdown.has_conceal(markdown.parse_inline("plain", "A")))
    end)

    t.it("keeps every range within the line", function()
      local cases = {
        "**bold**",
        "`code`",
        "[l](u)",
        "~~s~~",
        "a *b* c **d** e `f` g",
        "中文 **粗体** 和 *斜体*",
        "**",
        "``",
        "[]()",
      }
      for _, line in ipairs(cases) do
        for _, seg in ipairs(markdown.parse_inline(line, "A")) do
          t.truthy(seg.s >= 0, "negative start in " .. line)
          t.truthy(seg.e <= #line, "end past the line in " .. line)
          t.truthy(seg.e >= seg.s, "inverted range in " .. line)
        end
      end
    end)
  end)

  t.describe("rendered blocks", function()
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

    t.it("keeps conceal segments through rendering", function()
      local lines = render("a **bold** word")
      local concealed = 0
      for _, seg in ipairs(lines[1].segments or {}) do
        if seg.conceal then
          concealed = concealed + 1
        end
      end
      t.eq(2, concealed, "bold delimiters should be concealed after rendering")
    end)

    t.it("keeps conceal segments inside thoughts", function()
      local s = state.new("s", "/tmp")
      s:append({ id = "t", kind = "thought", text = "uses `code` here" })
      local lines = blocks.render_block(s.blocks[1], {
        icons = blocks.icon_set(true),
        width = 80,
        cwd = "/tmp",
        show_thoughts = true,
      })
      local groups, concealed = {}, 0
      for _, seg in ipairs(lines[1].segments or {}) do
        if seg.conceal then
          concealed = concealed + 1
        elseif seg.group then
          groups[seg.group] = true
        end
      end
      t.eq(2, concealed, "backticks should be concealed inside a thought")
      t.truthy(groups["AcpMdCode"], "inline code lost its style inside a thought")
    end)
  end)

  t.describe("headings", function()
    local blocks = require("acp.ui.blocks")
    local state = require("acp.session.state")

    t.it("maps levels to their own group", function()
      local expected = { "AcpH1", "AcpH2", "AcpH3", "AcpH4" }
      for level = 1, 4 do
        local s = state.new("s", "/tmp")
        s:append({ id = "a", kind = "agent", text = string.rep("#", level) .. " Title" })
        local lines = blocks.render_block(s.blocks[1], {
          icons = blocks.icon_set(true),
          width = 80,
          cwd = "/tmp",
          show_thoughts = false,
        })
        -- The heading marker is dropped from the text; the body keeps its level
        -- group.
        t.truthy(lines[1].text:find("Title", 1, true), "heading text missing")
        local groups = {}
        for _, seg in ipairs(lines[1].segments or {}) do
          groups[seg.group] = true
        end
        t.truthy(groups[expected[level]], "heading level " .. level .. " lost its group")
      end
    end)
  end)
end
