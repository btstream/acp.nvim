-- Integration test for the phase-7 inline safety work:
--   * an agent writing the source file directly instead of the copy
--   * an irreversible tool kind (`delete`) under allow_commands
--   * a question asked mid-turn
--
-- Kept separate from integration_inline.lua because these flows need their own
-- permission handling: the picker is stubbed so a headless run never blocks.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function wait(cond, timeout, label)
  if not vim.wait(timeout or 10000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

local acp = require("acp")
local controller = require("acp.controller")
local picker = require("acp.ui.picker")

-- No check here drives a permission dialog by hand.
local real_select = picker.select
picker.select = function() end

acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = {},
  layout = { input_height = 6 },
  permissions = { prompt = "select" },
  inline = { review = { mode = "write" }, guard_mode = "off" },
})

local notes = {}
vim.notify = function(message, level)
  notes[#notes + 1] = { message = tostring(message), level = level }
end

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

-- Open the source file before the panel exists: panel windows lock their
-- buffer, so `:edit` would be refused in one of them.
local file = tmp .. "/sample.lua"
vim.fn.writefile({ "local a = 1", "local INLINE_OLD = 2", "local c = 3" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
local source_win = vim.api.nvim_get_current_win()

acp.open()
local st = controller.state()
wait(function()
  return st.session ~= nil and st.client ~= nil and st.connection == "ready"
end, 8000, "session creation")

local function reset_file()
  vim.fn.writefile({ "local a = 1", "local INLINE_OLD = 2", "local c = 3" }, file)
  vim.api.nvim_set_current_win(source_win)
  vim.cmd("edit! " .. vim.fn.fnameescape(file))
  require("acp.inline.review").reset(vim.api.nvim_get_current_buf())
end
reset_file()

local function select_line(line)
  return { 0, line, 1, 0 }
end

---Start an inline edit on line 2 and submit `text`.
local function start(text)
  vim.api.nvim_set_current_win(source_win)
  require("acp.inline").open({
    review = "write",
    mode = "V",
    pos1 = select_line(2),
    pos2 = select_line(2),
  })
  wait(function()
    local buf = vim.api.nvim_get_current_buf()
    return vim.bo[buf].filetype == "acp_inline"
  end, 5000, "inline prompt window")
  vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { text })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
end

local function lines()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
end

local function settle()
  require("acp.inline").stop()
  vim.wait(2000, function()
    return st.session == nil or (st.session.status == "idle" and not require("acp.inline").is_active())
  end, 20)
end

-- 1. Direct write to the source file -----------------------------------------

check("a direct write to the source file is detected and not applied", function()
  settle()
  reset_file()
  local offered
  picker.select = function(opts)
    offered = opts
  end
  start("replace the marker; INLINE_DIRECT_WRITE")
  wait(function()
    return offered ~= nil
  end, 10000, "direct-write recovery picker")
  picker.select = real_select

  assert(offered and #offered.items == 3, "expected three recovery choices")
  -- The reviewed edit must not be applied on top of the agent's write.
  assert(lines()[2] == "local INLINE_OLD = 2", "the reviewed edit was applied anyway")
  local disk = vim.fn.readfile(file)
  assert(disk[1] == "DIRECTLY WRITTEN BY AGENT", "the agent's write is missing: " .. vim.inspect(disk))

  local reload
  for _, item in ipairs(offered.items) do
    if item.value == "reload" then
      reload = item
    end
  end
  assert(reload, "no reload choice")
  offered.on_choice(reload.value)
  wait(function()
    return lines()[1] == "DIRECTLY WRITTEN BY AGENT"
  end, 3000, "reload from disk")
end)

-- 2. A delete is not covered by allow_commands --------------------------------

check("a delete is refused unless allow_kinds lists it", function()
  settle()
  reset_file()
  -- The inline policy answers through the interaction broker, not through
  -- `client:resolve_permission`, so the decision is observed on the wire: the
  -- mock reports the option it received.
  local answered
  local original_answer = st.interactions.answer
  st.interactions.answer = function(interactions, id, response)
    local interaction = interactions:get(id)
    if interaction and interaction.type == "permission" then
      answered = response
    end
    return original_answer(interactions, id, response)
  end
  start("INLINE_DELETE replace the marker")
  wait(function()
    return answered ~= nil
  end, 10000, "delete permission decision")
  st.interactions.answer = original_answer
  local outcome = answered and answered.outcome or {}
  assert(outcome.outcome == "selected", "expected an explicit option: " .. vim.inspect(answered))
  assert(outcome.optionId == "reject", "a delete was allowed by allow_commands: " .. tostring(outcome.optionId))
end)

-- 3. A question mid-turn reaches the user -------------------------------------

check("a question during an inline turn is left to the user", function()
  settle()
  reset_file()
  local asked
  local interactions = st.interactions
  local original_present = interactions.presenters.elicitation.present
  interactions.presenters.elicitation.present = function(interaction)
    asked = interaction
    return true
  end
  start("INLINE_ASK replace the marker")
  wait(function()
    return asked ~= nil
  end, 10000, "inline question reached the presenter")
  interactions.presenters.elicitation.present = original_present
  assert(asked.type == "elicitation", "expected an elicitation, got " .. tostring(asked.type))
  interactions:answer(asked.id, { action = "cancel" })
  vim.wait(800)
end)

vim.fn.delete(tmp, "rf")
pcall(controller.disconnect)

if #failures > 0 then
  error("inline safety integration failures:\n  " .. table.concat(failures, "\n  "), 0)
end
io.write("all inline safety integration checks passed\n")
vim.cmd("qa!")
