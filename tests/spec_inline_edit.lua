return function(t)
  local Config = require("acp.config")
  local selection = require("acp.inline.selection")
  local result = require("acp.inline.result")
  local copy = require("acp.inline.copy")
  local apply = require("acp.inline.apply")
  local review = require("acp.inline.review")
  local diff_session = require("acp.inline.diff_session")

  local function cfg(over)
    return Config.validate(Config.merge(Config.defaults, over or {}))
  end

  local function win_with(lines, ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if ft then
      vim.bo[buf].filetype = ft
    end
    local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 60, height = 8 })
    return win, buf
  end

  local function pos(row, col)
    return { 0, row + 1, col, 0 }
  end

  local function wait_close(buf)
    vim.wait(500, function()
      return not require("acp.inline.diff_session").active(buf)
    end, 10)
  end

  t.describe("inline selection", function()
    t.it("expands a character selection to whole lines and merges touching ranges", function()
      local win, buf = win_with({ "one two", "three four", "five six" })
      local c = cfg()
      local got = assert(selection.capture(win, c, { mode = "v", pos1 = pos(0, 4), pos2 = pos(1, 2) }))
      t.eq(1, #got.ranges)
      t.eq(
        { 0, 0, 1, 10 },
        { got.ranges[1].start_row, got.ranges[1].start_col, got.ranges[1].end_row, got.ranges[1].end_col }
      )
      t.eq("one two\nthree four", got.text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("keeps exact columns when expansion is off, including reversed ranges", function()
      local win, buf = win_with({ "one two" })
      local c = cfg({ inline = { expand_selection = false } })
      local got = assert(selection.capture(win, c, { mode = "v", pos1 = pos(0, 7), pos2 = pos(0, 5) }))
      t.eq(4, got.ranges[1].start_col)
      t.eq(7, got.ranges[1].end_col)
      t.eq("two", got.text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("captures a block as one range per row", function()
      local win, buf = win_with({ "abcdef", "ghijkl", "mnopqr" })
      local got = assert(selection.capture(win, cfg(), { mode = "\22", pos1 = pos(0, 2), pos2 = pos(2, 4) }))
      t.eq(3, #got.ranges)
      t.eq("bcd\nhij\nnop", got.text)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("uses a bounded whole-line window when scope is context", function()
      local lines = {}
      for i = 1, 60 do
        lines[i] = "line " .. i
      end
      local win, buf = win_with(lines)
      vim.api.nvim_win_set_cursor(win, { 30, 0 })
      local got = assert(selection.capture(win, cfg({ inline = { scope = "context" } })))
      t.truthy(got.ranges[1].start_row < 29)
      t.truthy(got.ranges[1].end_row > 29)
      t.eq(0, got.ranges[1].start_col)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("keeps cursor mode unrestricted instead of an insertion point", function()
      local win, buf = win_with({ "abc" })
      vim.api.nvim_win_set_cursor(win, { 1, 1 })
      local c = cfg()
      local got = assert(selection.capture(win, c))
      t.truthy(got.free)
      t.falsy(got.linewise)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline result filtering", function()
    t.it("keeps hunks inside the range and reports the rest", function()
      local original = { "a", "b", "c", "d", "e" }
      local edited = { "a", "B", "c", "D", "e" }
      local sel = { ranges = { { start_row = 1, start_col = 0, end_row = 2, end_col = 1 } } }
      local hunks = result.hunks(original, edited)
      local kept, dropped = result.keep_editable(sel, hunks)
      t.eq(2, #hunks)
      t.eq(1, #kept)
      t.eq(1, dropped)
      t.eq({ "a", "B", "c", "d", "e" }, result.apply_hunks(original, kept))
    end)

    t.it("accepts an insertion exactly at the range start and end", function()
      local sel = { ranges = { { start_row = 1, start_col = 0, end_row = 2, end_col = 1 } } }
      local start = result.hunks({ "a", "b" }, { "a", "x", "b" })[1]
      local finish = result.hunks({ "a", "b" }, { "a", "b", "x" })[1]
      t.eq(1, #result.keep_editable(sel, { start }))
      t.eq(1, #result.keep_editable(sel, { finish }))
    end)

    t.it("detects buffer changes outside the edit", function()
      local win, buf = win_with({ "a" })
      local sel = assert(selection.capture(win, cfg(), { mode = "v", pos1 = pos(0, 1), pos2 = pos(0, 1) }))
      t.truthy(result.verify(sel))
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "b" })
      local ok, reason = result.verify(sel)
      t.falsy(ok)
      t.match("changed", reason)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline copy", function()
    t.it("writes a private sibling copy, reads it back and removes it", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/file.lua"
      local fh = assert(io.open(path, "wb"))
      fh:write("one\ntwo\n")
      fh:close()
      local win, buf = win_with({ "one", "two" }, "lua")
      vim.api.nvim_buf_set_name(buf, path)
      local sel = assert(selection.capture(win, cfg(), { mode = "v", pos1 = pos(0, 1), pos2 = pos(0, 1) }))
      local made = assert(copy.create(sel, cfg()))
      t.truthy(vim.startswith(vim.fs.basename(made), ".acp-inline-"))
      t.eq(vim.fs.dirname(made), dir)
      t.eq({ "one", "two" }, copy.read(made))
      t.truthy(copy.is_copy_path(made, made))
      t.falsy(copy.is_copy_path(path, made))
      t.falsy(copy.is_copy_path(dir .. "/.acp-inline-unrelated.lua", made))
      local stat = vim.uv.fs_stat(made)
      t.eq(384, stat.mode % 512)
      copy.remove(made)
      t.eq(nil, vim.uv.fs_stat(made))
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline apply", function()
    t.it("writes one undoable change and puts the cursor on it", function()
      local win, buf = win_with({ "a", "b", "c" })
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
      t.truthy(apply.write(buf, { "a", "B", "c" }, 1))
      t.eq({ 2, 0 }, vim.api.nvim_win_get_cursor(win))
      vim.cmd("silent undo")
      t.eq({ "a", "b", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline diff session", function()
    t.it("accepts and rejects independently, then collapses to one undo", function()
      local _, buf = win_with({ "a", "b", "c", "d" })
      local finished
      local ok = diff_session.open({
        bufnr = buf,
        lines = { "A", "b", "c", "D" },
        on_finish = function(accepted, total)
          finished = { accepted, total }
        end,
      })
      t.truthy(ok)
      t.eq({ "a", "b", "c", "d" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      local view = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      -- Whole-file two-column view: unchanged lines on both sides.
      t.match("1%s+- a", view)
      t.match("│%s+1%s+%+ A", view)
      t.match("2%s+b", view)
      -- `advance` defaults to false, so navigation is explicit.
      vim.api.nvim_feedkeys("gr", "x", false)
      t.eq({ "a", "b", "c", "d" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_feedkeys("]c", "x", false)
      vim.api.nvim_feedkeys("ga", "x", false)
      t.eq({ "a", "b", "c", "D" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      t.eq({ 1, 2 }, finished)
      vim.cmd("silent undo")
      t.eq({ "a", "b", "c", "d" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("chat selection attachments", function()
    t.it("links to the line range and keeps its place in the prompt", function()
      local context = require("acp.context")
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/file.lua"
      local fh = assert(io.open(path, "wb"))
      fh:write("alpha\nbeta\ngamma\n")
      fh:close()
      local win, buf = win_with({ "alpha", "beta", "gamma" }, "lua")
      vim.api.nvim_buf_set_name(buf, path)
      vim.bo[buf].buftype = ""
      vim.fn.setpos("'<", { 0, 2, 1, 0 })
      vim.fn.setpos("'>", { 0, 2, 4, 0 })
      local att, err = context.selection(cfg(), { bufnr = buf, embedded = false })
      t.eq(nil, err)
      t.eq("resource_link", att.block.type)
      t.match("#L2:2$", att.block.uri)
      t.eq("beta", att.text)
      local input = require("acp.ui.input").new({ config = cfg() })
      input:restore("before after")
      vim.api.nvim_win_set_cursor(win, { 1, 6 })
      input:add_attachment(att, { 0, 6 })
      t.eq("before[file.lua:2-2] after", vim.api.nvim_buf_get_lines(input.buf, 0, 1, false)[1])
      t.eq("before after", input:text())
      local blocks = context.to_prompt(input:text(), input.attachments, cfg())
      t.eq("text", blocks[1].type)
      t.eq("before", blocks[1].text)
      t.eq("resource_link", blocks[2].type)
      t.eq("text", blocks[3].type)
      t.eq(" after", blocks[3].text)
      input:destroy()
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("uses the current line when there is no visual marks", function()
      local context = require("acp.context")
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/file.lua"
      local fh = assert(io.open(path, "wb"))
      fh:write("alpha\nbeta\n")
      fh:close()
      local _, buf = win_with({ "alpha", "beta" }, "lua")
      vim.api.nvim_buf_set_name(buf, path)
      vim.bo[buf].buftype = ""
      vim.fn.setpos("'<", { 0, 0, 0, 0 })
      vim.fn.setpos("'>", { 0, 0, 0, 0 })
      local att, err = context.selection(cfg(), { bufnr = buf, line = 2, include_current_line = true })
      t.eq(nil, err)
      t.eq("beta", att.text)
      local _, problem = context.selection(cfg(), { bufnr = buf, line = 2 })
      t.match("no visual selection", problem)
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("embeds the selection when the agent advertises it", function()
      local context = require("acp.context")
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/file.lua"
      vim.fn.writefile({ "alpha" }, path)
      local _, buf = win_with({ "alpha" }, "lua")
      vim.api.nvim_buf_set_name(buf, path)
      vim.bo[buf].buftype = ""
      vim.fn.setpos("'<", { 0, 1, 1, 0 })
      vim.fn.setpos("'>", { 0, 1, 5, 0 })
      local att = assert(context.selection(cfg(), { bufnr = buf, embedded = true }))
      t.eq("resource", att.block.type)
      t.eq("alpha", att.block.resource.text)
      vim.fn.delete(dir, "rf")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline diff edge cases", function()
    t.it("rejects a pure deletion at the start of the buffer", function()
      local win, buf = win_with({ "a", "b", "c" })
      local finished
      assert(diff_session.open({
        bufnr = buf,
        lines = { "b", "c" },
        hunks = { { start_row = 0, end_row = -1, new_lines = {}, original = { "a" } } },
        on_finish = function(accepted, total)
          finished = { accepted, total }
        end,
      }))
      vim.api.nvim_feedkeys(vim.keycode("gr"), "x", false)
      t.eq({ "a", "b", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      t.eq({ 0, 1 }, finished)
      vim.api.nvim_buf_delete(buf, { force = true })
      t.truthy(win)
    end)
  end)

  t.describe("inline permissions", function()
    t.it("allows reads and only edits to the copy", function()
      local inline = require("acp.inline")
      local S = require("acp.controller").state()
      local saved_cfg, saved_client = S.config, S.client
      local chosen
      S.config = cfg()
      S.client = {
        resolve_permission = function(_, _, choice)
          chosen = choice
        end,
      }
      local win, buf = win_with({ "a" })
      local sel = assert(selection.capture(win, S.config))
      local path = assert(copy.create(sel, S.config))
      local invocation = { copy = path, on_status = function() end }
      local options = { { kind = "allow_once", optionId = "a" }, { kind = "reject_once", optionId = "r" } }
      t.truthy(inline.on_permission(invocation, { options = options, tool_call = { kind = "read" } }))
      t.eq("a", chosen)
      inline.on_permission(invocation, {
        options = options,
        tool_call = { kind = "edit", locations = { { path = path } } },
      })
      t.eq("a", chosen)
      inline.on_permission(
        invocation,
        { options = options, tool_call = { kind = "edit", locations = { { path = "/tmp/other.lua" } } } }
      )
      t.eq("r", chosen)
      inline.on_permission(invocation, {
        options = options,
        tool_call = { kind = "edit", locations = { { path = "/tmp/.acp-inline-somebody-else.lua" } } },
      })
      t.eq("r", chosen)
      inline.on_permission(
        invocation,
        { options = { { kind = "allow_always", optionId = "FOREVER" } }, tool_call = { kind = "read" } }
      )
      t.eq(nil, chosen)
      inline.on_permission(invocation, { options = options, tool_call = { kind = "edit" } })
      t.eq("r", chosen)
      S.config.inline.allow_writes = true
      inline.on_permission(invocation, { options = options, tool_call = { kind = "edit" } })
      t.eq("a", chosen)
      S.config.inline.allow_commands = false
      inline.on_permission(invocation, { options = options, tool_call = { kind = "execute" } })
      t.eq("r", chosen)
      S.config, S.client = saved_cfg, saved_client
      copy.remove(path)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline safety regressions", function()
    local function plan(old, new, range, linewise)
      return result.plan({ original = old, ranges = { range }, linewise = linewise }, new)
    end
    t.it("filters other columns on the selected row", function()
      local p = plan({ "abc def ghi" }, { "ABC XYZ GHI" }, { start_row = 0, start_col = 4, end_row = 0, end_col = 7 })
      t.eq({ "abc XYZ ghi" }, p.lines)
      t.truthy(p.dropped > 0)
    end)
    t.it("limits an exact zero-width range to insertion", function()
      local r = { start_row = 0, start_col = 1, end_row = 0, end_col = 1 }
      t.eq({ "aXbc" }, plan({ "abc" }, { "aXbc" }, r).lines)
      t.eq({ "abc" }, plan({ "abc" }, { "aXc" }, r).lines)
    end)
    t.it("applies normal-mode changes anywhere without filtering", function()
      local free = {
        original = { "a", "b", "c" },
        ranges = { { start_row = 1, start_col = 0, end_row = 1, end_col = 0 } },
        free = true,
      }
      local p = result.plan(free, { "A", "b", "C" })
      t.eq({ "A", "b", "C" }, p.lines)
      t.eq(0, p.dropped)
      local inserted = result.plan(free, { "a", "x", "b", "c" })
      t.eq({ "a", "x", "b", "c" }, inserted.lines)
    end)
    t.it("handles insertion into and deletion of empty lines", function()
      local r = { start_row = 0, start_col = 0, end_row = 0, end_col = 0 }
      t.eq({ "hello" }, plan({ "" }, { "hello" }, r).lines)
      r.end_col = 5
      t.eq({ "" }, plan({ "hello" }, { "" }, r).lines)
    end)
    t.it("filters adjacent line replacements independently", function()
      local p = plan(
        { "a", "b", "c" },
        { "A", "B", "C" },
        { start_row = 1, start_col = 0, end_row = 1, end_col = 1 },
        true
      )
      t.eq({ "a", "B", "c" }, p.lines)
      t.eq(2, p.dropped)
    end)
    t.it("keeps UTF-8 character boundaries", function()
      t.eq(
        { "甲新丙" },
        plan({ "甲乙丙" }, { "首新尾" }, { start_row = 0, start_col = 3, end_row = 0, end_col = 6 }).lines
      )
    end)
    t.it("limits rectangular changes to each row's bytes", function()
      local p = result.plan({
        original = { "abc", "def" },
        ranges = {
          { start_row = 0, start_col = 1, end_row = 0, end_col = 2 },
          { start_row = 1, start_col = 1, end_row = 1, end_col = 2 },
        },
      }, { "ABC", "DEF" })
      t.eq({ "aBc", "dEf" }, p.lines)
    end)
    t.it("handles exact multiline insertions", function()
      t.eq(
        { "aX", "Ybc" },
        plan({ "abc" }, { "aX", "Ybc" }, { start_row = 0, start_col = 1, end_row = 0, end_col = 1 }).lines
      )
    end)
    t.it("rejects filename and newline convention changes", function()
      local win, buf = win_with({ "a" })
      local sel = assert(selection.capture(win, cfg()))
      vim.bo[buf].endofline = not sel.eol
      t.falsy(result.verify(sel))
      vim.bo[buf].endofline = sel.eol
      vim.bo[buf].fileformat = "dos"
      t.falsy(result.verify(sel))
      vim.bo[buf].fileformat = sel.fileformat
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname())
      t.falsy(result.verify(sel))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("does not trust a refreshed changedtick", function()
      local win, buf = win_with({ "a" })
      local sel = assert(selection.capture(win, cfg()))
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user edit" })
      sel.changedtick = vim.api.nvim_buf_get_changedtick(buf)
      t.falsy(result.verify(sel))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("preserves edits made during review even when accepting", function()
      local _, buf = win_with({ "a", "b", "c" })
      assert(diff_session.open({ bufnr = buf, lines = { "A", "b", "C" } }))
      vim.api.nvim_feedkeys("ga", "x", false)
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "user edit" })
      vim.api.nvim_feedkeys("g2", "x", false)
      t.truthy(diff_session.active(buf))
      vim.api.nvim_feedkeys("g3", "x", false)
      t.falsy(diff_session.active(buf))
      t.eq({ "a", "user edit", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("rejects review acceptance after newline metadata changes", function()
      local _, buf = win_with({ "a" })
      assert(diff_session.open({ bufnr = buf, lines = { "A" } }))
      vim.bo[buf].endofline = not vim.bo[buf].endofline
      vim.api.nvim_feedkeys("g2", "x", false)
      t.truthy(diff_session.active(buf))
      vim.api.nvim_feedkeys("g3", "x", false)
      t.eq({ "a" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("does not move marks outside changed rows", function()
      local _, buf = win_with({ "a", "b", "c" })
      local ns = vim.api.nvim_create_namespace("inline-regression")
      local mark = vim.api.nvim_buf_set_extmark(buf, ns, 2, 0, {})
      assert(apply.hunks(buf, { "a", "b", "c" }, result.hunks({ "a", "b", "c" }, { "A", "b", "c" })))
      t.eq({ 2, 0 }, vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {}))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("bounds copy reads and rejects binary results", function()
      local win, buf = win_with({ "a" })
      local path = assert(copy.create(assert(selection.capture(win, cfg())), cfg()))
      local f = assert(io.open(path, "wb"))
      f:write(string.rep("x", 2048))
      f:close()
      t.eq(nil, copy.read(path, 1024))
      f = assert(io.open(path, "wb"))
      f:write("a\0b")
      f:close()
      t.eq(nil, copy.read(path))
      copy.remove(path)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline prompt text", function()
    local prompt = require("acp.inline.prompt")
    local function selection(over)
      return vim.tbl_extend("force", {
        original = { "local a = 1", "local b = 2", "local c = 3" },
        ranges = { { start_row = 1, start_col = 0, end_row = 1, end_col = 11 } },
        first = 2,
        last = 2,
        text = "local b = 2",
        linewise = true,
        filetype = "lua",
      }, over or {})
    end
    local function built(sel)
      return prompt.build({
        selection = sel,
        config = cfg(),
        copy = "/tmp/.acp-inline-test.lua",
        prompt = "rename this variable",
      })
    end

    t.it("only constrains a visual selection", function()
      local visual = built(selection())
      t.match("Rewrite only these whole lines", visual)
      t.match("byte column", visual)
      t.match("<selection>", visual)
      local cursor = built(selection({
        free = true,
        linewise = false,
        text = "",
        ranges = {
          { start_row = 1, start_col = 4, end_row = 1, end_col = 4 },
        },
      }))
      t.falsy(cursor:find("INSERT ONLY", 1, true))
      t.falsy(cursor:find("through line", 1, true))
      t.falsy(cursor:find("Out-of-range", 1, true))
      t.falsy(cursor:find("<selection>", 1, true))
      t.match("No selection", cursor)
      t.match("line 2, byte column 4", cursor)
      t.match("rename this variable", cursor)
    end)
  end)

  t.describe("inline review reset", function()
    t.it("clears always-accept", function()
      review.always_accept(9999)
      t.truthy(review.is_always_accepted(9999))
      review.reset(9999)
      t.falsy(review.is_always_accepted(9999))
    end)
  end)

  t.describe("inline prompt placement", function()
    local anchor = require("acp.inline.anchor")
    t.it("keeps the float inside the screen at every edge", function()
      local config = anchor.config(-5, -5, 10000, 10000)
      t.eq(0, config.row)
      t.eq(0, config.col)
      t.truthy(config.width <= vim.o.columns - 2)
      local bottom = anchor.config(10000, 10000, 20, 3)
      t.truthy(bottom.row + bottom.height <= vim.o.lines)
      t.truthy(bottom.col + bottom.width <= vim.o.columns)
    end)
    t.it("flips above the cursor when there is no room below", function()
      local win, buf = win_with({ "a", "b", "c" })
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      local top =
        anchor.place({ source = win, placement = "cursor", width = 40, height = 3, offset = { row = -10000 } })
      local bottom =
        anchor.place({ source = win, placement = "cursor", width = 40, height = 3, offset = { row = 10000 } })
      t.truthy(top.row <= bottom.row)
      t.truthy(top.row >= 0)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("anchors at the window when placement is window", function()
      local win, buf = win_with({ "a" })
      local pos = vim.api.nvim_win_get_position(win)
      local config = anchor.place({ source = win, placement = "window", width = 20, height = 3 })
      t.eq(pos[1], config.row)
      t.eq(pos[2], config.col)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("applies the configured offset", function()
      local win, buf = win_with({ "a" })
      local base = anchor.place({ source = win, placement = "cursor", width = 20, height = 2 })
      local moved = anchor.place({
        source = win,
        placement = "cursor",
        width = 20,
        height = 2,
        offset = { row = 2, col = 1 },
      })
      t.eq(math.min(base.row + 2, vim.o.lines - 4), moved.row)
      t.truthy(moved.col >= base.col)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline review rendering", function()
    local render = require("acp.inline.render")
    local original = { "a", "b", "c", "d" }
    local edited = { "A", "b", "c", "D" }
    local hunks = result.hunks(original, edited)
    local function build(over)
      return render.build(vim.tbl_extend("force", {
        original = original,
        edited = edited,
        hunks = hunks,
        width = 100,
      }, over or {}))
    end
    t.it("shows a whole-file two-column view and falls back on narrow width", function()
      local view = build()
      t.eq("split2", view.layout)
      t.match("^%s+1%s+- a%s", view.lines[1])
      t.match("│%s+1%s+%+ A", view.lines[1])
      t.match("^%s+2%s+  b%s", view.lines[2])
      t.eq(1, view.row_hunk[1])
      t.falsy(view.row_hunk[2])
      local narrow = build({ width = 30 })
      t.eq("unified", narrow.layout)
      t.truthy(table.concat(narrow.lines, "\n"):find("- a", 1, true))
    end)
    t.it("keeps the proposal on the right and marks a rejected hunk", function()
      hunks[1].decided, hunks[1].accepted = true, false
      local view = build()
      t.match("✗", view.lines[1])
      t.match("│%s+1%s+%+ A", view.lines[1])
      hunks[1].decided, hunks[1].accepted = nil, nil
    end)
    t.it("aligns inserts and deletes of different lengths", function()
      local uneven = result.hunks({ "a", "b" }, { "a", "x", "y", "b" })
      local view =
        render.build({ original = { "a", "b" }, edited = { "a", "x", "y", "b" }, hunks = uneven, width = 100 })
      local text = table.concat(view.lines, "\n")
      t.match("%+ x", text)
      t.match("%+ y", text)
      -- Both inserted lines belong to the same hunk; the delete side is blank.
      t.eq(1, view.row_hunk[2])
      t.eq(1, view.row_hunk[3])
      t.falsy(view.row_hunk[1])
    end)
    t.it("expands tabs and truncates long lines within the column", function()
      local original = { "\told" }
      local edited = { "\tnew" }
      local tabbed = result.hunks(original, edited)
      local view = render.build({ original = original, edited = edited, hunks = tabbed, width = 80, tabstop = 4 })
      t.falsy(view.lines[1]:find("\t", 1, true))
      local long_old = { string.rep("x", 500) }
      local long = result.hunks(long_old, { "y" })
      local clipped = render.build({ original = long_old, edited = { "y" }, hunks = long, width = 80 })
      t.truthy(vim.fn.strdisplaywidth(clipped.lines[1]) <= 80)
      t.match("…", clipped.lines[1])
    end)
    t.it("falls back to hunks past max_rows and truncates safely", function()
      local many_old, many_edited, many_hunks = {}, {}, {}
      for i = 1, 40 do
        many_old[i] = "old" .. i
        many_edited[i] = "new" .. i
        many_hunks[i] = { start = i - 1, old_lines = { "old" .. i }, new_lines = { "new" .. i }, new_start = i - 1 }
      end
      local view = render.build({
        original = many_old,
        edited = many_edited,
        hunks = many_hunks,
        width = 100,
        max_rows = 20,
      })
      t.eq("hunks", view.layout)
      t.truthy(#view.lines <= 20)
      t.match("@@ Hunk 1/40", view.lines[1])
    end)
  end)

  t.describe("inline review selection", function()
    local render = require("acp.inline.render")
    local res = require("acp.inline.result")
    local original = { "a", "b", "c", "d", "e" }
    local edited = { "A", "b", "c", "D", "e" }
    local hunks = res.hunks(original, edited)
    local function view()
      return render.build({ original = original, edited = edited, hunks = hunks, width = 100 })
    end
    t.it("maps changed rows to their hunk and leaves context unmapped", function()
      local v = view()
      t.eq(1, render.hunk_at(v, 1))
      t.falsy(render.hunk_at(v, 2))
      t.eq(2, render.hunk_at(v, 4))
      t.eq({ 1 }, render.selected(v, 1, 1))
      t.eq({ 1, 2 }, render.selected(v, 1, 4))
      t.eq({}, render.selected(v, 2, 3))
    end)
    t.it("reports each hunk's row range", function()
      local v = view()
      local from, to = render.hunk_range(v, 1)
      t.eq(1, from)
      t.truthy(to >= from)
      local second_from = render.hunk_range(v, 2)
      t.truthy(second_from > from)
    end)
    t.it("selects a hunk header as well as its changed rows", function()
      local hunks_view = render.build({
        original = { "a", "b" },
        edited = { "A", "b", "x" },
        hunks = res.hunks({ "a", "b" }, { "A", "b", "x" }),
        width = 100,
        layout = "hunks",
        context = 0,
      })
      t.eq("hunks", hunks_view.layout)
      t.eq(1, render.hunk_at(hunks_view, 1))
      t.eq(1, render.hunk_at(hunks_view, 2))
    end)
    t.it("acts on the whole Visual range", function()
      local win, buf = win_with(original)
      local accepted = {}
      local ok = require("acp.inline.diff_session").open({
        bufnr = buf,
        lines = edited,
        on_finish = function(count)
          accepted.count = count
        end,
      })
      t.truthy(ok)
      local review_win = vim.api.nvim_get_current_win()
      t.truthy(review_win ~= win)
      vim.api.nvim_win_set_cursor(review_win, { 1, 0 })
      vim.cmd("normal! V")
      vim.api.nvim_win_set_cursor(review_win, { 4, 0 })
      vim.api.nvim_feedkeys("ga", "x", false)
      wait_close(buf)
      t.eq({ "A", "b", "c", "D", "e" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      t.eq(2, accepted.count)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("refuses a decision on an unchanged row", function()
      local win, buf = win_with(original)
      assert(require("acp.inline.diff_session").open({ bufnr = buf, lines = edited }))
      vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
      vim.api.nvim_feedkeys("ga", "x", false)
      t.eq({ "a", "b", "c", "d", "e" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      require("acp.inline.diff_session").close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    t.it("keeps the cursor in place unless advance is enabled", function()
      local win, buf = win_with(original)
      assert(require("acp.inline.diff_session").open({ bufnr = buf, lines = edited }))
      local review_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(review_win, { 1, 0 })
      vim.api.nvim_feedkeys("gr", "x", false)
      t.eq(1, vim.api.nvim_win_get_cursor(review_win)[1])
      require("acp.inline.diff_session").close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("inline window config", function()
    t.it("accepts custom borders, titles and highlight groups", function()
      local c = cfg({
        inline = {
          window = {
            border = "double",
            title_pos = "center",
            style = "default",
            highlights = { normal = "MyNormal", border = "MyBorder", title = "MyTitle" },
            prompt = {
              placement = "cursor",
              width = 40,
              height = 2,
              offset = { row = 1, col = 2 },
              follow_cursor = false,
            },
            review = {
              placement = "cursor",
              width = 100,
              height = 10,
              layout = "unified",
              min_split_width = 70,
              max_rows = 50,
            },
          },
        },
      })
      t.eq("double", c.inline.window.border)
      t.eq("MyTitle", c.inline.window.highlights.title)
      t.eq("unified", c.inline.window.review.layout)
    end)
    t.it("accepts an explicit border character list", function()
      local c = cfg({ inline = { window = { border = { "a", "b", "c", "d", "e", "f", "g", "h" } } } })
      t.eq(8, #c.inline.window.border)
    end)
    t.it("rejects invalid appearance values", function()
      for _, over in ipairs({
        { inline = { window = { border = "wavy" } } },
        { inline = { window = { border = { "a", "b" } } } },
        { inline = { window = { title_pos = "middle" } } },
        { inline = { window = { style = "fancy" } } },
        { inline = { window = { highlights = { title = "" } } } },
        { inline = { window = { prompt = { width = 2 } } } },
        { inline = { window = { prompt = { follow_cursor = "yes" } } } },
        { inline = { window = { review = { layout = "columns" } } } },
        { inline = { window = { review = { min_split_width = 2 } } } },
      }) do
        local ok = pcall(Config.validate, Config.merge(Config.defaults, over))
        t.falsy(ok, vim.inspect(over))
      end
    end)
  end)
end
