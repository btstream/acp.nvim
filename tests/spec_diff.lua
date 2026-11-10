-- Diff extraction and rendering for file-modifying tool calls.
return function(t)
  local diff = require("acp.ui.diff")
  local state = require("acp.session.state")
  local blocks = require("acp.ui.blocks")

  local function tool(over)
    local block = {
      id = "t",
      kind = "tool",
      text = "",
      status = "completed",
      expanded = true,
    }
    for k, v in pairs(over or {}) do
      block[k] = v
    end
    return block
  end

  local function text_of(lines)
    local out = {}
    for _, line in ipairs(lines) do
      out[#out + 1] = line.text
    end
    return table.concat(out, "\n")
  end

  local OLD = "local a = 1\nlocal b = 2\n\nlocal function add(x, y)\n  return x + y\nend\n"
  local NEW = "local a = 1\nlocal b = 2\n\n-- Adds two numbers\nlocal function sum(x, y)\n  return x + y\nend\n"

  t.describe("diff extraction", function()
    t.it("reads the authoritative diff content", function()
      local block = tool({
        tool_kind = "edit",
        content = {
          { type = "content", content = { type = "text", text = "Edited f.lua" } },
          { type = "diff", path = "/proj/f.lua", oldText = OLD, newText = NEW },
        },
      })
      local entries = diff.from_block(block)
      t.eq(1, #entries)
      t.eq("/proj/f.lua", entries[1].path)
      t.eq(OLD, entries[1].oldText)
      t.eq(NEW, entries[1].newText)
      t.falsy(entries[1].synthetic, "an authoritative diff must not be marked synthetic")
    end)

    t.it("derives a live diff from edit input", function()
      local block = tool({ tool_kind = "edit", raw_input = { path = "/proj/f.lua", oldString = "a", newString = "b" } })
      local entries = diff.from_block(block)
      t.eq(1, #entries)
      t.eq("a", entries[1].oldText)
      t.eq("b", entries[1].newText)
      t.truthy(entries[1].synthetic)
    end)

    t.it("derives an all-additions preview from write input", function()
      local block = tool({ tool_kind = "write", raw_input = { path = "/proj/new.txt", content = "one\ntwo\n" } })
      local entries = diff.from_block(block)
      t.eq(1, #entries)
      t.eq("", entries[1].oldText)
      t.eq("one\ntwo\n", entries[1].newText)
      t.truthy(entries[1].synthetic)
    end)

    t.it("prefers the authoritative content over the input", function()
      local block = tool({
        tool_kind = "write",
        raw_input = { path = "/proj/f.lua", content = "live" },
        content = { { type = "diff", path = "/proj/f.lua", newText = "authoritative" } },
      })
      local entries = diff.from_block(block)
      t.eq("authoritative", entries[1].newText)
      t.falsy(entries[1].synthetic)
    end)

    t.it("returns nothing for tools that do not edit files", function()
      t.eq(0, #diff.from_block(tool({ tool_kind = "read", raw_input = { path = "/proj/f.lua" } })))
      t.eq(0, #diff.from_block(tool({ tool_kind = "execute", raw_input = { command = "ls" } })))
      t.eq(0, #diff.from_block(tool({})))
    end)

    t.it("accepts a raw unified patch", function()
      local patch = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n"
      local block = tool({ tool_kind = "patch", raw_input = { path = "/proj/f.lua", patchText = patch } })
      local entries = diff.from_block(block)
      t.eq(1, #entries)
      t.eq(patch, entries[1].patch)
    end)

    t.it("renders nothing when both sides are identical", function()
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = "a\nb\n", newText = "a\nb\n" } })
      t.eq(0, #lines, "an unchanged edit should not open a body")
    end)

    t.it("still renders a write of the same content", function()
      -- A write reports the new file wholesale; "no change" is not knowable
      -- without reading the old one, and showing the content is more useful.
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = "", newText = "a\nb\n", synthetic = true } })
      local added = 0
      for _, line in ipairs(lines) do
        if line.bg == "AcpDiffAdd" then
          added = added + 1
        end
      end
      t.eq(2, added)
    end)
  end)

  t.describe("diff rows", function()
    t.it("marks additions and removals", function()
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = "a\nb\n", newText = "a\nB\n" } })
      local text = text_of(lines)
      t.match("\n%+ B", text)
      t.match("\n%- b", text)
    end)

    t.it("renders context rows without a background", function()
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = OLD, newText = NEW } })
      local context_rows = 0
      for _, line in ipairs(lines) do
        if line.text:find("^  local a", 1) then
          context_rows = context_rows + 1
          t.eq(nil, line.bg, "context rows must inherit the card background")
        end
      end
      t.truthy(context_rows > 0, "no context rows were rendered")
    end)

    t.it("paints added rows green and removed rows red", function()
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = "a\n", newText = "b\n" } })
      local add, remove
      for _, line in ipairs(lines) do
        if line.text:find("^%+ ") then
          add = line
        elseif line.text:find("^%- ") then
          remove = line
        end
      end
      t.truthy(add and remove, "both sides of the change are missing")
      t.eq("AcpDiffAdd", add.bg)
      t.eq("AcpDiffDelete", remove.bg)
      -- The sign is not part of the body colour so a theme can colour it alone.
      t.eq("AcpDiffAddSign", add.segments[1].group)
      t.eq("AcpDiffRemoveSign", remove.segments[1].group)
    end)

    t.it("hides the hunk header when there is only one hunk", function()
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = OLD, newText = NEW } })
      for _, line in ipairs(lines) do
        t.falsy(line.text:find("^@@", 1), "a single hunk should not print @@")
      end
    end)

    t.it("keeps the hunk header when there are several", function()
      local rows = {}
      for i = 1, 40 do
        rows[i] = "line " .. i
      end
      local old = table.concat(rows, "\n") .. "\n"
      rows[3], rows[30] = "CHANGED 3", "CHANGED 30"
      local new = table.concat(rows, "\n") .. "\n"
      local lines = diff.lines({ { path = "/proj/f.lua", oldText = old, newText = new } })
      local hunks = 0
      for _, line in ipairs(lines) do
        if line.text:find("^@@", 1) then
          hunks = hunks + 1
          t.eq("AcpDiffHunk", line.segments[1].group)
        end
      end
      t.eq(2, hunks, "both hunks should be separated")
    end)

    t.it("respects the configured context", function()
      local rows = {}
      for i = 1, 20 do
        rows[i] = "line " .. i
      end
      local old = table.concat(rows, "\n") .. "\n"
      rows[10] = "CHANGED"
      local new = table.concat(rows, "\n") .. "\n"

      local function context_lines(ctx)
        local count = 0
        for _, line in ipairs(diff.lines({ { path = "f", oldText = old, newText = new } }, { context = ctx })) do
          if line.text:find("^  line") then
            count = count + 1
          end
        end
        return count
      end
      t.eq(2, context_lines(1))
      t.eq(6, context_lines(3))
    end)

    t.it("notes a missing trailing newline", function()
      local lines = diff.lines({ { path = "f", oldText = "a\nb", newText = "a\nb\n" } })
      local found = false
      for _, line in ipairs(lines) do
        if line.text:find("No newline at end of file", 1, true) then
          found = true
          t.eq("AcpDiffMeta", line.segments[1].group)
        end
      end
      t.truthy(found, "the missing-newline marker is missing")
    end)

    t.it("caps the number of rendered rows", function()
      local rows = {}
      for i = 1, 500 do
        rows[i] = "line " .. i
      end
      local new = table.concat(rows, "\n") .. "\n"
      local lines = diff.lines({ { path = "f", oldText = "", newText = new } }, { max_lines = 20, summary = "f" })
      local visible, summary = 0, nil
      for _, line in ipairs(lines) do
        if line.text:find("more lines", 1, true) then
          summary = line
        else
          visible = visible + 1
        end
      end
      t.eq(20, visible, "the cap should bound the body")
      t.truthy(summary, "the omitted rows need a summary")
      t.match("48%d more lines", summary.text)
      t.eq("AcpDiffMeta", summary.segments[1].group)
    end)

    t.it("refuses to diff an oversized payload", function()
      local huge = string.rep("x\n", 1000)
      local lines = diff.lines({ { path = "f", oldText = "", newText = huge } }, { max_bytes = 1024 })
      t.match("diff too large", text_of(lines))
      t.falsy(lines[#lines].bg, "the notice is not a coloured diff row")
    end)

    t.it("labels a file header when there are several files", function()
      local lines = diff.lines({
        { path = "/proj/a.lua", oldText = "a\n", newText = "b\n" },
        { path = "/proj/b.lua", oldText = "c\n", newText = "d\n" },
      })
      local text = text_of(lines)
      t.match("/proj/a%.lua", text)
      t.match("/proj/b%.lua", text)
    end)

    t.it("labels a derived write as new content", function()
      local lines = diff.lines({ { path = "/proj/notes.txt", oldText = "", newText = "x\n", synthetic = true } })
      t.match("notes%.txt %(new content%)", text_of(lines))
    end)

    t.it("uses the session directory for a shorter path", function()
      local lines = diff.lines({ { path = "/proj/src/a.lua", oldText = "a\n", newText = "b\n" } }, { cwd = "/proj" })
      t.match("src/a%.lua", text_of(lines))
    end)

    t.it("skips the file header when the summary already names it", function()
      local lines = diff.lines({
        { path = "/proj/src/a.lua", oldText = "a\n", newText = "b\n" },
      }, { cwd = "/proj", summary = "Edited a.lua (1 replacement)" })
      t.falsy(text_of(lines):find("src/a%.lua"), "the path is already in the summary")
    end)
  end)

  t.describe("diff syntax highlighting", function()
    local diff_hl = require("acp.ui.diff_hl")
    local CodeHL = require("acp.ui.code_hl")

    local function groups_of(lines)
      local groups = {}
      for _, line in ipairs(lines) do
        for _, seg in ipairs(line.segments or {}) do
          if type(seg.group) == "string" and seg.group:sub(1, 1) == "@" then
            groups[seg.group] = true
          end
        end
      end
      return groups
    end

    t.it("resolves a language from the file path", function()
      t.eq("lua", diff_hl.language("/proj/src/a.lua"))
      t.eq("python", diff_hl.language("/proj/a.py"))
      -- A filetype is not a parser name; the fence aliases are reused.
      t.eq("bash", diff_hl.language("/proj/run.sh"))
      t.eq(nil, diff_hl.language("/proj/a.unknownext"))
      t.eq(nil, diff_hl.language(""))
      t.eq(nil, diff_hl.language(nil))
    end)

    t.it("colours both sides of a lua diff", function()
      local lines = diff.lines({
        { path = "/proj/sample.lua", oldText = "local a = 1\n", newText = "-- note\nlocal b = 2\n" },
      })
      local groups = groups_of(lines)
      t.truthy(groups["@keyword"] or groups["@keyword.lua"], "no keyword colour")
      t.truthy(groups["@comment"] or groups["@comment.lua"], "no comment colour")
    end)

    t.it("colours context rows from both sides", function()
      local lines = diff.lines({
        {
          path = "/proj/sample.lua",
          oldText = "local keep = 1\nlocal a = 1\n",
          newText = "local keep = 1\nlocal b = 2\n",
        },
      })
      -- "local keep = 1" is context: it must be coloured even though it is not
      -- an added or removed line.
      local found = false
      for _, line in ipairs(lines) do
        if line.text:find("local keep", 1, true) then
          for _, seg in ipairs(line.segments or {}) do
            if type(seg.group) == "string" and seg.group:match("^@keyword") then
              found = true
            end
          end
        end
      end
      t.truthy(found, "a context row was left plain")
    end)

    t.it("skips the sign column and the card margin", function()
      local lines = diff.lines({ { path = "/proj/a.lua", oldText = "", newText = "local x = 1\n" } })
      local added
      for _, line in ipairs(lines) do
        if line.bg == "AcpDiffAdd" then
          added = line
        end
      end
      t.truthy(added)
      -- The diff row is "+ local x = 1" and the syntax offset must skip the
      -- two-byte sign prefix, so the keyword starts after it.
      local keyword
      for _, seg in ipairs(added.segments or {}) do
        if seg.group and seg.group:match("^@keyword") then
          keyword = seg
        end
      end
      t.truthy(keyword, "the added row lost its colour")
      t.eq("local", added.text:sub(keyword.s + 1, keyword.e))
    end)

    t.it("stays plain for an unknown file type", function()
      local lines = diff.lines({ { path = "/proj/a.unknownext", oldText = "a\n", newText = "b\n" } })
      t.eq(0, vim.tbl_count(groups_of(lines)), "an unknown type must not invent colours")
      -- The diff itself is still there.
      local text = text_of(lines)
      t.match("%- a", text)
      t.match("%+ b", text)
    end)

    t.it("stays plain when highlighting is disabled", function()
      local lines = diff.lines(
        { { path = "/proj/a.lua", oldText = "local a = 1\n", newText = "local b = 1\n" } },
        { syntax = false }
      )
      t.eq(0, vim.tbl_count(groups_of(lines)))
    end)

    t.it("stays plain past the row ceiling", function()
      local rows = {}
      for i = 1, 100 do
        rows[i] = "local v" .. i .. " = " .. i
      end
      local new = table.concat(rows, "\n") .. "\n"
      local lines = diff.lines(
        { { path = "/proj/a.lua", oldText = "", newText = new } },
        { max_rows = 10, max_lines = 200 }
      )
      t.eq(0, vim.tbl_count(groups_of(lines)), "a huge diff should not be parsed")
    end)

    t.it("keeps the diff background under the syntax colours", function()
      local lines = diff.lines({
        { path = "/proj/a.lua", oldText = "local a = 1\n", newText = "local b = 1\n" },
      })
      local checked = 0
      for _, line in ipairs(lines) do
        if line.bg == "AcpDiffAdd" or line.bg == "AcpDiffDelete" then
          checked = checked + 1
          -- The line-wide background lives in its own namespace; syntax and the
          -- sign are inline segments on top of it, so all three must coexist.
          local sign, syntax = false, false
          for _, seg in ipairs(line.segments or {}) do
            if seg.group == "AcpDiffAddSign" or seg.group == "AcpDiffRemoveSign" then
              sign = true
            elseif type(seg.group) == "string" and seg.group:sub(1, 1) == "@" then
              syntax = true
            end
          end
          t.truthy(sign, "the row lost its sign segment: " .. line.text)
          t.truthy(syntax, "the row lost its syntax segments: " .. line.text)
        end
      end
      t.truthy(checked > 0, "no coloured diff rows")
    end)

    t.it("reuses the syntax cache across renders", function()
      CodeHL.clear_cache()
      local original, calls = vim.treesitter.get_string_parser, 0
      vim.treesitter.get_string_parser = function(...)
        calls = calls + 1
        return original(...)
      end
      local ok, err = pcall(function()
        local entries = { { path = "/proj/cache.lua", oldText = "local a = 1\n", newText = "local b = 1\n" } }
        diff.lines(entries)
        local first = calls
        t.truthy(first > 0, "nothing was parsed")
        diff.lines(entries)
        t.eq(first, calls, "the same diff was parsed twice")
      end)
      vim.treesitter.get_string_parser = original
      CodeHL.clear_cache()
      if not ok then
        error(err)
      end
    end)

    t.it("parses each file of a patch separately", function()
      local lines = diff.lines({
        { path = "/proj/a.lua", oldText = "local a = 1\n", newText = "local b = 1\n" },
        { path = "/proj/a.py", oldText = "x = 1\n", newText = "x = 2\n" },
      })
      -- Lua's and Python's captures must both be present; one language would
      -- mean the sections were merged.
      local groups = groups_of(lines)
      local saw_python = false
      for name in pairs(groups) do
        if name:find("%.python$") or name == "@variable" then
          saw_python = true
        end
      end
      t.truthy(groups["@keyword"] or groups["@keyword.lua"], "the lua file lost its colour")
      t.truthy(saw_python, "the python file was not parsed")
    end)
  end)

  t.describe("diff card", function()
    local function render(block, over)
      local s = state.new("s", "/proj")
      s:append(block)
      return blocks.render_block(
        s.blocks[1],
        vim.tbl_extend("force", { icons = blocks.icon_set(true), width = 70, cwd = "/proj" }, over or {})
      )
    end

    t.it("draws the diff inside the expanded card", function()
      local lines = render({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "completed",
        expanded = true,
        detail = "Edited f.lua (1 replacement)",
        content = { { type = "diff", path = "/proj/f.lua", oldText = OLD, newText = NEW } },
      })
      local text = text_of(lines)
      t.match("Edited f%.lua", text)
      t.match("%+ local function sum", text)
      t.match("%- local function add", text)

      -- Diff rows keep their own background despite the card surface.
      local add
      for _, line in ipairs(lines) do
        if line.text:find("^  %+ ") then
          add = line
        end
      end
      t.truthy(add, "no added row")
      t.eq("AcpDiffAdd", add.bg)
    end)

    t.it("keeps the diff out of a collapsed card", function()
      local lines = render({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "completed",
        expanded = false,
        detail = "Edited f.lua",
        content = { { type = "diff", path = "/proj/f.lua", oldText = OLD, newText = NEW } },
      })
      t.falsy(text_of(lines):find("%+ local function sum"), "a collapsed card showed the diff")
    end)

    t.it("does not repeat the location list under a diff", function()
      local lines = render({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "completed",
        expanded = true,
        content = { { type = "diff", path = "/proj/f.lua", oldText = OLD, newText = NEW } },
        locations = { { path = "/proj/f.lua", line = 4 } },
      })
      local locations = 0
      for _, line in ipairs(lines) do
        if line.location then
          locations = locations + 1
        end
      end
      t.eq(0, locations, "the diff header already shows the file")
    end)

    t.it("separates the summary from the diff", function()
      local lines = render({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "completed",
        expanded = true,
        detail = "Edited f.lua",
        content = { { type = "diff", path = "/proj/f.lua", oldText = OLD, newText = NEW } },
      })
      local rule
      for _, line in ipairs(lines) do
        if line.text:find("^  ──") then
          rule = line
        end
      end
      t.truthy(rule, "the summary is not separated from the diff")
      t.eq("AcpDiffMeta", rule.segments[1].group)
    end)

    t.it("renders a live diff from the tool input", function()
      local lines = render({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "in_progress",
        expanded = true,
        raw_input = { path = "/proj/f.lua", oldString = "old line", newString = "new line" },
      })
      local text = text_of(lines)
      t.match("%- old line", text)
      t.match("%+ new line", text)
    end)

    t.it("reuses the cached diff for an unrelated change", function()
      local s = state.new("s", "/proj")
      s:append({
        id = "t",
        kind = "tool",
        tool_kind = "edit",
        status = "completed",
        expanded = true,
        content = { { type = "diff", path = "/proj/f.lua", oldText = OLD, newText = NEW } },
      })
      local block = s.blocks[1]
      local ctx = { icons = blocks.icon_set(true), width = 70, cwd = "/proj" }
      blocks.render_block(block, ctx)
      local cached = block._diff_cache
      t.truthy(cached, "the diff was not cached")

      block.status = "completed"
      blocks.render_block(block, ctx)
      t.truthy(block._diff_cache == cached, "the diff was recomputed for an unchanged payload")
    end)
  end)
end
