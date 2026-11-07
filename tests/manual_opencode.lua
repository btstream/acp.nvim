-- Real OpenCode end-to-end check (requires a logged in `opencode`).
local controller = require("acp.controller")
local acp = require("acp")

acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "opencode", args = { "acp" } } },
  ui = {},
  layout = { input_height = 6 },
})

acp.open()
local st = controller.state()

vim.wait(30000, function()
  return st.session ~= nil
end, 50)
print("SESSION:", st.session and st.session.id, "connection:", st.connection)
if not st.session then
  vim.cmd("qa!")
  return
end

local reducer = require("acp.session.reducer")
local model, mode = reducer.toolbar_labels(st.session)
print("MODEL:", model, "| MODE:", mode)
print("OPTIONS:", #(st.session.config_options or {}))

controller.submit("Reply with exactly one word: PONG", {})

local done = vim.wait(180000, function()
  return st.session.status == "idle" and #st.session.blocks > 1
end, 200)
print("FINISHED:", done, "status:", st.session.status, "blocks:", #st.session.blocks)
print("---- transcript ----")
print(table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n"))
print("---- usage ----")
print(vim.inspect(st.session.usage))
print("---- error ----")
print(vim.inspect(st.session.last_error))
acp.hide()
vim.cmd("qa!")
