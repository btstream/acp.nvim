-- Minimal test harness (no external dependencies).
local M = {}

local tests = {}
local current_file = "?"

-- Per-test cleanup hooks and persistent after-each hooks. Cleanups run in
-- reverse order even when the test failed, so a failure cannot leak windows,
-- processes or replaced globals into every following test.
local cleanups = {}
local after_each = {}

---Register a cleanup for the current test. Runs after the test, pass or fail.
---@param fn fun()
function M.cleanup(fn)
  assert(type(fn) == "function", "cleanup must be a function")
  cleanups[#cleanups + 1] = fn
end

---Register a cleanup that runs after every test.
---@param fn fun()
function M.after_each(fn)
  assert(type(fn) == "function", "after_each must be a function")
  after_each[#after_each + 1] = fn
end

local function snapshot()
  local functions = {
    { vim, "notify" },
    { vim.ui, "select" },
    { vim.ui, "input" },
    { vim.api, "nvim_open_win" },
    { vim.api, "nvim__redraw" },
    { vim.api, "nvim_set_option_value" },
    { vim, "schedule" },
    { vim, "system" },
    { vim, "paste" },
    { vim.fn, "jobstart" },
    { vim.fn, "jobstop" },
    { vim.fn, "chansend" },
    { vim.fn, "has" },
    { vim.treesitter, "get_string_parser" },
    { vim.uv, "hrtime" },
    { vim.uv, "fs_rename" },
    { vim.uv, "fs_mkstemp" },
    { vim.uv, "fs_read" },
    { vim.uv, "fs_write" },
  }
  local saved = {}
  for _, entry in ipairs(functions) do
    saved[#saved + 1] = { entry[1], entry[2], entry[1][entry[2]] }
  end
  local options = {
    "laststatus",
    "columns",
    "lines",
    "splitkeep",
    "swapfile",
    "shadafile",
    "mouse",
    "diffopt",
    "splitright",
    "winwidth",
    "winminwidth",
  }
  local saved_options = {}
  for _, name in ipairs(options) do
    saved_options[#saved_options + 1] = { name, vim.o[name] }
  end
  return saved, saved_options
end

local function restore(saved, saved_options)
  for _, entry in ipairs(saved) do
    pcall(function()
      entry[1][entry[2]] = entry[3]
    end)
  end
  for _, entry in ipairs(saved_options) do
    pcall(function()
      vim.o[entry[1]] = entry[2]
    end)
  end
end

local function reset_layout()
  local tabs = vim.api.nvim_list_tabpages()
  local keep_tab = tabs[1]
  for index = #tabs, 2, -1 do
    pcall(vim.api.nvim_tabpage_close, tabs[index], true)
  end
  if not keep_tab or not vim.api.nvim_tabpage_is_valid(keep_tab) then
    vim.cmd("tabnew")
    keep_tab = vim.api.nvim_get_current_tabpage()
  end
  pcall(vim.api.nvim_set_current_tabpage, keep_tab)
  local wins = vim.api.nvim_tabpage_list_wins(keep_tab)
  local keep_win
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
      keep_win = keep_win or win
    end
  end
  keep_win = keep_win or wins[1]
  for _, win in ipairs(wins) do
    if win ~= keep_win then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if not keep_win or not vim.api.nvim_win_is_valid(keep_win) then
    vim.cmd("new")
  else
    pcall(vim.api.nvim_set_current_win, keep_win)
  end
end

local function reset_buffers(baseline_buf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= baseline_buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if not vim.api.nvim_buf_is_valid(baseline_buf) then
    baseline_buf = vim.api.nvim_create_buf(true, false)
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= baseline_buf then
    pcall(vim.api.nvim_win_set_buf, win, baseline_buf)
  end
  return baseline_buf
end

local function run_hooks(hooks, label)
  for index = #hooks, 1, -1 do
    local ok, err = xpcall(hooks[index], debug.traceback)
    if not ok then
      io.write("cleanup error in " .. label .. ": " .. tostring(err):gsub("\n%s*stack traceback.*", "") .. "\n")
    end
  end
end

function M.describe(name, fn)
  current_file = name
  fn()
end

---@param name string
---@param fn fun()
function M.it(name, fn)
  tests[#tests + 1] = { name = current_file .. " :: " .. name, fn = fn }
end

---A known gap: the test describes the intended behaviour and is expected to
---fail until the work that fixes it lands. A failure is reported as pending,
---not as a failure; an unexpected pass is a failure ("XPASS"), so the marker
---is removed as soon as the behaviour exists.
---@param name string
---@param reason string what is missing, e.g. "phase 3: elicitation"
---@param fn fun()
function M.pending(name, reason, fn)
  tests[#tests + 1] = { name = current_file .. " :: " .. name, fn = fn, pending = reason }
end

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(
      string.format(
        "%s\n  expected: %s\n  actual:   %s",
        message or "values differ",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

function M.falsy(value, message)
  if value then
    error(message or "expected a falsy value", 2)
  end
end

function M.match(pattern, value, message)
  if type(value) ~= "string" or not value:match(pattern) then
    error(
      string.format("%s\n  pattern: %s\n  value: %s", message or "pattern did not match", pattern, vim.inspect(value)),
      2
    )
  end
end

function M.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("expected an error", 2)
  end
  if pattern and not tostring(err):match(pattern) then
    error(string.format("error did not match %s: %s", pattern, tostring(err)), 2)
  end
end

function M.run()
  local passed, failed, pending = 0, 0, 0
  local failures = {}
  local saved, saved_options = snapshot()
  local baseline_buf = vim.api.nvim_get_current_buf()
  for _, test in ipairs(tests) do
    cleanups = {}
    local ok, err = xpcall(test.fn, debug.traceback)
    if #cleanups > 0 then
      run_hooks(cleanups, test.name)
    end
    cleanups = {}
    if #after_each > 0 then
      run_hooks(after_each, "after_each")
    end
    restore(saved, saved_options)
    pcall(reset_layout)
    baseline_buf = reset_buffers(baseline_buf)
    if test.pending then
      if ok then
        failed = failed + 1
        failures[#failures + 1] = {
          name = test.name,
          err = "XPASS: marked pending (" .. test.pending .. ") but passed; turn it into a normal test",
        }
        io.write("XPASS " .. test.name .. "\n")
      else
        pending = pending + 1
        io.write("pend " .. test.name .. "  [" .. test.pending .. "]\n")
        -- ACP_TEST_PENDING=1 shows why each pending test fails, so a broken
        -- test cannot hide behind the marker.
        if os.getenv("ACP_TEST_PENDING") == "1" then
          io.write("     " .. (tostring(err):gsub("\n%s*stack traceback.*", ""):gsub("\n", " ")) .. "\n")
        end
      end
    elseif ok then
      passed = passed + 1
      io.write("ok   " .. test.name .. "\n")
    else
      failed = failed + 1
      failures[#failures + 1] = { name = test.name, err = err }
      io.write("FAIL " .. test.name .. "\n")
    end
  end
  io.write(string.format("\n%d passed, %d failed, %d pending\n", passed, failed, pending))
  for _, failure in ipairs(failures) do
    io.write("\n--- " .. failure.name .. " ---\n" .. tostring(failure.err) .. "\n")
  end
  if failed > 0 then
    vim.cmd("cq 1")
  else
    vim.cmd("qa!")
  end
end

return M
