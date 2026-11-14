-- Test entrypoint: nvim --headless -u tests/minimal_init.lua -l tests/run.lua
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
vim.opt.runtimepath:append(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- Safety net: the suite deletes drafts and writes logs. If minimal_init was
-- skipped or its overrides were lost, refuse to run instead of touching the
-- user's real state/cache/data.
local real_home = vim.fs.normalize(vim.fn.expand("~")) .. "/.local"
for _, kind in ipairs({ "data", "state", "cache" }) do
  local path = vim.fs.normalize(vim.fn.stdpath(kind))
  if path:sub(1, #real_home + 1) == real_home .. "/" or path == real_home then
    error(string.format("tests are not isolated: stdpath(%q) is %s (run with tests/minimal_init.lua)", kind, path), 0)
  end
end
-- Tripwire: a rename into the real state tree is a leak and shows up in the
-- test output (drafts use rename for its atomicity).
local real_rename = vim.uv.fs_rename
vim.uv.fs_rename = function(from, to, ...)
  if tostring(to):find(real_home .. "/state", 1, true) then
    io.write("REAL RENAME " .. tostring(from) .. " -> " .. tostring(to) .. "\n")
  end
  return real_rename(from, to, ...)
end

local t = require("tests.harness")

-- Baseline cleanup for every case. Specs replace globals, open windows, start
-- processes and call setup; a failed assertion skips their hand-written
-- teardown, so the harness restores all of it here.
local controller = require("acp.controller")
local drafts = require("acp.storage.drafts")
local drafts_path = drafts.path
local setup_calls, torn_down = 0, 0
local raw_setup = controller.setup
controller.setup = function(...)
  setup_calls = setup_calls + 1
  return raw_setup(...)
end
t.after_each(function()
  -- Let callbacks scheduled by the test run before their state disappears.
  vim.wait(1)
  local inline = package.loaded["acp.inline"]
  if inline then
    pcall(inline.invalidate)
  end
  if setup_calls ~= torn_down then
    torn_down = setup_calls
    pcall(raw_setup, {}, { discard_queued = true })
    -- The agent store caches session titles/cwds across setups; without a new
    -- cache a later test sees a previous test's title for the same mock session.
    pcall(function()
      controller.state().sess.agent_store = {}
    end)
  end
  drafts.clear()
  drafts.path = drafts_path
  vim.wait(1)
end)

require("tests.spec_framing")(t)
require("tests.spec_jsonrpc")(t)
require("tests.spec_config")(t)
require("tests.spec_capabilities")(t)
require("tests.spec_reducer")(t)
require("tests.spec_toolbar")(t)
require("tests.spec_layout")(t)
require("tests.spec_renderer")(t)
require("tests.spec_client")(t)
require("tests.spec_protocol_conformance")(t)
require("tests.spec_early_update")(t)
require("tests.spec_ui")(t)
require("tests.spec_complete")(t)
require("tests.spec_completion_sources")(t)
require("tests.spec_image")(t)
require("tests.spec_inline")(t)
require("tests.spec_inline_edit")(t)
require("tests.spec_permissions")(t)
require("tests.spec_permission_details")(t)
require("tests.spec_auth")(t)
require("tests.spec_auth_flow")(t)
require("tests.spec_auth_retry")(t)
require("tests.spec_controls")(t)
require("tests.spec_controls_flow")(t)
require("tests.spec_presentation")(t)
require("tests.spec_inline_safety")(t)
require("tests.spec_interactions")(t)
require("tests.spec_elicitation_schema")(t)
require("tests.spec_elicitation")(t)
require("tests.spec_drafts")(t)
require("tests.spec_panel")(t)
require("tests.spec_window_lock")(t)
require("tests.spec_sessions")(t)
require("tests.spec_sessions_snacks")(t)
require("tests.spec_session_scope")(t)
require("tests.spec_newlines")(t)
require("tests.spec_edgy_views")(t)
require("tests.spec_layout_sizing")(t)
require("tests.spec_highlights")(t)
require("tests.spec_pickers")(t)
require("tests.spec_keymaps")(t)
require("tests.spec_diff")(t)
require("tests.spec_async")(t)
require("tests.spec_optimizations")(t)
require("tests.spec_backgrounds")(t)
require("tests.spec_markdown")(t)
require("tests.spec_code_hl")(t)
require("tests.spec_cards")(t)
require("tests.spec_thoughts")(t)
require("tests.spec_tables")(t)
require("tests.spec_separator")(t)
require("tests.spec_subagent")(t)
require("tests.spec_audit")(t)
require("tests.spec_performance")(t)
require("tests.spec_lifecycle")(t)
require("tests.spec_modules")(t)
require("tests.spec_chrome_lifecycle")(t)
require("tests.spec_resize")(t)
require("tests.spec_transport_limits")(t)
require("tests.spec_chunking")(t)
require("tests.spec_lazy_render")(t)
require("tests.spec_history_page")(t)
require("tests.spec_spinner")(t)
require("tests.spec_scheduling")(t)
require("tests.spec_commit")(t)
require("tests.spec_tail")(t)
require("tests.spec_session_management")(t)
require("tests.spec_session_lifecycle")(t)
require("tests.spec_architecture")(t)
require("tests.spec_agent_manager")(t)
require("tests.spec_agent_install")(t)
require("tests.spec_agent_resolve")(t)
require("tests.spec_agent_manager_service")(t)
require("tests.spec_agent_launch")(t)

t.run()
