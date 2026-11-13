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
      local saved_cfg, saved_client = S.config, S.conn.client
      local chosen
      S.config = cfg()
      S.conn.client = {
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
      S.config, S.conn.client = saved_cfg, saved_client
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

  t.describe("inline review card rendering", function()
    local card = require("acp.inline.review.card")
    local original = { "a", "b", "c", "d" }
    local edited = { "A", "b", "c", "D" }
    local hunks = result.hunks(original, edited)
    local function build(over)
      return card.build(vim.tbl_extend("force", {
        hunks = hunks,
        original = original,
        edited = edited,
        path = "/tmp/sample.lua",
        width = 60,
        context = 0,
      }, over or {}))
    end
    t.it("reuses the card renderer and maps every row to its hunk", function()
      local view = build()
      t.match("@@ Hunk 1/2", view.lines[1])
      t.eq(1, view.row_hunk[1])
      t.eq(1, view.row_hunk[2])
      t.truthy(table.concat(view.lines, "\n"):find("- a", 1, true))
      t.truthy(table.concat(view.lines, "\n"):find("+ A", 1, true))
      t.eq(2, view.rendered)
    end)
    t.it("marks accepted and rejected hunks in the gutter", function()
      hunks[1].decided, hunks[1].accepted = true, true
      t.match("^✓", build().lines[1])
      hunks[1].accepted = false
      t.match("^✗", build().lines[1])
      t.match("rejected", build().lines[1])
      hunks[1].decided, hunks[1].accepted = nil, nil
    end)
    t.it("truncates past max_rows instead of overrunning", function()
      local many_old, many_edited, many_hunks = {}, {}, {}
      for i = 1, 40 do
        many_old[i] = "old" .. i
        many_edited[i] = "new" .. i
        many_hunks[i] = { start = i - 1, old_lines = { "old" .. i }, new_lines = { "new" .. i }, new_start = i - 1 }
      end
      local view = build({
        hunks = many_hunks,
        original = many_old,
        edited = many_edited,
        max_rows = 20,
      })
      t.truthy(#view.lines <= 20)
      t.truthy(view.rendered < #many_hunks)
      t.match("truncated", view.lines[#view.lines])
    end)
    t.it("keeps syntax segments from the card renderer", function()
      local lua = { "local a = 1", "local b = 2" }
      local changed = { "local a = 42", "local b = 2" }
      local view = build({
        hunks = result.hunks(lua, changed),
        original = lua,
        edited = changed,
        path = "/tmp/sample.lua",
        width = 80,
        syntax = true,
      })
      local groups = {}
      for _, span in ipairs(view.spans) do
        if span.group then
          groups[span.group] = true
        end
      end
      t.truthy(groups.AcpDiffAdd or groups.AcpDiffDelete, vim.inspect(vim.tbl_keys(groups)))
    end)

    t.it("uses byte offsets after accepted and rejected UTF-8 markers", function()
      for _, accepted in ipairs({ true, false }) do
        local h = result.hunks({ "local a = 1" }, { "local a = 2" })
        h[1].decided, h[1].accepted = true, accepted
        local view = build({ hunks = h, original = { "local a = 1" }, edited = { "local a = 2" } })
        local found = false
        for _, span in ipairs(view.spans) do
          if span.group == "AcpDiffAddSign" or span.group == "AcpDiffRemoveSign" then
            found = true
            t.eq(4, span.start)
            t.eq(6, span.stop)
            t.truthy(({ ["+ "] = true, ["- "] = true })[view.lines[span.row + 1]:sub(span.start + 1, span.stop)])
          end
        end
        t.truthy(found)
      end
    end)

    t.it("shows configured original context without including neighboring changes", function()
      local old = { "left", "old", "middle", "other", "right" }
      local new = { "left", "new", "middle", "OTHER", "right" }
      local h = result.hunks(old, new)
      local view = build({ hunks = { h[1] }, original = old, edited = new, context = 3 })
      local text = table.concat(view.lines, "\n")
      t.truthy(text:find("left", 1, true))
      t.truthy(text:find("middle", 1, true))
      t.truthy(text:find("other", 1, true))
      t.falsy(text:find("OTHER", 1, true))
      local plain = build({ hunks = { h[1] }, original = old, edited = new, context = 0 })
      t.falsy(table.concat(plain.lines, "\n"):find("left", 1, true))
    end)

    t.it("keeps configured review highlights ahead of the static defaults", function()
      local hl = require("acp.ui.highlights")
      local saved = {
        DiffAdd = vim.api.nvim_get_hl(0, { name = "DiffAdd" }),
        DiffDelete = vim.api.nvim_get_hl(0, { name = "DiffDelete" }),
        DiffChange = vim.api.nvim_get_hl(0, { name = "DiffChange" }),
      }
      vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#005500" })
      vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#550000" })
      vim.api.nvim_set_hl(0, "DiffChange", { bg = "#000055" })
      hl.setup({
        AcpDiffModify = { bg = "#123456" },
        AcpReviewAdd = { bg = "#abcdef" },
        AcpReviewDelete = { bg = "#fedcba" },
        AcpReviewPending = { bg = "#456789" },
        AcpReviewFiller = { fg = "#334455" },
      })
      for _ = 1, 2 do
        t.eq(0x123456, vim.api.nvim_get_hl(0, { name = "AcpDiffModify", link = false }).bg)
        t.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "AcpReviewAdd", link = false }).bg)
        t.eq(0xfedcba, vim.api.nvim_get_hl(0, { name = "AcpReviewDelete", link = false }).bg)
        t.eq(0x456789, vim.api.nvim_get_hl(0, { name = "AcpReviewPending", link = false }).bg)
        t.eq(0x334455, vim.api.nvim_get_hl(0, { name = "AcpReviewFiller", link = false }).fg)
        vim.api.nvim_exec_autocmds("ColorScheme", {})
      end
      for name, spec in pairs(saved) do
        vim.api.nvim_set_hl(0, name, spec)
      end
      hl.setup({})
    end)

    t.it("copies the theme diff surfaces onto the review rows", function()
      local hl = require("acp.ui.highlights")
      local saved = {}
      for _, name in ipairs({ "DiffAdd", "DiffDelete", "DiffChange", "DiffText", "CursorLine" }) do
        saved[name] = vim.api.nvim_get_hl(0, { name = name })
      end
      vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#103010", fg = "#ffffff" })
      vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#301010", fg = "#ffffff" })
      vim.api.nvim_set_hl(0, "DiffChange", { bg = "#101030", underline = true })
      vim.api.nvim_set_hl(0, "DiffText", { bg = "#404070", bold = true })
      vim.api.nvim_set_hl(0, "CursorLine", { bg = "#202020", underline = true })
      hl.setup({})
      for group, expected in pairs({
        AcpReviewAdd = 0x103010,
        AcpReviewDelete = 0x301010,
        AcpReviewPending = 0x101030,
        AcpReviewAddText = 0x404070,
        AcpReviewDeleteText = 0x404070,
        AcpReviewCursorLine = 0x202020,
      }) do
        local def = vim.api.nvim_get_hl(0, { name = group, link = false })
        t.eq(expected, def.bg, group)
        -- Only the surface is copied: syntax keeps the text colour, and the
        -- theme's underline must not be drawn across every column.
        t.falsy(def.fg, group .. " carries a foreground")
        t.falsy(def.underline, group .. " carries an underline")
      end
      -- The copy follows the theme.
      vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#105510" })
      vim.api.nvim_exec_autocmds("ColorScheme", {})
      t.eq(0x105510, vim.api.nvim_get_hl(0, { name = "AcpReviewAdd", link = false }).bg)
      -- An explicit override wins.
      hl.setup({ AcpReviewAdd = { bg = "#224422" } })
      t.eq(0x224422, vim.api.nvim_get_hl(0, { name = "AcpReviewAdd", link = false }).bg)
      for name, spec in pairs(saved) do
        vim.api.nvim_set_hl(0, name, spec)
      end
      hl.setup({})
    end)

    t.it("classifies hunks by old/new content, not row counts or decisions", function()
      for _, case in ipairs({
        { {}, { "new" }, "add" },
        { { "old" }, {}, "delete" },
        { { "old" }, { "new" }, "modify" },
        { { "old" }, { "new", "extra" }, "modify" },
        { { "old", "extra" }, { "new" }, "modify" },
      }) do
        local hunk = { old_lines = case[1], new_lines = case[2] }
        t.eq(case[3], result.hunk_kind(hunk))
        hunk.decided, hunk.accepted = true, true
        t.eq(case[3], result.hunk_kind(hunk))
        hunk.accepted = false
        t.eq(case[3], result.hunk_kind(hunk))
      end
    end)

    t.it("uses fixed subdued filler foregrounds on every theme", function()
      local hl = require("acp.ui.highlights")
      local saved = {}
      for _, name in ipairs({ "Normal", "NormalFloat", "DiffDelete" }) do
        saved[name] = vim.api.nvim_get_hl(0, { name = name })
      end
      for _, bg in ipairs({ "#202020", "#ffffff", "NONE" }) do
        vim.api.nvim_set_hl(0, "Normal", { bg = bg, fg = "#ffffff" })
        vim.api.nvim_set_hl(0, "NormalFloat", { bg = bg })
        vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#602020", fg = "#ffffff" })
        hl.setup({})
        t.eq(0x5c6370, vim.api.nvim_get_hl(0, { name = "AcpReviewFiller", link = false }).fg)
        -- No background: the row/Normal background shows through.
        t.falsy(vim.api.nvim_get_hl(0, { name = "AcpReviewFiller", link = false }).bg)
        vim.api.nvim_exec_autocmds("ColorScheme", {})
        t.eq(0x5c6370, vim.api.nvim_get_hl(0, { name = "AcpReviewFiller", link = false }).fg)
      end
      for name, spec in pairs(saved) do
        vim.api.nvim_set_hl(0, name, spec)
      end
      hl.setup({})
    end)
  end)

  t.describe("inline review session", function()
    local session_mod = require("acp.inline.diff_session")
    local original = { "a", "b", "c", "d", "e" }
    local edited = { "A", "b", "c", "D", "e" }

    local function open(over)
      local _, buf = win_with(original)
      local cfg_now = cfg()
      -- Force the native layout regardless of the test screen width.
      cfg_now.inline.window.review.min_split_width = 20
      for key, value in pairs(over or {}) do
        cfg_now.inline.window.review[key] = value
      end
      local finished = {}
      local ok, err = session_mod.open({
        bufnr = buf,
        lines = edited,
        config = cfg_now,
        on_finish = function(count)
          finished.count = count
        end,
      })
      return ok, err, buf, finished
    end

    ---Review windows ordered left to right, with their buffers.
    local function sorted_panes()
      local panes = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        panes[#panes + 1] = {
          col = vim.api.nvim_win_get_position(win)[2],
          win = win,
          buf = vim.api.nvim_win_get_buf(win),
        }
      end
      table.sort(panes, function(a, b)
        return a.col < b.col
      end)
      return panes
    end

    ---Row decorations of a review buffer: `row -> group` (filler rows by their
    ---line highlight, changed rows by their row surface).
    local function row_groups(buf)
      local ns = vim.api.nvim_get_namespaces()["acp.inline.review"]
      local out = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        local d = mark[4]
        if d.line_hl_group then
          out[mark[2] + 1] = d.line_hl_group
        elseif d.hl_eol then
          out[mark[2] + 1] = d.hl_group
        end
      end
      return out
    end

    t.it("classifies each row of a mixed hunk on its own side", function()
      -- Nothing similar: plain top-down pairing, the surplus row is the addition.
      local mixed = result.hunk_rows({ old_lines = { "old" }, new_lines = { "new", "added" } })
      t.eq("modify", mixed.old[1])
      t.eq("modify", mixed.new[1])
      t.eq("add", mixed.new[2])
      t.eq(nil, mixed.old[2])

      -- Something similar: linematch pairs it wherever it sits.
      local similar = result.hunk_rows({
        old_lines = { "local x = 1" },
        new_lines = { "-- a new comment", "local x = 2" },
      })
      t.eq("modify", similar.old[1])
      t.eq("add", similar.new[1])
      t.eq("modify", similar.new[2])

      -- Unequal replacement: the matched row modifies, the surplus old row is
      -- the deletion.
      local shrunk = result.hunk_rows({ old_lines = { "o1", "o2" }, new_lines = { "n1" } })
      t.eq("modify", shrunk.old[1])
      t.eq("delete", shrunk.old[2])
      t.eq("modify", shrunk.new[1])

      -- linematch pairs the surviving line wherever it sits, so a three-line
      -- replacement of one line marks the last old row as the modification and
      -- the first two as deletions.
      local paired_last = result.hunk_rows({
        old_lines = { "a = 1", "b = 2", "return a + b" },
        new_lines = { "return a + b + 1" },
      })
      t.eq({ delete = true, delete_b = true, modify = true }, {
        delete = paired_last.old[1] == "delete",
        delete_b = paired_last.old[2] == "delete",
        modify = paired_last.old[3] == "modify",
      })
      t.eq("modify", paired_last.new[1])

      local added = result.hunk_rows({ old_lines = {}, new_lines = { "a", "b" } })
      t.eq({ add = true, add_b = true }, { add = added.new[1] == "add", add_b = added.new[2] == "add" })
      local removed = result.hunk_rows({ old_lines = { "a", "b" }, new_lines = {} })
      t.eq(
        { delete = true, delete_b = true },
        { delete = removed.old[1] == "delete", delete_b = removed.old[2] == "delete" }
      )
    end)

    t.it("aligns rows so modified rows face content and added rows face filler", function()
      local align = require("acp.inline.review.align")
      local cases = {
        { { "a", "b", "c" }, { "a", "B", "x", "c" } },
        { { "a", "b" }, { "z", "a", "b", "y" } },
        { { "a", "b", "c" }, { "c" } },
        { {}, { "new" } },
        { { "only" }, {} },
        {
          { "--- Builds a greeting string.", "---", "--- Every argument is optional", "--- error.", "---", "x" },
          { "--- 构造一个问候字符串。", "---", "--- 每个参数都是可选的", "---", "x" },
        },
      }
      for _, case in ipairs(cases) do
        local old, new = case[1], case[2]
        local hunks = result.hunks(old, new)
        local model = align.build(old, new, hunks)
        local left = align.pane(model, "original", hunks)
        local right = align.pane(model, "proposal", hunks)
        t.eq(#left.lines, #right.lines, "columns differ in height")
        for r, row in ipairs(model.rows) do
          if row.kind == "modify" or row.kind == "same" then
            t.falsy(left.filler[r] or right.filler[r], "a paired row faces filler")
          elseif row.kind == "add" then
            t.truthy(left.filler[r] and not right.filler[r], "an added row does not face filler")
          elseif row.kind == "delete" then
            t.truthy(right.filler[r] and not left.filler[r], "a deleted row does not face filler")
          end
        end
        -- Every real line is shown exactly once, in order.
        local seen_old, seen_new = {}, {}
        for r = 1, #model.rows do
          if not left.filler[r] then
            seen_old[#seen_old + 1] = left.lines[r]
          end
          if not right.filler[r] then
            seen_new[#seen_new + 1] = right.lines[r]
          end
        end
        t.eq(old, seen_old)
        t.eq(new, seen_new)
      end
      -- The translated comment pairs top-down, not by accident of similarity.
      local old, new = cases[6][1], cases[6][2]
      local model = align.build(old, new, result.hunks(old, new))
      t.eq(3, model.rows[3].old)
      t.eq(3, model.rows[3].new)
      t.eq("delete", model.rows[4].kind)
    end)

    t.it("marks only the changed characters of a similar row", function()
      t.eq({ old = { { 10, 13 } }, new = { { 10, 13 } } }, result.char_ranges("local x = foo(1)", "local x = bar(1)"))
      -- A rewrite would light up the whole row: the row surface is enough.
      t.eq({ old = {}, new = {} }, result.char_ranges("-- Builds a greeting", "-- 构造一个问候"))
      -- Ranges stay on UTF-8 boundaries.
      local ranges = result.char_ranges("名字 = 1", "名称 = 1")
      t.eq({ { 3, 6 } }, ranges.old)
      t.eq({ { 3, 6 } }, ranges.new)
    end)

    t.it("pads every column to the same rows and paints each side", function()
      local _, buf = win_with({ "a", "old", "z" })
      local c = cfg()
      c.inline.window.review.min_split_width = 20
      assert(session_mod.open({ bufnr = buf, lines = { "a", "new", "added", "z" }, config = c }))
      local panes = sorted_panes()
      local lines = {}
      for i, pane in ipairs(panes) do
        lines[i] = vim.api.nvim_buf_get_lines(pane.buf, 0, -1, false)
      end
      t.eq({ "a", "old", "", "z" }, lines[1])
      t.eq({ "a", "old", "", "z" }, lines[2])
      t.eq({ "a", "new", "added", "z" }, lines[3])
      -- Original: what goes away. Result: still undecided. Proposal: what comes in.
      t.eq({ [2] = "AcpReviewDelete", [3] = "AcpReviewFiller" }, row_groups(panes[1].buf))
      t.eq({ [2] = "AcpReviewPending", [3] = "AcpReviewFiller" }, row_groups(panes[2].buf))
      t.eq({ [2] = "AcpReviewAdd", [3] = "AcpReviewAdd" }, row_groups(panes[3].buf))
      -- Real line numbers: filler rows have none, the proposal keeps its own.
      local layout = require("acp.inline.review.layout")
      local lnums = layout.gutter(panes[1].buf).lnums
      t.eq({ 1, 2, nil, 3 }, { lnums[1], lnums[2], lnums[3], lnums[4] })
      t.eq(4, layout.gutter(panes[3].buf).lnums[4])
      -- One state bar per hunk row, the same in every column.
      for _, pane in ipairs(panes) do
        local bars = layout.gutter(pane.buf).bars
        t.falsy(bars[1])
        t.truthy(bars[2] and bars[3])
        t.falsy(bars[4])
      end
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("repaints every column from the decision", function()
      local _, buf = win_with({ "a", "old", "z", "q" })
      local c = cfg()
      c.inline.window.review.min_split_width = 20
      c.inline.window.review.fold = false
      assert(session_mod.open({ bufnr = buf, lines = { "a", "new", "z", "Q" }, config = c }))
      local panes = sorted_panes()
      local result_win = panes[2].win
      vim.api.nvim_set_current_win(result_win)
      vim.api.nvim_win_set_cursor(result_win, { 2, 0 })
      vim.api.nvim_feedkeys("ga", "x", false)
      -- Accepted: the result shows the proposal, the replaced original dims.
      t.eq({ "a", "new", "z", "q" }, vim.api.nvim_buf_get_lines(panes[2].buf, 0, -1, false))
      t.eq("AcpReviewDimmed", row_groups(panes[1].buf)[2])
      t.eq("AcpReviewAdd", row_groups(panes[2].buf)[2])
      t.eq("AcpReviewAdd", row_groups(panes[3].buf)[2])
      local layout = require("acp.inline.review.layout")
      t.eq("AcpReviewStateAccepted", layout.gutter(panes[1].buf).bars[2].group)
      t.eq("✓", layout.gutter(panes[3].buf).bars[2].glyph)
      -- Rejected: the original is kept as is, the dropped proposal dims.
      vim.api.nvim_win_set_cursor(result_win, { 4, 0 })
      vim.api.nvim_feedkeys("u", "x", false)
      t.eq("AcpReviewStateCurrent", layout.gutter(panes[2].buf).bars[4].group)
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })

      _, buf = win_with({ "a", "old", "z", "q" })
      assert(session_mod.open({ bufnr = buf, lines = { "a", "new", "z", "Q" }, config = c }))
      panes = sorted_panes()
      vim.api.nvim_set_current_win(panes[2].win)
      vim.api.nvim_win_set_cursor(panes[2].win, { 2, 0 })
      vim.api.nvim_feedkeys("gr", "x", false)
      t.eq(nil, row_groups(panes[1].buf)[2])
      t.eq(nil, row_groups(panes[2].buf)[2])
      t.eq("AcpReviewDimmed", row_groups(panes[3].buf)[2])
      t.eq("AcpReviewStateRejected", layout.gutter(panes[2].buf).bars[2].group)
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("starts Tree-sitter for languages Neovim does not cover by default", function()
      local layout = require("acp.inline.review.layout")
      local sources = {
        python = { "def f(x):", "    return x + 1" },
        javascript = { "function f(x) {", "  return x + 1", "}" },
        lua = { "local function f(x)", "  return x + 1", "end" },
      }
      for lang, lines in pairs(sources) do
        local buf = layout.scratch(lines, lang, false)
        t.truthy(vim.treesitter.highlighter.active[buf], lang .. " was not highlighted by Tree-sitter")
        t.eq("", vim.bo[buf].syntax, lang .. " fell back to legacy syntax")
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      -- An unknown language falls back silently to the legacy syntax file.
      local odd = layout.scratch({ "whatever" }, "totally_unknown_lang", false)
      t.falsy(vim.treesitter.highlighter.active[odd])
      t.eq("totally_unknown_lang", vim.bo[odd].syntax)
      vim.api.nvim_buf_delete(odd, { force = true })
    end)

    t.it("pins every review window so its buffer cannot be replaced", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = win }), "unpinned window " .. win)
        local before = vim.api.nvim_win_get_buf(win)
        for _, command in ipairs({ "enew", "bnext", "edit /tmp/acp-review-should-not-open.lua" }) do
          local changed, failure = pcall(function()
            vim.api.nvim_win_call(win, function()
              vim.cmd(command)
            end)
          end)
          t.falsy(changed, command .. " -> " .. tostring(failure))
          t.match("E1513", tostring(failure))
          t.eq(before, vim.api.nvim_win_get_buf(win))
        end
      end
      -- Closing is still allowed, and it settles the review like any other exit.
      -- The teardown is scheduled, so the session disappears one event-loop turn
      -- after the tab is gone.
      vim.cmd("tabclose")
      vim.wait(200, function()
        return not session_mod.active(buf)
      end)
      t.falsy(session_mod.active(buf))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("leaves window options and later floats untouched", function()
      local function global(name)
        return vim.api.nvim_get_option_value(name, { scope = "global" })
      end
      local saved = { diff = global("diff"), winhighlight = global("winhighlight") }
      vim.o.diffopt = "internal,filler,context:2"
      vim.api.nvim_set_option_value("winhighlight", "DiffAdd:Error", { scope = "global" })
      local ok, err, buf = open()
      t.truthy(ok, err)
      local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 20,
        height = 3,
        style = "minimal",
      })
      t.falsy(vim.api.nvim_get_option_value("diff", { win = float }), "float joined the diff")
      t.falsy(
        vim.api.nvim_get_option_value("winhighlight", { win = float }):find("AcpReview", 1, true),
        "float inherited the review winhighlight"
      )
      t.eq(saved.diff, global("diff"))
      -- A pre-existing global value survives and is not overwritten with the
      -- review's own winhighlight.
      t.eq("DiffAdd:Error", global("winhighlight"))
      vim.api.nvim_win_close(float, true)
      session_mod.close_all()
      t.eq(saved.diff, global("diff"))
      t.eq("DiffAdd:Error", global("winhighlight"))
      vim.api.nvim_set_option_value("winhighlight", saved.winhighlight, { scope = "global" })
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("brings a pane back after its buffer was swapped", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      local win = vim.api.nvim_get_current_win()
      local pane_buf = vim.api.nvim_win_get_buf(win)
      vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
      vim.api.nvim_win_call(win, function()
        vim.cmd("edit " .. vim.fn.tempname())
      end)
      t.truthy(
        vim.wait(500, function()
          return vim.api.nvim_win_get_buf(win) == pane_buf
        end),
        "the review buffer was not restored"
      )
      t.truthy(vim.api.nvim_get_option_value("winfixbuf", { win = win }))
      -- The hunk mappings belong to the restored buffer again.
      t.truthy(vim.api.nvim_win_call(win, function()
        return vim.fn.maparg("ga", "n", false, true).callback ~= nil
      end))
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("opens the native three-window layout in its own tab", function()
      local tabs = #vim.api.nvim_list_tabpages()
      local ok, err, buf = open()
      t.truthy(ok, err)
      t.eq(tabs + 1, #vim.api.nvim_list_tabpages())
      local wins = vim.api.nvim_tabpage_list_wins(0)
      t.eq(3, #wins)
      for _, win in ipairs(wins) do
        -- Not Vim's diff mode: it would diff all three columns against each
        -- other. Rows are aligned by padding instead.
        t.falsy(vim.wo[win].diff, "window is in diff mode")
        t.truthy(vim.wo[win].scrollbind)
        t.truthy(vim.wo[win].cursorbind)
      end
      local counts = {}
      for _, win in ipairs(wins) do
        counts[#counts + 1] = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
      end
      t.eq({ counts[1], counts[1], counts[1] }, counts)
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("keeps the column order regardless of 'splitright'", function()
      local saved = vim.o.splitright
      for _, value in ipairs({ false, true }) do
        vim.o.splitright = value
        local ok, err, buf = open()
        t.truthy(ok, err)
        local ordered = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          ordered[#ordered + 1] = { col = vim.api.nvim_win_get_position(win)[2], win = win }
        end
        table.sort(ordered, function(a, b)
          return a.col < b.col
        end)
        local firsts = {}
        for _, entry in ipairs(ordered) do
          firsts[#firsts + 1] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(entry.win), 0, 1, false)[1]
        end
        -- original | result | proposal
        t.eq({ "a", "a", "A" }, firsts, "splitright=" .. tostring(value))
        session_mod.close_all()
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      vim.o.splitright = saved
    end)

    t.it("applies the review appearance options", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        t.eq("no", vim.wo[win].signcolumn)
        t.falsy(vim.wo[win].relativenumber)
        t.eq("1", vim.wo[win].foldcolumn)
        t.eq("expr", vim.wo[win].foldmethod)
        t.truthy(vim.wo[win].statuscolumn:find("acp.inline.review.layout", 1, true))
        local fcs = vim.api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
        t.truthy(fcs:find("vert:│", 1, true), fcs)
        t.truthy(vim.wo[win].winhl:find("CursorLine:AcpReviewCursorLine", 1, true))
      end
      -- The gutter shows the bar cell and the real line number.
      local win = vim.api.nvim_get_current_win()
      local text = vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, { winid = win, use_statuscol_lnum = 1 }).str
      t.match("1 $", text)
      -- The global option must not be touched by the window-local assignment.
      t.falsy(vim.api.nvim_get_option_value("statuscolumn", { scope = "global" }):find("acp", 1, true))
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("paints only the rows each pane actually changes", function()
      local _, buf = win_with({ "a", "b", "c", "d", "e" })
      local c = cfg()
      c.inline.window.review.min_split_width = 20
      assert(session_mod.open({ bufnr = buf, lines = { "a", "b", "NEW", "c", "d", "e" }, config = c }))
      local panes = sorted_panes()
      t.truthy(session_mod.active(buf))
      -- A pure insertion has no row on the old side: the original and the
      -- (still unmodified) result columns show filler there, the proposal the
      -- inserted line. Neighbouring unchanged lines stay unpainted.
      t.eq({ [3] = "AcpReviewFiller" }, row_groups(panes[1].buf))
      t.eq({ [3] = "AcpReviewFiller" }, row_groups(panes[2].buf))
      t.eq({ [3] = "AcpReviewAdd" }, row_groups(panes[3].buf))
      for _, pane in ipairs(panes) do
        t.eq(6, vim.api.nvim_buf_line_count(pane.buf))
      end
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("does not paint unchanged insertion anchors as hunk rows", function()
      local _, buf = win_with({ "a", "", "c", "d", "e" })
      local c = cfg()
      c.inline.window.review.min_split_width = 20
      assert(session_mod.open({ bufnr = buf, lines = { "a", "", "NEW", "c", "d", "e" }, config = c }))
      local ns = vim.api.nvim_get_namespaces()["acp.inline.review"]
      local panes = sorted_panes()
      for _, pane in ipairs(panes) do
        -- The empty anchor line above the insertion is untouched everywhere.
        t.eq({}, vim.api.nvim_buf_get_extmarks(pane.buf, ns, { 1, 0 }, { 1, -1 }, {}))
      end
      local marks = vim.api.nvim_buf_get_extmarks(panes[3].buf, ns, { 2, 0 }, { 2, -1 }, { details = true })
      t.eq(1, #marks)
      t.eq("AcpReviewAdd", marks[1][4].hl_group)
      t.eq(3, marks[1][4].end_row)
      t.eq(0, marks[1][4].end_col)
      t.truthy(marks[1][4].hl_eol)
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("uses two windows for 2-column", function()
      local ok, err, buf = open({ layout = "2-column" })
      t.truthy(ok, err)
      t.eq(2, #vim.api.nvim_tabpage_list_wins(0))
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("decides pure EOF insertions individually in both native layouts", function()
      for _, mode in ipairs({ "2-column", "3-column" }) do
        for _, action in ipairs({ "ga", "gr" }) do
          local _, buf = win_with({ "a", "b" })
          local c = cfg()
          c.inline.window.review.min_split_width = 20
          c.inline.window.review.layout = mode
          assert(session_mod.open({ bufnr = buf, lines = { "a", "b", "NEW" }, config = c }))
          vim.api.nvim_feedkeys("]c", "x", false)
          -- The inserted row is a display row of its own, after `b`.
          t.eq(3, vim.api.nvim_win_get_cursor(0)[1])
          vim.api.nvim_feedkeys(action, "x", false)
          wait_close(buf)
          t.falsy(session_mod.active(buf))
          t.eq(action == "ga" and { "a", "b", "NEW" } or { "a", "b" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end)

    t.it("updates the current hunk bar when the cursor moves", function()
      local ok, err, buf = open({ fold = false })
      t.truthy(ok, err)
      local layout = require("acp.inline.review.layout")
      local mid = vim.api.nvim_get_current_buf()
      local function bar(row)
        local entry = layout.gutter(mid).bars[row]
        return entry and entry.group
      end
      local ns = vim.api.nvim_get_namespaces()["acp.inline.review"]
      local function hint_row()
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(mid, ns, 0, -1, { details = true })) do
          if mark[4].virt_text_pos == "eol" then
            return mark[2] + 1
          end
        end
      end
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = mid })
      t.eq("AcpReviewStateCurrent", bar(4))
      t.eq("AcpReviewStatePending", bar(1))
      t.eq(4, hint_row())
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = mid })
      t.eq("AcpReviewStatePending", bar(4))
      t.eq(nil, hint_row())
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("never touches diffopt or diff mode", function()
      local saved = vim.o.diffopt
      vim.o.diffopt = "internal,filler,context:2"
      local _, _, b1 = open()
      t.eq("internal,filler,context:2", vim.o.diffopt)
      vim.cmd("tabnew")
      local source_tab2 = vim.api.nvim_get_current_tabpage()
      local _, _, b2 = open()
      t.eq("internal,filler,context:2", vim.o.diffopt)
      session_mod.close_all()
      t.eq("internal,filler,context:2", vim.o.diffopt)
      vim.api.nvim_buf_delete(b1, { force = true })
      vim.api.nvim_buf_delete(b2, { force = true })
      if vim.api.nvim_tabpage_is_valid(source_tab2) then
        vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(source_tab2))
      end
      vim.o.diffopt = saved
    end)

    t.it("rolls back options, buffers and autocmds when splitting fails", function()
      local _, buf = win_with(original)
      local before_tabs = #vim.api.nvim_list_tabpages()
      local before_buffers = vim.api.nvim_list_bufs()
      local before_opt = vim.o.diffopt
      local width, minwidth = vim.o.winwidth, vim.o.winminwidth
      local c = cfg()
      c.inline.window.review.min_split_width = 20
      vim.o.winwidth = vim.o.columns
      vim.o.winminwidth = math.floor(vim.o.columns / 2)
      local ok, err = session_mod.open({ bufnr = buf, lines = edited, config = c })
      vim.o.winminwidth = minwidth
      vim.o.winwidth = width
      t.falsy(ok)
      t.truthy(err:find("E36", 1, true), err)
      t.eq(before_opt, vim.o.diffopt)
      t.eq(before_tabs, #vim.api.nvim_list_tabpages())
      t.eq(before_buffers, vim.api.nvim_list_bufs())
      t.falsy(session_mod.active(buf))
      t.falsy(pcall(vim.api.nvim_get_autocmds, { group = "AcpInlineReview" .. buf }))
      assert(session_mod.open({ bufnr = buf, lines = edited, config = c }))
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("accepts one hunk and leaves the rest untouched", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_feedkeys("ga", "x", false)
      t.truthy(session_mod.active(buf))
      session_mod.close_all()
      t.eq({ "a", "b", "c", "d", "e" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("writes accepted hunks on finish and rejects on close", function()
      local ok, err, buf, finished = open({ advance = true })
      t.truthy(ok, err)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_feedkeys("g2", "x", false)
      wait_close(buf)
      t.eq(2, finished.count)
      t.eq({ "A", "b", "c", "D", "e" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.cmd("silent undo")
      t.eq(original, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("decides hunks from any column, since rows are aligned", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      local panes = sorted_panes()
      -- The proposal column selects the hunk on the same display row.
      vim.api.nvim_set_current_win(panes[3].win)
      vim.api.nvim_win_set_cursor(panes[3].win, { 1, 0 })
      vim.api.nvim_feedkeys("ga", "x", false)
      t.truthy(session_mod.active(buf))
      -- So does the original column.
      vim.api.nvim_set_current_win(panes[1].win)
      vim.api.nvim_win_set_cursor(panes[1].win, { 4, 0 })
      vim.api.nvim_feedkeys("gr", "x", false)
      wait_close(buf)
      t.eq({ "A", "b", "c", "d", "e" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("keeps the remaining hunks reachable after an accepted one", function()
      local _, buf = win_with(original)
      local c = cfg()
      c.inline.window.review.min_split_width = 20
      local wide_edited = { "A", "b", "c", "d", "E" }
      assert(session_mod.open({ bufnr = buf, lines = wide_edited, config = c }))
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(win, { 5, 0 })
      vim.api.nvim_feedkeys("ga", "x", false)
      -- `advance` is off, so the cursor stays put; the accepted hunk vanishes
      -- from the diff and `]c` must still reach the remaining pending hunk.
      t.eq(5, vim.api.nvim_win_get_cursor(win)[1])
      vim.api.nvim_feedkeys("]c", "x", false)
      t.eq(1, vim.api.nvim_win_get_cursor(win)[1])
      vim.api.nvim_feedkeys("ga", "x", false)
      wait_close(buf)
      t.eq({ "A", "b", "c", "d", "E" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("navigates review hunks in order from every pane after line shifts", function()
      for _, mode in ipairs({ "2-column", "3-column" }) do
        local old = {}
        for i = 1, 24 do
          old[i] = "original line " .. i
        end
        local new = vim.deepcopy(old)
        new[3], new[10], new[20] = "CHANGED 3", "CHANGED 10", "CHANGED 20"
        table.insert(new, 4, "INSERTED")
        local _, buf = win_with(old)
        local c = cfg()
        c.inline.window.review.layout = mode
        c.inline.window.review.min_split_width = 20
        assert(session_mod.open({ bufnr = buf, lines = new, config = c }))
        local function move(key, expected, win)
          win = win or vim.api.nvim_get_current_win()
          vim.api.nvim_feedkeys(key, "x", false)
          -- Navigation stays in the column it started from.
          t.eq(win, vim.api.nvim_get_current_win())
          t.eq(expected, vim.api.nvim_win_get_cursor(0)[1], mode .. " " .. key)
        end
        -- Display rows: the insertion after line 3 is a row of its own, so the
        -- later hunks sit one row lower, in every column and whatever is decided.
        move("]c", 3)
        move("]c", 11)
        move("]h", 21)
        move("[h", 11)
        move("[c", 3)
        move("[c", 21)
        move("]c", 3)
        vim.api.nvim_feedkeys("ga", "x", false)
        move("]c", 11)
        move("]c", 21)
        move("]c", 3) -- decided hunks remain reachable for undo
        vim.api.nvim_feedkeys("u", "x", false)
        move("]c", 11)
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        move("]c", 11)
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        move("[c", 3)
        local result_win = vim.api.nvim_get_current_win()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if win ~= result_win then
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
            move("]c", 3, win)
          end
        end
        session_mod.close_all()
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)

    t.it("navigates card hunks from headers and unchanged separators", function()
      local ok, err, buf = open({ min_split_width = 10000, context = 0 })
      t.truthy(ok, err)
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local second
      for row, line in ipairs(lines) do
        if line:find("@@ Hunk 2/2", 1, true) then
          second = row
        end
      end
      t.truthy(second)
      vim.api.nvim_feedkeys("]c", "x", false)
      t.eq(second, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_feedkeys("]c", "x", false)
      t.eq(1, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_feedkeys("[c", "x", false)
      t.eq(second, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_win_set_cursor(0, { second - 1, 0 })
      vim.api.nvim_feedkeys("[c", "x", false)
      t.eq(1, vim.api.nvim_win_get_cursor(0)[1])
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("keeps the result column read-only so decisions are not lost", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      local mid = vim.api.nvim_get_current_buf()
      t.falsy(vim.bo[mid].modifiable)
      t.falsy(pcall(vim.api.nvim_buf_set_lines, mid, 0, 1, false, { "MANUAL" }))
      vim.api.nvim_feedkeys("g2", "x", false)
      wait_close(buf)
      t.eq({ "A", "b", "c", "D", "e" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.cmd("silent undo")
      t.eq(original, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("drops the session when the review tab is closed", function()
      local saved = vim.o.diffopt
      local ok, err, buf = open()
      t.truthy(ok, err)
      vim.cmd("tabclose")
      vim.wait(200, function()
        return false
      end)
      t.falsy(session_mod.active(buf))
      t.eq(saved, vim.o.diffopt)
      local reopened, why = session_mod.open({
        bufnr = buf,
        lines = edited,
        config = cfg(),
      })
      t.truthy(reopened, why)
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("drops the session when the source buffer is wiped", function()
      local ok, err, buf = open()
      t.truthy(ok, err)
      vim.api.nvim_buf_delete(buf, { force = true })
      t.falsy(session_mod.active(buf))
      t.eq(1, #vim.api.nvim_list_tabpages())
    end)

    t.it("does not leak the tab placeholder buffer", function()
      local before = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        before[buf] = true
      end
      local ok, err, buf = open()
      t.truthy(ok, err)
      session_mod.close_all()
      vim.api.nvim_buf_delete(buf, { force = true })
      for _, leftover in ipairs(vim.api.nvim_list_bufs()) do
        if not before[leftover] and vim.api.nvim_buf_is_valid(leftover) then
          t.falsy(vim.bo[leftover].buftype == "", "leftover normal buffer " .. leftover)
        end
      end
    end)

    t.it("falls back to the card renderer on a narrow screen", function()
      local _, buf = win_with(original)
      local c = cfg()
      c.inline.window.review.min_split_width = 10000
      local ok, err = session_mod.open({ bufnr = buf, lines = edited, config = c })
      t.truthy(ok, err)
      local current = vim.api.nvim_get_current_buf()
      t.eq("acp_inline_review", vim.bo[current].filetype)
      t.truthy(table.concat(vim.api.nvim_buf_get_lines(current, 0, -1, false), "\n"):find("@@ Hunk", 1, true))
      session_mod.close_all()
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
              layout = "2-column",
              min_split_width = 70,
              max_rows = 50,
            },
          },
        },
      })
      t.eq("double", c.inline.window.border)
      t.eq("MyTitle", c.inline.window.highlights.title)
      t.eq("2-column", c.inline.window.review.layout)
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
