-- Run the real panel/mock-agent integration suites with A+B enabled.
-- nvim --headless -u tests/minimal_init.lua -l tests/integration_lazy.lua [native|edgy|reconnect]
local suites = { native = "integration.lua", edgy = "integration_edgy.lua", reconnect = "integration_reconnect.lua" }
local suite = assert(suites[arg[1] or "native"], "expected native, edgy or reconnect")
local acp = require("acp")
local setup = acp.setup
acp.setup = function(opts)
  return setup(vim.tbl_deep_extend(
    "force",
    opts or {},
    { ui = { render = {
      lazy_syntax = true,
      pagination = { enabled = true },
    } } }
  ))
end
dofile(vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. "tests/" .. suite)
