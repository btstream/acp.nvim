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
      local rows = 0
      for _, line in ipairs(lines) do
        if line.table then
          rows = rows + 1
          t.eq(nil, line.bg, "table rows must not carry a background")
        end
      end
      t.eq(3, rows, "header, rule and body row should be present")
    end)

    t.it("uses one highlight group for every border character", function()
      local lines = render("| a | b |\n|---|---|\n| 1 | 2 |")
      for _, line in ipairs(lines) do
        if line.table then
          -- The whole row is covered by the border group first, so the frame is
          -- a single tone; cell groups are layered on top.
          t.eq("AcpTableBorder", line.segments[1].group, "border group missing on: " .. line.text)
        end
      end
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
end
