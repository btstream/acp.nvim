-- Integration: reconnect and session restoration.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
local acp = require("acp")
local controller = require("acp.controller")

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

acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = {},
})
acp.open()
local st = controller.state()

vim.wait(8000, function()
  return st.session ~= nil
end, 20)
check("session starts", function()
  assert(st.session ~= nil, "no session")
end)

-- Simulate a crash.
st.client:shutdown(true)
vim.wait(500)
check("crash is reported", function()
  assert(st.connection == "disconnected", "expected disconnected, got " .. tostring(st.connection))
end)

controller.reconnect()
vim.wait(12000, function()
  if st.connection ~= "ready" or st.session == nil then
    return false
  end
  for _, block in ipairs(st.session.blocks) do
    if block.kind == "agent" and (block.text or ""):find("old answer", 1, true) then
      return true
    end
  end
  return false
end, 50)

check("reconnect restores the session", function()
  assert(st.connection == "ready", "not ready")
  assert(st.session.id == "sess_mock", "wrong session")
end)

check("history is replayed after reconnect", function()
  local kinds = vim.tbl_map(function(b)
    return b.kind
  end, st.session.blocks)
  assert(vim.tbl_contains(kinds, "user"), "no user block")
  assert(vim.tbl_contains(kinds, "agent"), "no agent block")
end)

-- Blocks are rendered on a deferred tick (`Chat:schedule_render` waits 40ms), so
-- the state can be complete while the buffer is still empty. Wait for the buffer
-- itself rather than reading it straight after the state check.
vim.wait(3000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  return text:find("old answer", 1, true) ~= nil
end, 20)

check("transcript shows the replayed history", function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  assert(text:find("old answer", 1, true), "replayed answer missing")
end)

acp.hide()

if #failures > 0 then
  io.write("\n" .. #failures .. " reconnect failures:\n")
  for _, f in ipairs(failures) do
    io.write("  - " .. f .. "\n")
  end
  vim.cmd("cq 1")
else
  io.write("\nall reconnect checks passed\n")
  vim.cmd("qa!")
end
