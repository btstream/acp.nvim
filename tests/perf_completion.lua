-- nvim --headless -i NONE -u tests/minimal_init.lua -l tests/perf_completion.lua
-- No optional completion framework is needed. Measures discovery + full-item
-- materialisation, not just the first 200 paths or an empty hidden buffer.
local core = require("acp.completion")
local Config = require("acp.config")
local root = "/tmp/opencode"
local config = Config.validate(Config.merge(Config.defaults, {
  completion = {
    files = {
      root = root,
      command = {
        "python3",
        "-c",
        "import os;os.write(1,b''.join(('deep/folder/file%d.lua'%i).encode()+b'\\0' for i in range(10000))+b'deep/z-last-target.lua\\0')",
      },
    },
  },
}))
local buf = vim.api.nvim_create_buf(false, true)
local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 60, height = 8 })
vim.bo[buf].filetype = "acp_input"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@z " })
vim.api.nvim_win_set_cursor(win, { 1, 2 })
local session = { cwd = root }
core.attach(buf, function()
  return session
end, config)
local ticks = 0
local timer = vim.uv.new_timer()
timer:start(1, 1, function()
  ticks = ticks + 1
end)
local function run(label)
  local started = vim.uv.hrtime()
  local result, problem
  core.request(buf, 0, 2, function(items, err)
    result, problem = items, err
  end)
  assert(
    vim.wait(5000, function()
      return result ~= nil
    end, 1),
    "completion timed out"
  )
  assert(not problem, problem)
  assert(#result == 10001, "completion returned an incomplete project index")
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  io.write(string.format("ok %s: %d candidates in %.1fms\n", label, #result, elapsed))
  local native = core.native_items(result, { kind = "file", query = "zlasttarget" }, 1)
  assert(#native == 1 and native[1].word == "@deep/z-last-target.lua", "late fuzzy match was truncated")
end
run("cold scan")
run("cached index")
timer:stop()
timer:close()
assert(ticks > 1, "large completion did not yield to the event loop")
io.write(string.format("ok event-loop progress: %d timer ticks\n", ticks))
core.detach(buf)
core.refresh()
vim.api.nvim_win_close(win, true)
vim.api.nvim_buf_delete(buf, { force = true })
io.write("all completion performance checks passed\n")
vim.cmd("qa!")
