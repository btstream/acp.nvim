-- Test entrypoint: nvim --headless -u tests/minimal_init.lua -l tests/run.lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:append(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

local t = require("tests.harness")

require("tests.spec_framing")(t)
require("tests.spec_jsonrpc")(t)
require("tests.spec_config")(t)
require("tests.spec_reducer")(t)
require("tests.spec_toolbar")(t)
require("tests.spec_layout")(t)
require("tests.spec_renderer")(t)
require("tests.spec_client")(t)
require("tests.spec_ui")(t)
require("tests.spec_complete")(t)
require("tests.spec_permissions")(t)
require("tests.spec_drafts")(t)
require("tests.spec_panel")(t)
require("tests.spec_window_lock")(t)
require("tests.spec_sessions")(t)
require("tests.spec_sessions_snacks")(t)

t.run()
