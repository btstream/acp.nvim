-- Configuration defaults, merging and validation.
local M = {}

---@class AcpAgentConfig
---@field command? string
---@field args? string[]
---@field env? table<string, string>

M.defaults = {
  -- Agent used when none is specified explicitly.
  agent = "opencode",

  ---@type table<string, AcpAgentConfig>
  agents = {
    opencode = {
      command = "opencode",
      args = { "acp" },
    },
  },

  -- Working directory for sessions. Defaults to the current project root (see cwd resolution).
  cwd = nil,

  log = {
    level = "warn",
    max_bytes = 1024 * 1024,
    -- When true, protocol payloads are logged at debug level with secrets redacted.
    protocol = false,
  },

  transport = {
    -- Maximum size of a single newline delimited JSON message.
    max_line_bytes = 8 * 1024 * 1024,
    -- How many bytes of stderr to keep for diagnostics.
    stderr_keep_bytes = 64 * 1024,
    -- Milliseconds to wait for graceful shutdown before killing the process.
    shutdown_timeout = 2000,
  },

  layout = {
    ---@type "native"|"external"
    backend = "native",
    ---@type "right"|"left"
    position = "right",
    -- Width as a fraction of the editor columns (0 < width <= 1) or an absolute cell count (> 1).
    width = 0.38,
    min_width = 42,
    max_width = 120,
    input_height = 8,
    min_input_height = 4,
    max_input_height = 24,
    focus_input_on_open = true,
    -- Keep the previously focused window when the panel is closed.
    restore_focus = true,
    -- Lock the ACP windows to their own buffers ('winfixbuf'), so commands and
    -- plugins cannot replace the transcript or the composer with another file.
    lock_buffer = true,
  },

  ui = {
    -- Use Nerd Font icons. Set to false for a plain ASCII interface.
    icons = true,
    -- Show agent thoughts. Off by default, matching Zed's clean transcript.
    show_thoughts = false,
    follow_output = true,
    wrap = true,

    -- Selector implementation: "vim" uses vim.ui.select (so telescope,
    -- fzf-lua, snacks.nvim and friends apply), "internal" always uses the
    -- built-in floating picker.
    ---@type "vim"|"internal"
    picker = "vim",

    -- Backend for the :Acp sessions browser.
    -- "snacks" uses snacks.nvim when it is installed, and falls back to the
    -- built-in window automatically when it is not. "internal" always uses the
    -- built-in window.
    ---@type "snacks"|"internal"
    session_picker = "snacks",

    title = {
      ---@type "auto"|"winbar"|"off"
      placement = "auto",
    },

    toolbar = {
      ---@type "auto"|"winbar"|"off"
      placement = "auto",
      show_usage = false,
      -- Refresh animation for the running indicator.
      animate = true,
      animation_interval = 120,
    },

    -- Approximate Zed look: restrained colors, minimal decoration.
    zed_style = true,
  },

  keymaps = {
    send = "<C-s>",
    cancel = "<C-c>",
    close_panel = "q",
    focus_input = "i",
    open_location = "<CR>",
    prev_block = "[b",
    next_block = "]b",
    toggle_block = "<Tab>",
  },

  permissions = {
    ---@type "select"|"native"
    prompt = "select",
    -- option kinds that are selected automatically (use with care)
    auto_allow = {},
  },

  context = {
    max_file_bytes = 512 * 1024,
    max_selection_lines = 2000,
  },

  -- Show timeline notices sent by the agent (requires the session.notices capability).
  notices = true,
}

---Whether `t` is a plain table that should be merged rather than replaced.
---
---`vim.islist({})` is true, so an *empty* table must be treated as a map when
---the default at the same key is a map: otherwise `ui = {}` would wipe every
---default instead of leaving them intact.
---@param t any
---@param default any
---@return boolean
local function is_map(t, default)
  if type(t) ~= "table" then
    return false
  end
  if next(t) == nil then
    -- Empty table: follow the default's shape.
    return type(default) == "table" and not vim.islist(default)
  end
  return not vim.islist(t)
end

---Deep merge `over` into `base` without mutating either.
---@param base table
---@param over table|nil
---@return table
function M.merge(base, over)
  local out = {}
  for k, v in pairs(base) do
    out[k] = v
  end
  for k, v in pairs(over or {}) do
    if is_map(v, out[k]) and is_map(out[k], out[k]) then
      out[k] = M.merge(out[k], v)
    else
      out[k] = v
    end
  end
  return out
end

local function fail(fmt, ...)
  error("acp.nvim: " .. string.format(fmt, ...), 0)
end

local function check_enum(value, allowed, path)
  for _, v in ipairs(allowed) do
    if value == v then
      return
    end
  end
  fail("%s must be one of %s, got %s", path, table.concat(allowed, ", "), vim.inspect(value))
end

local function check_number(value, min, max, path)
  if type(value) ~= "number" then
    fail("%s must be a number, got %s", path, type(value))
  end
  if value < min or value > max then
    fail("%s must be between %s and %s, got %s", path, min, max, value)
  end
end

---Validate and normalize a merged configuration table.
---@param cfg table
---@return table
function M.validate(cfg)
  check_enum(cfg.agent, vim.tbl_keys(cfg.agents), "agent")
  check_enum(cfg.layout.backend, { "native", "external" }, "layout.backend")
  check_enum(cfg.layout.position, { "right", "left" }, "layout.position")
  check_number(cfg.layout.width, 0.05, 1000, "layout.width")
  check_number(cfg.layout.input_height, 1, 200, "layout.input_height")
  check_enum(cfg.ui.picker, { "vim", "internal" }, "ui.picker")
  check_enum(cfg.ui.session_picker, { "snacks", "internal" }, "ui.session_picker")
  check_enum(cfg.ui.title.placement, { "auto", "winbar", "off" }, "ui.title.placement")
  check_enum(cfg.ui.toolbar.placement, { "auto", "winbar", "off" }, "ui.toolbar.placement")
  check_enum(cfg.permissions.prompt, { "select", "native" }, "permissions.prompt")

  if cfg.layout.min_width > cfg.layout.max_width then
    fail("layout.min_width must not exceed layout.max_width")
  end

  local agent = cfg.agents[cfg.agent]
  if not agent or type(agent.command) ~= "string" or agent.command == "" then
    fail("agents.%s.command must be a non-empty string", cfg.agent)
  end
  agent.args = agent.args or {}
  if not vim.islist(agent.args) then
    fail("agents.%s.args must be a list", cfg.agent)
  end

  return cfg
end

---Resolve the panel width in columns for a total `total` width.
---@param cfg table
---@param total integer
---@return integer
function M.panel_width(cfg, total)
  local w = cfg.layout.width
  local cols = (w <= 1) and math.floor(total * w + 0.5) or math.floor(w)
  cols = math.max(cols, cfg.layout.min_width)
  cols = math.min(cols, cfg.layout.max_width)
  -- Never take more than half the screen.
  cols = math.min(cols, math.max(1, math.floor(total * 0.6)))
  return cols
end

return M
