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
      t.falsy(got.insertion)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("records an insertion point without a visual range", function()
      local win, buf = win_with({ "abc" })
      vim.api.nvim_win_set_cursor(win, { 1, 1 })
      local c = cfg()
      local got = assert(selection.capture(win, c))
      t.eq(0, #got.text)
      t.truthy(got.insertion)
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
      t.truthy(copy.is_copy_path(made, cfg()))
      t.falsy(copy.is_copy_path(path, cfg()))
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
      local win, buf = win_with({ "a", "b", "c", "d" })
      local hunks = result.hunks({ "a", "b", "c", "d" }, { "A", "b", "c", "D" })
      local finished
      local ok = diff_session.open({
        bufnr = buf,
        lines = { "A", "b", "c", "D" },
        hunks = {
          { start_row = 0, end_row = 0, new_lines = hunks[1].new_lines, original = hunks[1].old_lines },
          { start_row = 3, end_row = 3, new_lines = hunks[2].new_lines, original = hunks[2].old_lines },
        },
        on_finish = function(accepted, total)
          finished = { accepted, total }
        end,
      })
      t.truthy(ok)
      t.eq({ "A", "b", "c", "D" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_feedkeys("gr", "x", false)
      t.eq({ "a", "b", "c", "D" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_feedkeys("ga", "x", false)
      t.eq({ a = "a" }, { a = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] })
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
      local win, buf = win_with({ "b", "c" })
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
      vim.cmd("silent undo")
      t.eq({ "b", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
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
      local invocation = { copy = "/tmp/.acp-inline-1-x.lua", on_status = function() end }
      local options = { { kind = "allow_once", optionId = "a" }, { kind = "reject_once", optionId = "r" } }
      t.truthy(inline.on_permission(invocation, { options = options, tool_call = { kind = "read" } }))
      t.eq("a", chosen)
      inline.on_permission(invocation, {
        options = options,
        tool_call = { kind = "edit", locations = { { path = "/tmp/.acp-inline-1-x.lua" } } },
      })
      t.eq("a", chosen)
      inline.on_permission(
        invocation,
        { options = options, tool_call = { kind = "edit", locations = { { path = "/tmp/other.lua" } } } }
      )
      t.eq("r", chosen)
      inline.on_permission(invocation, { options = options, tool_call = { kind = "edit" } })
      t.eq("r", chosen)
      S.config.inline.allow_writes = true
      inline.on_permission(invocation, { options = options, tool_call = { kind = "edit" } })
      t.eq("a", chosen)
      S.config.inline.allow_commands = false
      inline.on_permission(invocation, { options = options, tool_call = { kind = "execute" } })
      t.eq("r", chosen)
      S.config, S.client = saved_cfg, saved_client
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
end
