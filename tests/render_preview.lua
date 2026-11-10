-- Renders a representative transcript and writes it to a text file.
--
--   nvim --headless -u tests/minimal_init.lua -l tests/render_preview.lua
--
-- Used to eyeball the layout without a real terminal UI.
local config = require("acp.config")
local state = require("acp.session.state")
local Chat = require("acp.ui.chat")
local toolbar = require("acp.ui.toolbar")
local highlights = require("acp.ui.highlights")

local function demo_session()
  local s = state.new("ses_preview", "/home/user/project")
  s.title = "Refactor the auth middleware"
  s.config_options = {
    {
      id = "model",
      name = "Model",
      category = "model",
      type = "select",
      currentValue = "sonnet",
      options = { { value = "sonnet", name = "Claude Sonnet 5" }, { value = "haiku", name = "Claude Haiku 5" } },
    },
    {
      id = "mode",
      name = "Mode",
      category = "mode",
      type = "select",
      currentValue = "code",
      options = { { value = "code", name = "Build" } },
    },
  }
  s.status = "idle"
  s.usage = { used = 42000, size = 200000 }

  s:add_local_user("Refactor the auth middleware so tokens are validated once.\nKeep the public API unchanged.", {
    { label = "src/auth.lua" },
    { label = "auth_test.lua 12-40" },
  })
  s:begin_turn()

  s:append({
    id = "plan",
    kind = "plan",
    entries = {
      { content = "Read the current middleware", status = "completed" },
      { content = "Extract token validation", status = "in_progress" },
      { content = "Update tests", status = "pending" },
    },
  })

  s:append({
    id = "t1",
    kind = "tool",
    tool_kind = "read",
    title = "Read src/auth.lua",
    status = "completed",
    detail = "120 lines read",
    locations = { { path = "/home/user/project/src/auth.lua", line = 1 } },
  })

  s:append({
    id = "a1",
    kind = "agent",
    text = "I'll start by reading the middleware, then extract validation into a helper.\n\n```lua\nlocal function validate(token)\n  return Token.verify(token)\nend\n```\n\nThe public surface stays `auth.middleware(opts)`.",
  })

  s:append({
    id = "t2",
    kind = "tool",
    tool_kind = "edit",
    title = "Edit src/auth.lua",
    status = "completed",
    detail = "+18 -11",
    locations = { { path = "/home/user/project/src/auth.lua", line = 24 } },
  })

  s:append({
    id = "t3",
    kind = "tool",
    tool_kind = "execute",
    title = "Run busted tests/auth_spec.lua",
    status = "failed",
    detail = "1 failure in token_spec",
  })

  s:append({ id = "c1", kind = "compaction", text = "", status = "completed" })

  s:finish_turn("end_turn")

  -- A second turn, so the preview shows the divider drawn between turns.
  s:add_local_user("Now add the tests for the extracted helper.")
  s:begin_turn()
  s:append({
    id = "a2",
    kind = "agent",
    text = "Added `tests/token_spec.lua` covering the extracted validator.",
  })
  s:finish_turn("end_turn")
  return s
end

---Strip winbar highlight markup so the preview shows the visible text.
---@param s string
---@return string
local function plain(s)
  return (
    s:gsub("%%#[%w_]+#", "")
      :gsub("%%[$][%w_]+[$]", "")
      :gsub("%%@v:lua%.%w+@", "")
      :gsub("%%T", "")
      :gsub("%%=", "")
      :gsub("%%%%", "%")
  )
end

local cfg = config.validate(config.merge(config.defaults, { ui = { toolbar = { show_usage = true } } }))
highlights.setup()

local chat = Chat.new({ config = cfg })
chat.width = 60
local session = demo_session()
chat:set_session(session)

local lines = {}
for _, line in
  ipairs(vim.tbl_map(function(l)
    return l.text
  end, chat.cache and {} or {}))
do
  lines[#lines + 1] = line
end

local out = {}
out[#out + 1] = "=== transcript (width 60) ==="
for _, line in ipairs(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)) do
  out[#out + 1] = "│ " .. line
end

out[#out + 1] = ""
out[#out + 1] = "=== composer toolbar (width 60) ==="
local model, mode = require("acp.ui.presenter").toolbar_labels(session)
local tb = toolbar.render({
  mode = mode,
  model = model,
  status = "running",
  waiting = false,
  queued = 1,
  usage = session.usage,
  show_usage = true,
  spinner = "⠹",
}, 60)
out[#out + 1] = plain(tb)

out[#out + 1] = ""
out[#out + 1] = "=== composer toolbar (width 28, waiting) ==="
local tb2 = toolbar.render({
  mode = "Build",
  model = "Claude Sonnet 5",
  status = "running",
  waiting = true,
}, 28)
out[#out + 1] = plain(tb2)

out[#out + 1] = ""
out[#out + 1] = "=== chat title (width 60) ==="
local title = toolbar.chat_title({ agent = "opencode", title = session.title, pending_new = true }, 60)
out[#out + 1] = plain(title)

local fh = io.open("tests/preview.txt", "wb")
fh:write(table.concat(out, "\n") .. "\n")
fh:close()
print(table.concat(out, "\n"))
vim.cmd("qa!")
