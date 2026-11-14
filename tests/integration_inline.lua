-- Integration test: an inline rewrite goes through a private copy and only the
-- selected lines reach the buffer. Both review modes are exercised.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function wait(cond, timeout, label)
  -- `vim.wait` returns early when input or a tabpage switch interrupts it, so
  -- retry until the real deadline instead of treating one interruption as a
  -- timeout.
  local deadline = vim.uv.now() + (timeout or 10000)
  while true do
    if cond() then
      return
    end
    local left = deadline - vim.uv.now()
    if left <= 0 then
      error("timed out: " .. (label or "condition"), 2)
    end
    vim.wait(math.min(left, 100), cond, 10)
  end
end

local acp = require("acp")
local controller = require("acp.controller")
require("acp.inline.review").reset(vim.api.nvim_get_current_buf())

acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = {},
  layout = { input_height = 6 },
  inline = { review = { mode = "write" } },
})
vim.notify = function(m, l)
  if l and l >= 3 then
    io.write("N:" .. tostring(m) .. "\n")
  end
end
acp.open()

local failures = {}
local function check(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(err)
    io.write("FAIL " .. name .. "\n")
  else
    io.write("ok   " .. name .. "\n")
  end
end

local st = controller.state()
wait(function()
  return st.session ~= nil and st.client ~= nil
end, 8000, "session creation")

local file = tmp .. "/sample.lua"
vim.fn.writefile({ "local a = 1", "local INLINE_OLD = 2", "local c = 3", "local INLINE_OLD = 4" }, file)
vim.cmd("split " .. vim.fn.fnameescape(file))
local source_buf = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
local expected_session = st.session
local session_creations = 0
local new_session = st.client.new_session
st.client.new_session = function(...)
  session_creations = session_creations + 1
  return new_session(...)
end

local function select_line(line)
  return { 0, line, 1, 0 }
end

local function start(review, text)
  vim.api.nvim_set_current_win(source_win)
  pcall(vim.cmd, "stopinsert")
  require("acp.inline").open({
    review = review,
    mode = "V",
    pos1 = select_line(2),
    pos2 = select_line(2),
  })
  wait(function()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].filetype == "acp_inline"
  end, 3000, "inline prompt")
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { text or "replace the marker" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
end

-- Normal mode: no visual range. The cursor is only a hint and the request
-- decides the scope.
local function start_cursor(line, text)
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { line, 0 })
  require("acp.inline").open({ review = "write" })
  wait(function()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].filetype == "acp_inline"
  end, 3000, "inline prompt")
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { text or "replace the marker" })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
end

local function lines()
  return vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
end

---A write must reach disk again once the buffer is unlocked.
local function assert_writable()
  vim.api.nvim_buf_call(source_buf, function()
    vim.cmd("silent write")
  end)
  assert(vim.deep_equal(vim.fn.readfile(file), lines()), "the buffer did not write after unlocking")
end

check("direct mode rewrites only the selected line", function()
  require("acp.inline.review").reset(vim.api.nvim_get_current_buf())
  start("write")
  wait(function()
    return lines()[2] == "local INLINE_NEW = 2"
  end, 10000, "inline rewrite")
  local snapshot = lines()
  assert(snapshot[1] == "local a = 1", "line above changed: " .. vim.inspect(snapshot))
  assert(snapshot[4] == "local INLINE_OLD = 4", "out-of-range line changed: " .. vim.inspect(snapshot))
  vim.cmd("silent undo")
  wait(function()
    return lines()[2] == "local INLINE_OLD = 2"
  end, 3000, "undo")
end)

check("normal mode follows the request instead of an insert-only point", function()
  require("acp.inline.review").reset(source_buf)
  -- The cursor is on line 3 but the request edits line 2: no range filtering.
  start_cursor(3, "INLINE_NORMAL replace the marker")
  wait(function()
    return lines()[2] == "local INLINE_NEW = 2"
  end, 10000, "normal-mode edit")
  assert(lines()[3] == "local c = 3", "unrelated line changed: " .. vim.inspect(lines()))
  vim.cmd("silent undo")
  wait(function()
    return lines()[2] == "local INLINE_OLD = 2"
  end, 3000, "normal-mode undo")
end)

check("visual mode drops edits outside the selected range", function()
  require("acp.inline.review").reset(source_buf)
  start("write", "INLINE_VISUAL replace the marker INLINE_OUTSIDE")
  wait(function()
    return lines()[2] == "local INLINE_NEW = 2"
  end, 10000, "visual edit")
  vim.wait(200)
  assert(#lines() == 4, "out-of-range appended line was applied: " .. vim.inspect(lines()))
  vim.cmd("silent undo")
  wait(function()
    return lines()[2] == "local INLINE_OLD = 2"
  end, 3000, "visual undo")
end)

check("diff mode applies only after accepting the hunk", function()
  require("acp.inline.review").reset(vim.api.nvim_get_current_buf())
  start("diff", "EXPLICIT")
  wait(function()
    return require("acp.inline.diff_session").active(source_buf)
  end, 10000, "inline diff")
  assert(lines()[2] == "local INLINE_OLD = 2", "review changed the source before acceptance")
  vim.api.nvim_feedkeys(vim.keycode("ga"), "x", false)
  wait(function()
    return not require("acp.inline.diff_session").active(source_buf)
  end, 3000, "review finish")
  assert(lines()[2] == "local INLINE_NEW = 2", "accepted hunk was reverted")
  vim.cmd("silent undo")
  wait(function()
    return lines()[2] == "local INLINE_OLD = 2"
  end, 3000, "undo")
end)

check("rejecting the hunk restores the original", function()
  require("acp.inline.review").reset(vim.api.nvim_get_current_buf())
  start("diff", "EXPLICIT")
  wait(function()
    return require("acp.inline.diff_session").active(source_buf)
  end, 10000, "inline diff")
  vim.api.nvim_feedkeys(vim.keycode("gr"), "x", false)
  wait(function()
    return not require("acp.inline.diff_session").active(source_buf)
  end, 3000, "review finish")
  local snapshot = lines()
  assert(snapshot[2] == "local INLINE_OLD = 2", "rejected hunk stayed applied")
  assert(snapshot[1] == "local a = 1")
end)

check("always-accept makes the next change direct", function()
  local review = require("acp.inline.review")
  review.always_accept(vim.api.nvim_get_current_buf())
  start(nil)
  wait(function()
    return lines()[2] == "local INLINE_NEW = 2"
  end, 10000, "always accept")
  wait(function()
    return not require("acp.inline.diff_session").active(source_buf)
  end, 3000, "no review")
  review.reset(vim.api.nvim_get_current_buf())
  vim.cmd("silent undo")
end)

check("a running inline turn locks edits and writes until it finishes", function()
  -- An unsaved edit before the turn must survive it, and a `:w` during the
  -- turn must neither reach disk nor count as an external change.
  vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { "user edit" })
  start("write", "INLINE_DELAY")
  local before = vim.fn.readfile(file)
  assert(not vim.bo[source_buf].modifiable, "the source stayed editable during the turn")
  assert(not pcall(vim.api.nvim_buf_set_lines, source_buf, 1, 2, false, { "mid-turn edit" }))
  local notes = {}
  local notify = vim.notify
  vim.notify = function(message)
    notes[#notes + 1] = tostring(message)
  end
  vim.api.nvim_buf_call(source_buf, function()
    pcall(vim.cmd, "silent write")
  end)
  vim.notify = notify
  assert(vim.deep_equal(before, vim.fn.readfile(file)), "the write changed the disk mid-turn")
  assert(table.concat(notes, "\n"):find("locked until it finishes", 1, true), "no lock notification")
  wait(function()
    return not require("acp.inline").is_active() and st.session.status == "idle"
  end, 10000, "late result")
  assert(lines()[1] == "user edit", "an unsaved edit was lost: " .. vim.inspect(lines()))
  assert(lines()[2] == "local INLINE_NEW = 2", "the inline result was not applied")
  assert(vim.bo[source_buf].modifiable, "the source stayed locked after the turn")
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, vim.fn.readfile(file))
  vim.bo[source_buf].modified = false
  assert(vim.deep_equal(vim.fn.readfile(file), lines()), vim.inspect(lines()))
  assert_writable()
end)

check("cancelled inline settles before the next turn", function()
  start("write", "INLINE_SLOW")
  assert(require("acp.inline").stop())
  wait(function()
    return not require("acp.inline").is_active()
  end, 10000, "cancel settlement")
  assert(lines()[2] == "local INLINE_OLD = 2", "cancelled result applied")
  assert(st.session.status == "idle", "cancel left session busy")
  assert(vim.bo[source_buf].modifiable, "cancel left the source locked")
  assert_writable()
end)

check("a failed inline turn unlocks the source", function()
  start("write", "INLINE_DELETE replace the marker")
  wait(function()
    return not require("acp.inline").is_active() and st.session.status == "idle"
  end, 10000, "failed turn settlement")
  assert(vim.bo[source_buf].modifiable, "the failure path left the source locked")
  assert_writable()
end)

check("explicit diff overrides always accept", function()
  require("acp.inline.review").always_accept(source_buf)
  start("diff", "EXPLICIT")
  wait(function()
    return require("acp.inline.diff_session").active(source_buf)
  end, 10000, "one-off diff")
  vim.api.nvim_feedkeys("g3", "x", false)
  require("acp.inline.review").reset(source_buf)
  assert(lines()[2] == "local INLINE_OLD = 2")
end)

check("review mode uses the filetype at result time", function()
  local old = st.config.inline.review.by_filetype
  st.config.inline.review.by_filetype = { markdown = "diff" }
  start(nil, "INLINE_DELAY")
  vim.bo[source_buf].filetype = "markdown"
  wait(function()
    return require("acp.inline.diff_session").active(source_buf)
  end, 10000, "changed filetype")
  vim.api.nvim_feedkeys("g3", "x", false)
  vim.bo[source_buf].filetype = "lua"
  st.config.inline.review.by_filetype = old
end)

check("busy session rejects inline without sending another prompt", function()
  start("write", "INLINE_SLOW")
  local turn = st.session.turn
  vim.api.nvim_set_current_win(source_win)
  assert(require("acp.inline").open() == false, "overlapping inline opened")
  assert(st.session.turn == turn)
  require("acp.inline").stop()
  wait(function()
    return not require("acp.inline").is_active()
  end, 10000, "busy cancel")
end)

check("ordinary chat remains queued behind cancelled inline", function()
  start("write", "INLINE_SLOW")
  assert(controller.send_now("hello queued", nil, st.session))
  assert(#st.session.queue == 1, "ordinary chat was not queued")
  controller.cancel()
  wait(function()
    return not require("acp.inline").is_active() and st.session.status == "idle" and #st.session.queue == 0
  end, 15000, "queued chat settlement")
  assert(lines()[2] == "local INLINE_OLD = 2", "cancelled inline applied")
end)

check("ordinary busy turn rejects inline submission without consuming it", function()
  assert(controller.send_now("slow", nil, st.session))
  local turn = st.session.turn
  start("write")
  assert(require("acp.inline.ui").is_open(), "busy inline input was lost")
  assert(st.session.turn == turn, "inline submitted an overlapping turn")
  require("acp.inline.ui").close()
  controller.cancel()
  wait(function()
    return st.session.status == "idle"
  end, 10000, "ordinary cancellation")
end)

check("a private copy is removed after the request", function()
  local copy = require("acp.inline.copy")
  local dir = vim.fs.dirname(file)
  local leftovers = vim.fn.glob(dir .. "/.acp-inline-*", false, true)
  assert(#leftovers == 0, "inline copy left behind: " .. vim.inspect(leftovers))
  assert(copy)
end)

check("inline reuses the current session without creating another", function()
  assert(st.session == expected_session, "inline changed the selected session")
  assert(session_creations == 0, "inline created a new ACP session")
end)

check("disconnect invalidates an in-flight inline result", function()
  start("write", "INLINE_DELAY")
  controller.disconnect()
  assert(not require("acp.inline").is_active(), "disconnect retained inline ownership")
  vim.wait(300)
  assert(lines()[2] == "local INLINE_OLD = 2", "late disconnected result applied")
  assert(vim.bo[source_buf].modifiable, "disconnect left the source locked")
  assert_writable()
  assert(#vim.fn.glob(tmp .. "/.acp-inline-*", false, true) == 0, "disconnect leaked copy")
end)

vim.fn.delete(tmp, "rf")
pcall(controller.disconnect)

if #failures > 0 then
  error("integration inline failures:\n  " .. table.concat(failures, "\n  "), 0)
end
io.write("all inline integration checks passed\n")
vim.cmd("qa!")
