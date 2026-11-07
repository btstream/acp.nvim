-- Performance smoke test: nvim --headless -u tests/minimal_init.lua -l tests/perf.lua
local config = require("acp.config")
local state = require("acp.session.state")
local Chat = require("acp.ui.chat")
local blocks = require("acp.ui.blocks")

local cfg = config.validate(config.merge(config.defaults, { ui = { language = "en" } }))
local chat = Chat.new({ config = cfg })
chat.width = 80

local session = state.new("perf", "/tmp")

local function ms(fn)
  local t0 = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - t0) / 1e6
end

local report = {}

local function check(name, elapsed, limit)
  local ok = elapsed <= limit
  report[#report + 1] = string.format("%s %-46s %8.1fms (limit %dms)", ok and "ok  " or "FAIL", name, elapsed, limit)
  return ok
end

local all_ok = true

-- 1. Initial render of 1000 blocks.
for i = 1, 1000 do
  if i % 3 == 0 then
    session:append({
      id = "t" .. i,
      kind = "tool",
      title = "Tool " .. i,
      status = i % 6 == 0 and "failed" or "completed",
      detail = "result for tool " .. i,
    })
  else
    session:append({
      id = "a" .. i,
      kind = "agent",
      text = string.rep("Some response text for block " .. i .. ". ", 8),
    })
  end
end

local elapsed = ms(function()
  chat:set_session(session)
  chat:render()
end)
all_ok = check("initial render of 1000 blocks", elapsed, 1500) and all_ok

-- 2. Streaming: append a chunk 200 times; only the last block must re-render.
session:append({ id = "stream", kind = "agent", text = "" })
chat:render()
elapsed = ms(function()
  for i = 1, 200 do
    session.blocks[#session.blocks].text = session.blocks[#session.blocks].text .. "chunk " .. i .. " "
    chat:render()
  end
end)
all_ok = check("200 streaming updates with 1000 blocks", elapsed, 1500) and all_ok

-- 3. Toggle a mid-transcript tool block.
local target = session.blocks[500]
elapsed = ms(function()
  target.expanded = true
  chat:render()
end)
all_ok = check("expand one block in a long transcript", elapsed, 300) and all_ok

-- 4. Markdown rendering of a large block.
local big = string.rep("# Heading\n\nSome paragraph with `code` and more text.\n\n```lua\nlocal x = 1\n```\n\n", 200)
elapsed = ms(function()
  blocks.render_text(big, "AcpAssistant", 80)
end)
all_ok = check("markdown rendering of ~1600 lines", elapsed, 400) and all_ok

-- 5. Toolbar rendering is cheap and can run every animation frame.
elapsed = ms(function()
  local toolbar = require("acp.ui.toolbar")
  for _ = 1, 1000 do
    toolbar.render({ mode = "Build", model = "Claude Sonnet 5", status = "running", spinner = "*" }, 80)
  end
end)
all_ok = check("1000 toolbar renders", elapsed, 300) and all_ok

-- 6. Buffer line count sanity: the transcript should be complete.
local line_count = vim.api.nvim_buf_line_count(chat.buf)
report[#report + 1] = string.format("info   transcript lines: %d", line_count)
if line_count < 1000 then
  all_ok = false
  report[#report + 1] = "FAIL   transcript looks truncated"
end

io.write(table.concat(report, "\n") .. "\n")
if all_ok then
  io.write("\nperformance checks passed\n")
  vim.cmd("qa!")
else
  io.write("\nperformance checks failed\n")
  vim.cmd("cq 1")
end
