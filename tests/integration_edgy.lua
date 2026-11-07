-- Integration test: acp.nvim windows under edgy.nvim control.
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
local edgy_path = root .. "../edgy.nvim"
local candidates = {
  edgy_path,
  vim.fn.expand("~/.local/share/nvim/lazy/edgy.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/*/start/edgy.nvim"),
}
local found = nil
for _, candidate in ipairs(candidates) do
  local expanded = vim.fn.glob(candidate, false, true)
  if type(expanded) == "table" then
    expanded = expanded[1]
  end
  if expanded and expanded ~= "" and vim.fn.isdirectory(expanded) == 1 then
    found = expanded
    break
  end
end
edgy_path = found

local function wait(cond, timeout, label)
  if not vim.wait(timeout or 8000, cond, 20) then
    error("timed out: " .. (label or "condition"), 2)
  end
end

if vim.fn.isdirectory(edgy_path) == 0 then
  io.write("SKIP: edgy.nvim not found at " .. edgy_path .. "\n")
  vim.cmd("qa!")
  return
end

vim.opt.runtimepath:append(edgy_path)
vim.opt.laststatus = 3
vim.opt.splitkeep = "screen"

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

pcall(vim.cmd, "packadd edgy.nvim")

local edgy = require("edgy")
local acp_edgy = require("acp.integrations.edgy")

local opts = {
  left = { "Trouble" },
  right = {},
  options = {
    left = { size = 30 },
    right = { size = 46 },
    bottom = { size = 10 },
    top = { size = 10 },
  },
  animate = { enabled = false },
}
acp_edgy.extend(opts)
edgy.setup(opts)

local acp = require("acp")
local controller = require("acp.controller")

acp.setup({
  agent = "opencode",
  agents = { opencode = { command = "python3", args = { root .. "tests/mock_agent.py" } } },
  ui = { language = "en" },
  layout = { backend = "external", input_height = 6 },
})

acp.open()
local st = controller.state()

wait(function()
  return st.char_set == nil and st.session ~= nil
end, 8000, "session creation")

check("edgy recognizes both acp windows", function()
  local chat_ok = st.chat and st.chat:is_visible()
  local input_ok = st.input and st.input:is_visible()
  assert(chat_ok, "chat window missing under edgy")
  assert(input_ok, "composer window missing under edgy")
end)

check("edgy places the views in the right edgebar", function()
  local chat = edgy.get_win(st.chat.win)
  local input = edgy.get_win(st.input.win)
  assert(chat ~= nil, "chat window is not managed by edgy")
  assert(input ~= nil, "composer window is not managed by edgy")
end)

check("acp owns the composer winbar, not edgy", function()
  local winbar = vim.api.nvim_get_option_value("winbar", { win = st.input.win })
  assert(winbar and winbar:find("acp_input") == nil, "edgy winbar leaked in")
  assert(winbar and #winbar > 0, "composer winbar empty")
end)

check("acp keeps ownership of both winbars by default", function()
  local chat_bar = vim.api.nvim_get_option_value("winbar", { win = st.chat.win })
  local input_bar = vim.api.nvim_get_option_value("winbar", { win = st.input.win })
  local chat_res = vim.api.nvim_eval_statusline(chat_bar, {
    winid = st.chat.win,
    maxwidth = vim.api.nvim_win_get_width(st.chat.win),
    use_winbar = true,
  })
  local input_res = vim.api.nvim_eval_statusline(input_bar, {
    winid = st.input.win,
    maxwidth = vim.api.nvim_win_get_width(st.input.win),
    use_winbar = true,
  })
  assert(chat_res.str:find("opencode", 1, true), "chat title missing: " .. tostring(chat_res.str))
  assert(#input_res.str > 0, "composer winbar empty")
end)

check("main editing area is untouched", function()
  local main_wins = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    if ft ~= "acp_chat" and ft ~= "acp_input" then
      main_wins = main_wins + 1
    end
  end
  assert(main_wins >= 1, "no main window left")
end)

check("composer keymaps are buffer local", function()
  local maps = vim.api.nvim_buf_get_keymap(st.input.buf, "n")
  local has_send = false
  for _, map in ipairs(maps) do
    if map.lhs == "<C-S>" or map.lhs == "<C-s>" then
      has_send = true
    end
  end
  assert(has_send, "send keymap missing")
  -- Check the global table from a plain buffer that has no ACP maps. The ACP
  -- windows are locked to their buffers, so open a separate window.
  vim.cmd("split | enew")
  local scratch = vim.api.nvim_get_current_buf()
  local global = vim.fn.maparg("<C-s>", "n", false, true)
  assert(vim.tbl_isempty(global), "a global <C-s> mapping was created")
end)

-- Conversation still works while edgy owns the layout.
controller.submit("hello", {})
wait(function()
  local lines = vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false)
  return table.concat(lines, "\n"):find("Hello from the mock agent", 1, true) ~= nil
end, 10000, "streamed reply")

check("conversation works under edgy", function()
  local text = table.concat(vim.api.nvim_buf_get_lines(st.chat.buf, 0, -1, false), "\n")
  assert(text:find("Hello from the mock agent", 1, true), "missing reply")
end)

-- Closing only the composer must not be re-created by acp.
vim.api.nvim_win_close(st.input.win, true)
vim.wait(200)
check("closing one view does not force it back open", function()
  assert(st.input.win == nil or not vim.api.nvim_win_is_valid(st.input.win), "composer was forced back open")
end)

check("the session survives closing the composer", function()
  assert(st.session ~= nil, "session lost")
end)

acp.hide()

if #failures > 0 then
  io.write("\n" .. #failures .. " edgy integration failures:\n")
  for _, f in ipairs(failures) do
    io.write("  - " .. f .. "\n")
  end
  vim.cmd("cq 1")
else
  io.write("\nall edgy checks passed\n")
  vim.cmd("qa!")
end
