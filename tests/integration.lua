-- Integration test: drives the real panel against the mock agent.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

local function wait(cond, timeout, label)
  if not vim.wait(timeout or 8000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

local acp = require("acp")
local controller = require("acp.controller")

acp.setup({
  agent = "opencode",
  agents = {
    opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } },
  },
  ui = {},
  layout = { input_height = 6 },
})

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

for _, laststatus in ipairs({ 0, 2, 3 }) do
  vim.o.laststatus = laststatus
  local before_statusline = vim.o.statusline
  local before_laststatus = vim.o.laststatus
  acp.setup({
    agent = "opencode",
    agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
    ui = {},
    layout = { input_height = 6 },
  })
  acp.open()

  local st = controller.state()
  wait(function()
    return st.session ~= nil
  end, 8000, "session creation")
  check("laststatus=" .. laststatus .. " creates both windows", function()
    assert(st.chat and st.chat:is_visible(), "chat window missing")
    assert(st.input and st.input:is_visible(), "composer window missing")
  end)

  check("laststatus=" .. laststatus .. " chat buffer is acp_chat", function()
    assert(vim.bo[st.chat.buf].filetype == "acp_chat", "wrong filetype")
  end)

  check("laststatus=" .. laststatus .. " composer winbar is set", function()
    local ok = vim.api.nvim_win_is_valid(st.input.win)
    assert(ok, "invalid composer window")
    local winbar = vim.api.nvim_get_option_value("winbar", { win = st.input.win })
    assert(winbar and #winbar > 0, "composer winbar is empty")
  end)

  check("laststatus=" .. laststatus .. " does not touch the global statusline", function()
    assert(vim.o.statusline == before_statusline, "statusline was modified")
    assert(vim.o.laststatus == before_laststatus, "laststatus was modified")
  end)

  acp.hide()
  check("laststatus=" .. laststatus .. " hide keeps the session", function()
    assert(st.session ~= nil, "session was discarded on hide")
  end)
end

-- Full conversation through the UI.
vim.o.laststatus = 3
acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = {},
  layout = { input_height = 6 },
})
acp.open()

local st = controller.state()
wait(function()
  return st.session ~= nil
end, 8000, "session creation")
acp.hide()
acp.open()

controller.submit("hello there", {})

wait(function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  return text:find("Hello from the mock agent", 1, true) ~= nil
end, 10000, "streamed reply")

check("transcript shows the streamed reply", function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  assert(text:find("Hello from the mock agent", 1, true), "missing reply")
  assert(text:find("hello there", 1, true), "missing user message")
  assert(text:find("Plan", 1, true), "missing plan block")
end)

check("usage is tracked", function()
  assert(st.session.usage and st.session.usage.used == 1200, "usage not tracked")
end)

check("toolbar reflects an idle session after the turn", function()
  local winbar = vim.api.nvim_get_option_value("winbar", { win = st.input.win })
  local res = vim.api.nvim_eval_statusline(winbar, {
    winid = st.input.win,
    maxwidth = vim.api.nvim_win_get_width(st.input.win),
    use_winbar = true,
  })
  -- The status is a glyph, not the word "Idle".
  local ic = require("acp.ui.icons").get(true)
  assert(res.str:find(ic.status_idle, 1, true), "toolbar did not return to idle: " .. tostring(res.str))
end)

-- Queuing while running.
controller.submit("slow one", {})
controller.submit("queued message", {})
check("messages submitted during a turn are queued", function()
  assert(st.session.status == "running", "session should be running")
  assert(#st.session.queue >= 1, "nothing queued")
end)
acp.cancel()
wait(function()
  return st.session.status == "idle"
end, 10000, "cancellation")

-- Add a selection attachment: move to a normal window first, because the
-- composer is locked to its own buffer.
check("selections can be attached", function()
  local main
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
    if ft ~= "acp_chat" and ft ~= "acp_input" then
      main = win
      break
    end
  end
  assert(main, "no main window to move to")
  vim.api.nvim_set_current_win(main)
  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line one", "line two" })
  vim.bo.buftype = ""
  vim.cmd("write! /tmp/acp_sel_test.lua")
  vim.cmd("normal! ggVj")
  vim.cmd("normal! \27")
  vim.fn.setpos("'<", { 0, 1, 1, 0 })
  vim.fn.setpos("'>", { 0, 2, 8, 0 })
  acp.add_selection()
  assert(#st.input.attachments == 1, "attachment missing")
  assert(st.input.attachments[1].kind == "selection", "wrong attachment kind")
end)

-- Draining the queue after cancel should not deadlock.
wait(function()
  return #st.session.queue == 0
end, 15000, "queue drain")

-- Two prompts submitted back to back must run sequentially. The agent rejects
-- an overlapping prompt, so a stale `prompt_finished` marking the freshly
-- started turn idle used to surface as "Session already has an active ACP
-- prompt" on the next send.
controller.submit("first fast one", {})
controller.submit("second fast one", {})
check("back-to-back prompts both complete", function()
  wait(function()
    return st.session.status == "idle" and #st.session.queue == 0
  end, 20000, "sequential turns")
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  assert(not text:find("already has an active ACP prompt", 1, true), "overlapping prompt was rejected")
end)

-- A turn delegated to a subagent: opencode tags the updates it produces with
-- `_meta["opencode/child-session"]`, and the transcript must label them without
-- leaking the child session's own traffic.
controller.submit("run the subagent", {})

wait(function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  return text:find("call sites", 1, true) ~= nil
end, 15000, "subagent turn")

check("transcript labels the subagent turn", function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  -- The panel is narrow here, so only the start of the agent supplied title is
  -- shown; the label itself must survive.
  assert(text:find("subagent: ", 1, true), "the subagent label is missing")
  assert(text:find("two call sites", 1, true), "the delegated answer is missing")
end)

check("child session updates stay out of the transcript", function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  assert(not text:find("CHILD-INTERNAL-ONLY", 1, true), "a child session update leaked into the parent transcript")
end)

check("the subagent label keeps the header inside the panel", function()
  local width = vim.api.nvim_win_get_width(st.chat.win)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false)) do
    assert(
      vim.api.nvim_strwidth(line) <= width,
      string.format("a transcript line is %d cells at width %d: %s", vim.api.nvim_strwidth(line), width, line)
    )
  end
end)

-- Nothing should be left running once the queue drained.
check("no prompt outlived the queue", function()
  wait(function()
    return st.session.status == "idle"
  end, 10000, "idle after queue")
  assert(#st.session.queue == 0, "queue not empty")
end)

acp.hide()

if #failures > 0 then
  io.write("\n" .. #failures .. " integration failures:\n")
  for _, f in ipairs(failures) do
    io.write("  - " .. f .. "\n")
  end
  vim.cmd("cq 1")
else
  io.write("\nall integration checks passed\n")
  vim.cmd("qa!")
end
