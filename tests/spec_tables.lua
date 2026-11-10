-- Tests for GFM pipe-table rendering.
return function(t)
  local blocks = require("acp.ui.blocks")
  local state = require("acp.session.state")
  local Table = require("acp.ui.table")

  local function render(text, width)
    local s = state.new("s", "/proj")
    s:append({ id = "a", kind = "agent", text = text })
    return blocks.render_block(s.blocks[1], {
      icons = blocks.icon_set(true),
      width = width or 60,
      cwd = "/proj",
      show_thoughts = false,
    })
  end

  local function texts(lines)
    local out = {}
    for _, l in ipairs(lines) do
      out[#out + 1] = l.text
    end
    return out
  end

  local function joined(lines)
    return table.concat(texts(lines), "\n")
  end

  t.describe("table detection", function()
    t.it("recognises a separator row", function()
      t.truthy(Table.is_separator("|---|---|"))
      t.truthy(Table.is_separator("| :--- | :---: | ---: |"))
      t.truthy(Table.is_separator("|---|"))
    end)

    t.it("rejects non-separators", function()
      t.falsy(Table.is_separator("| a | b |"))
      t.falsy(Table.is_separator("---"))
      t.falsy(Table.is_separator("| --- | x |"))
      t.falsy(Table.is_separator(""))
    end)

    t.it("needs a header and a separator to be a table", function()
      t.truthy(Table.is_table({ "| a | b |", "|---|---|" }))
      t.falsy(Table.is_table({ "| a | b |" }))
      t.falsy(Table.is_table({ "| a | b |", "| 1 | 2 |" }))
    end)
  end)

  t.describe("cell splitting", function()
    t.it("splits a plain row", function()
      t.eq({ "a", "b", "c" }, Table.split_cells("| a | b | c |"))
    end)

    t.it("trims cell whitespace", function()
      t.eq({ "a", "b" }, Table.split_cells("|   a   |   b   |"))
    end)

    t.it("honours an escaped pipe", function()
      t.eq({ "a|b", "c" }, Table.split_cells("| a\\|b | c |"))
    end)

    t.it("keeps empty cells", function()
      t.eq({ "a", "", "c" }, Table.split_cells("| a |  | c |"))
    end)
  end)

  t.describe("alignment parsing", function()
    t.it("reads every alignment form", function()
      t.eq({ "left", "center", "right", "left" }, Table.alignments("| --- | :---: | ---: | --- |"))
    end)
  end)

  t.describe("table rendering", function()
    t.it("draws a header, a rule and the body", function()
      local lines = render("| Name | Value |\n|---|---|\n| alpha | 1 |\n| beta | 2 |")
      local out = texts(lines)
      local body = table.concat(out, "\n")
      t.truthy(body:find("Name", 1, true), "header missing")
      t.truthy(body:find("├", 1, true), "header rule missing")
      t.truthy(body:find("alpha", 1, true))
      t.truthy(body:find("beta", 1, true))
      -- The assistant glyph gets its own line so the table columns stay aligned.
      t.eq(false, out[1]:find("Name", 1, true) ~= nil, "the table must not start on the icon line")
    end)

    t.it("paints no background", function()
      -- A table is text, not a surface; it must read like the prose around it.
      local lines = render("| a | b |\n|---|---|\n| 1 | 2 |")
      for _, line in ipairs(lines) do
        if line.table then
          t.eq(nil, line.bg, "table rows must not carry a background")
        end
      end
    end)

    t.it("aligns vertical borders with rule junctions at every wrapped row", function()
      local glyphs = {
        ["│"] = true,
        ["┌"] = true,
        ["┬"] = true,
        ["┐"] = true,
        ["├"] = true,
        ["┼"] = true,
        ["┤"] = true,
        ["└"] = true,
        ["┴"] = true,
        ["┘"] = true,
      }
      for _, width in ipairs({ 32, 45, 68, 90 }) do
        local lines = render(
          "| 场景 | 行为 | 验证 |\n|---|:---:|---:|\n"
            .. "| **单 buffer，保存** | `enew() + delete` → nvim 继续运行 | ✅ [存活](https://example.test) |",
          width
        )
        local expected
        for _, line in ipairs(lines) do
          if line.table then
            local positions = {}
            for i = 1, #line.text do
              if glyphs[line.text:sub(i, i + 2)] then
                positions[#positions + 1] = vim.api.nvim_strwidth(line.text:sub(1, i - 1))
              end
            end
            expected = expected or positions
            t.eq(expected, positions, "border column differs: " .. line.text)
          end
        end
      end
    end)

    t.it("draws a full grid around every row", function()
      local lines = render("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
      local out = texts(lines)
      local borders = {}
      for _, line in ipairs(out) do
        if line:find("─", 1, true) or line:find("│", 1, true) then
          borders[#borders + 1] = line
        end
      end
      -- Top, header, header rule, row, row rule, row, bottom.
      t.eq(7, #borders, "expected a closed grid: " .. table.concat(borders, " / "))
      t.truthy(borders[1]:find("┌", 1, true), "missing top border")
      t.truthy(borders[#borders]:find("└", 1, true), "missing bottom border")
      -- Every grid line must end with a right-hand border character.
      for _, line in ipairs(borders) do
        t.truthy(line:match("[│┐┤┘]$"), "row not closed on the right: " .. line)
      end
    end)

    t.it("uses one highlight group for every border character", function()
      local lines = render("| a | b |\n|---|---|\n| 1 | 2 |")
      for _, line in ipairs(lines) do
        if line.table then
          -- The first segment paints the leading border. Cell styling must
          -- never spill over any of the vertical border glyphs.
          t.eq("AcpTableBorder", line.segments[1].group, "border group missing on: " .. line.text)
        end
      end
    end)

    t.it("never conceals already stripped markup or styles a border as cell text", function()
      local lines = render(
        "| 场景 | 行为 | 验证 |\n|---|---|---|\n"
          .. "| 单 buffer，保存 | `enew() + delete` → 只关 buffer，nvim 继续运行 | ✅ nvim 存活，当前是空 buffer |\n"
          .. "| **未保存修改** | 拒绝关闭 + `vim.notify(WARN)`，不写盘、不丢数据 | [正常](https://example.test/long-url) |",
        68
      )
      local width
      for _, line in ipairs(lines) do
        if line.table then
          width = width or vim.api.nvim_strwidth(line.text)
          t.eq(width, vim.api.nvim_strwidth(line.text), "grid width differs: " .. line.text)
          for _, seg in ipairs(line.segments) do
            t.falsy(seg.conceal, "table markup is already removed from the buffer")
            t.truthy(seg.s >= 0 and seg.e >= seg.s and seg.e <= #line.text, "segment outside rendered row")
          end
          local from = 1
          while true do
            local bar = line.text:find("│", from, true)
            if not bar then
              break
            end
            local painted = false
            for _, seg in ipairs(line.segments) do
              if seg.s < bar - 1 + #"│" and seg.e > bar - 1 then
                t.eq("AcpTableBorder", seg.group, "cell highlight spilled onto a border: " .. line.text)
                painted = true
              end
            end
            t.truthy(painted, "vertical border has no highlight")
            from = bar + #"│"
          end
        end
      end
    end)

    t.it("measures natural column widths using visible cell content", function()
      local marked = Table.render(
        Table.parse({ "| **标题** | `name` |", "|---|---|", "| [内容](https://long.test/url) | `abc` |" }),
        "AcpAssistant",
        80
      )
      local plain =
        Table.render(Table.parse({ "| 标题 | name |", "|---|---|", "| 内容 | abc |" }), "AcpAssistant", 80)
      t.eq(texts(plain), texts(marked))
    end)

    t.it("keeps inline styles on the right visible bytes after whitespace wrapping", function()
      local lines = Table.render(
        Table.parse({
          "| 项目 | 内容 |",
          "|---|---|",
          "| a | `alpha bravo charlie delta` **粗体文字** [链接](https://long.test/url) |",
        }),
        "AcpAssistant",
        30
      )
      local code, bold, link = {}, {}, {}
      local groups = { AcpMdCode = code, AcpBold = bold, AcpMdLink = link }
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments) do
          local target = groups[seg.group]
          if target then
            target[#target + 1] = line.text:sub(seg.s + 1, seg.e)
          end
        end
      end
      t.eq("alphabravocharliedelta", table.concat(code):gsub("%s", ""))
      t.eq("粗体文字", table.concat(bold))
      t.eq("链接", table.concat(link))
    end)

    t.it("applies the alignment of each column", function()
      -- Left cell hugs its column's left edge; right cell hugs the right edge.
      local function body_row(lines)
        for _, line in ipairs(lines) do
          if line.table and not line.text:find("├", 1, true) and line.text:find("a", 1, true) then
            return line.text
          end
        end
      end
      local left_row = body_row(render("| h |\n|:--|\n| a |"))
      local right_row = body_row(render("| h |\n|--:|\n| a |"))
      t.truthy(left_row:find(" a ", 1, true), "left-aligned cell should sit at the start: " .. left_row)
      t.truthy(right_row:find(" a │", 1, true), "right-aligned cell should sit at the end: " .. right_row)
    end)

    t.it("pads columns to their widest cell", function()
      local lines = render("| a | b |\n|---|---|\n| longer | x |")
      -- Compare the rule with the body row: the first line carries the assistant
      -- icon prefix, so it is wider by design.
      local rule, body
      for _, line in ipairs(lines) do
        if line.table then
          if line.text:find("├", 1, true) then
            rule = line.text
          else
            body = body or line.text
          end
        end
      end
      t.truthy(rule and body, "table rows missing")
      t.eq(vim.api.nvim_strwidth(rule), vim.api.nvim_strwidth(body))
    end)

    t.it("shrinks to fit a narrow panel", function()
      local lines = render("| a very long column name | another long one |\n|---|---|\n| x | y |", 28)
      for _, line in ipairs(lines) do
        if line.table then
          t.truthy(vim.api.nvim_strwidth(line.text) <= 28, "table row exceeded the panel width: " .. line.text)
        end
      end
    end)

    t.it("wraps long cell text across several rows", function()
      local lines = render("| id | note |\n|---|---|\n| 1 | " .. string.rep("word ", 30) .. " |", 60)
      local body = {}
      for _, line in ipairs(lines) do
        if line.table and not line.text:find("├", 1, true) then
          body[#body + 1] = line.text
        end
      end
      -- Header plus at least two wrapped body rows.
      t.truthy(#body >= 3, "cell text was not wrapped: " .. table.concat(body, " / "))
    end)

    t.it("wraps CJK text without a space to break on", function()
      local cjk = string.rep("内容", 20)
      local lines = render("| a | b |\n|---|---|\n| x | " .. cjk .. " |", 40)
      local row_count = 0
      for _, line in ipairs(lines) do
        if line.table and not line.text:find("├", 1, true) then
          row_count = row_count + 1
        end
      end
      t.truthy(row_count >= 3, "CJK text was not wrapped")
    end)

    t.it("does not split a latin word when it can be avoided", function()
      local lines = render("| a | b |\n|---|---|\n| x | alpha bravo charlie delta echo |", 40)
      local joined = table.concat(texts(lines), "\n")
      -- Every word must appear whole somewhere; no mid-word break.
      for _, word in ipairs({ "alpha", "bravo", "charlie", "delta", "echo" }) do
        t.truthy(joined:find(word, 1, true), word .. " was split across rows")
      end
    end)

    t.it("renders inline markup inside cells", function()
      local lines = render("| a | b |\n|---|---|\n| x | **bold** and *italic* and `code` |")
      local groups = {}
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          if seg.group and seg.group ~= "AcpTableBorder" and seg.group ~= "AcpTableHead" then
            groups[seg.group] = true
          end
        end
      end
      t.truthy(groups["AcpBold"], "bold missing in a cell")
      t.truthy(groups["AcpItalic"], "italic missing in a cell")
      t.truthy(groups["AcpMdCode"], "inline code missing in a cell")
    end)

    t.it("hides markup delimiters inside cells", function()
      -- Cell text is rebuilt from the visible characters, so the delimiters do
      -- not reach the buffer at all (unlike prose, which conceals them).
      local lines = render("| a |\n|---|\n| **bold** and `code` |")
      local joined = table.concat(texts(lines), "\n")
      t.falsy(joined:find("**", 1, true), "bold delimiters leaked into the table")
      t.falsy(joined:find("`", 1, true), "code delimiters leaked into the table")
      t.truthy(joined:find("bold", 1, true))
      t.truthy(joined:find("code", 1, true))
    end)

    t.it("does not count concealed delimiters when wrapping", function()
      -- A bold word must stay on one line: only its visible width matters.
      local lines = render("| a | b |\n|---|---|\n| x | " .. string.rep("**abcdefgh** ", 5) .. " |", 40)
      local joined = table.concat(texts(lines), "\n")
      t.truthy(joined:find("abcdefgh", 1, true), "bold word lost")
      -- No row may exceed the panel width.
      for _, line in ipairs(lines) do
        if line.table then
          t.truthy(vim.api.nvim_strwidth(line.text) <= 40, "row overflowed: " .. line.text)
        end
      end
    end)

    t.it("still aligns columns when cells carry markup", function()
      local lines = render("| a | b |\n|---|---|\n| **long cell here** | x |")
      local widths = {}
      for _, line in ipairs(lines) do
        if line.table then
          widths[#widths + 1] = vim.api.nvim_strwidth(line.text)
        end
      end
      for i = 2, #widths do
        t.eq(widths[1], widths[i], "rows are not the same width")
      end
    end)

    t.it("keeps every row a single line", function()
      local lines = render("| a | b |\n|---|---|\n| 1 | 2 |")
      for _, line in ipairs(lines) do
        t.falsy(line.text:find("\n"), "table row contains a newline")
      end
    end)

    t.it("leaves prose containing a pipe alone", function()
      local lines = render("some prose\n| not a table\nmore prose")
      t.falsy(joined(lines):find("├", 1, true), "prose should not be drawn as a table")
      t.truthy(joined(lines):find("| not a table", 1, true))
    end)

    t.it("renders a table at the very end of the text", function()
      local lines = render("intro\n\n| a | b |\n|---|---|\n| 1 | 2 |")
      t.truthy(joined(lines):find("├", 1, true), "trailing table was not flushed")
    end)

    t.it("does not treat pipes inside a fence as a table", function()
      local lines = render("```\n| a | b |\n|---|---|\n```")
      t.falsy(joined(lines):find("├", 1, true), "a fenced pipe row must stay code")
    end)

    t.it("pads a short row to the column count", function()
      local lines = render("| a | b | c |\n|---|---|---|\n| 1 |")
      local body
      for _, line in ipairs(lines) do
        if line.table and line.text:find(" 1 ", 1, true) then
          body = line.text
        end
      end
      t.truthy(body, "short row missing")
      -- A missing trailing cell must still produce a bordered, empty column.
      local bars = select(2, body:gsub("│", ""))
      t.eq(4, bars, "short row should be padded to the column count: " .. body)
    end)

    t.it("carries no background when the block is not a table", function()
      local lines = render("just | a | line")
      for _, line in ipairs(lines) do
        t.eq(nil, line.table)
      end
    end)
  end)

  t.describe("streaming tables", function()
    local source = "Intro\n\n| Name | Value |\n|---|---|\n| alpha | **bold** |\n| beta | `code` |\n\nAfter\n"

    t.it("matches fresh layout at every character including completed row boundaries", function()
      local cache = {}
      for i = 1, #source do
        local prefix = source:sub(1, i)
        local streamed = blocks.render_text(prefix, "AcpAssistant", 40, cache)
        local fresh = blocks.render_text(prefix, "AcpAssistant", 40)
        t.eq(fresh, streamed, "incremental layout lost a table row at byte " .. i)
      end
    end)

    t.it("preserves all accumulated rows when source arrives one line at a time", function()
      local cache, prefix = {}, ""
      for line in source:gmatch("[^\n]*\n") do
        prefix = prefix .. line
        t.eq(
          blocks.render_text(prefix, "AcpAssistant", 40),
          blocks.render_text(prefix, "AcpAssistant", 40, cache),
          "completed source rows must not vanish"
        )
      end
      t.truthy(joined(cache.lines):find("alpha", 1, true))
      t.truthy(joined(cache.lines):find("beta", 1, true))
    end)

    t.it("matches fresh layout for CJK character chunks and multiple tables", function()
      local full = "正文\n| **标题** | 内容 |\n|---|---|\n| 中文 | `代码` |\n\n"
        .. "中间\n| a | b |\n|---|---|\n| 链接 | [标签](https://example.test) |\n\n结束"
      local cache, prefix = {}, ""
      for i = 0, vim.fn.strchars(full) - 1 do
        prefix = prefix .. vim.fn.strcharpart(full, i, 1)
        t.eq(
          blocks.render_text(prefix, "AcpAssistant", 35),
          blocks.render_text(prefix, "AcpAssistant", 35, cache),
          "CJK stream differs at character " .. i
        )
      end
    end)

    t.it("reuses a completed table when subsequent prose streams", function()
      local prefix = "Intro\n| a | b |\n|---|---|\n| alpha | beta |\n\n"
      local cache = {}
      blocks.render_text(prefix, "AcpAssistant", 40, cache)
      local stable_rule = cache.lines[2]
      local calls, original = 0, Table.render
      Table.render = function(...)
        calls = calls + 1
        return original(...)
      end
      local ok, err = pcall(function()
        for i = 1, 20 do
          prefix = prefix .. "x"
          blocks.render_text(prefix, "AcpAssistant", 40, cache)
        end
      end)
      Table.render = original
      if not ok then
        error(err)
      end
      t.eq(0, calls, "a closed table should stay in the stable prefix")
      t.truthy(stable_rule == cache.lines[2])
    end)

    t.it("survives JSON null fields in tool diffs", function()
      local Chat = require("acp.ui.chat")
      local cfg = require("acp.config").defaults
      local session = state.new("nil-diff", "/tmp")
      session:track_changes()
      session:append({
        id = "tool",
        kind = "tool",
        tool_kind = "edit",
        title = "Write",
        status = "completed",
        content = {
          { type = "diff", path = "/tmp/new.lua", oldText = vim.NIL, newText = "local a = 1\n" },
          { type = "diff", path = "/tmp/old.lua", oldText = "gone\n", newText = vim.NIL },
        },
      })
      local chat = Chat.new({ config = cfg })
      local ok, err = pcall(function()
        chat:set_session(session)
        chat:render()
        session.blocks[1].expanded = true
        session:touch(session.blocks[1], false)
        chat:render()
      end)
      chat:destroy()
      if not ok then
        error(err, 0)
      end
    end)

    t.it("matches a fresh transcript and extmarks as a mixed CJK table grows", function()
      local Chat = require("acp.ui.chat")
      local cfg = require("acp.config").defaults
      local session = state.new("stream-table", "/proj")
      session:track_changes()
      local incremental, fresh = Chat.new({ config = cfg }), Chat.new({ config = cfg })
      incremental.width, fresh.width = 45, 45
      incremental:set_session(session)
      local chunks = {
        "| 场景 | 行为 | 验证 |\n",
        "|---|---|---|\n",
        "| 单 buffer，保存 | `enew()",
        " + delete` → 只关 buffer，nvim 继续运行 | ✅ nvim 存活 |\n",
        "| 未保存修改 | **拒绝关闭** + `vim.notify(WARN)` | [正常](https://test.local) |\n",
        "\n表格之后的正文\n",
      }
      local function marks(chat)
        local out = {}
        for _, mark in
          ipairs(
            vim.api.nvim_buf_get_extmarks(chat.buf, vim.api.nvim_get_namespaces().acp_chat, 0, -1, { details = true })
          )
        do
          local d = mark[4]
          out[#out + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group, d.conceal }
        end
        table.sort(out, function(a, b)
          return vim.inspect(a) < vim.inspect(b)
        end)
        return out
      end
      local ok, err = pcall(function()
        for _, chunk in ipairs(chunks) do
          session:append_text("agent", chunk, "table")
          incremental:render()
          -- Clear the reference so it cannot reuse a previous layout or marks.
          fresh:set_session(nil)
          fresh:set_session(session)
          t.eq(fresh:transcript(), incremental:transcript())
          t.eq(fresh.meta, incremental.meta)
          t.eq(marks(fresh), marks(incremental))
        end
      end)
      incremental:destroy()
      fresh:destroy()
      if not ok then
        error(err, 0)
      end
    end)
  end)
end
