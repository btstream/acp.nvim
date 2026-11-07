-- Minimal test harness (no external dependencies).
local M = {}

local tests = {}
local current_file = "?"

function M.describe(name, fn)
  current_file = name
  fn()
end

---@param name string
---@param fn fun()
function M.it(name, fn)
  tests[#tests + 1] = { name = current_file .. " :: " .. name, fn = fn }
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
  local passed, failed = 0, 0
  local failures = {}
  for _, test in ipairs(tests) do
    local ok, err = xpcall(test.fn, debug.traceback)
    if ok then
      passed = passed + 1
      io.write("ok   " .. test.name .. "\n")
    else
      failed = failed + 1
      failures[#failures + 1] = { name = test.name, err = err }
      io.write("FAIL " .. test.name .. "\n")
    end
  end
  io.write(string.format("\n%d passed, %d failed\n", passed, failed))
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
