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
    -- Milliseconds to wait for a response to a regular request.
    request_timeout = 30000,
    -- Absolute ceiling for a prompt turn, in milliseconds. Prompts may run for
    -- minutes, so this is deliberately generous; it exists only so a wedged
    -- agent cannot hang the turn forever. 0 disables it.
    prompt_timeout = 600000,
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
    -- Show agent thoughts expanded. Off by default, matching Zed's clean
    -- transcript; a collapsed header is still drawn so they can be opened.
    -- Kept for compatibility: `thoughts.default_expanded` supersedes it.
    show_thoughts = false,
    thoughts = {
      -- Expand reasoning by default instead of showing a collapsed header.
      default_expanded = false,
      -- Draw a "Thinking" header when collapsed. Turning this off hides
      -- thoughts entirely, with no way to expand them from the transcript.
      show_collapsed_header = true,
    },
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
---
---Nested tables are copied, so the merged result never shares structure with
---`base` (the module defaults) or with `over` (the user's table). Sharing them
---meant validation-time normalisation such as `agent.args = agent.args or {}`
---wrote into the global defaults.
---@param base table
---@param over table|nil
---@return table
function M.merge(base, over)
  local out = {}
  for k, v in pairs(base) do
    if type(v) == "table" then
      out[k] = M.merge(v, nil)
    else
      out[k] = v
    end
  end
  for k, v in pairs(over or {}) do
    if is_map(v, out[k]) and is_map(out[k], out[k]) then
      out[k] = M.merge(out[k], v)
    elseif type(v) == "table" and not vim.islist(v) then
      out[k] = M.merge({}, v)
    elseif type(v) == "table" then
      -- Lists are replaced wholesale, but still deep-copied so callers cannot
      -- mutate the merged config through the table they passed in.
      out[k] = vim.deepcopy(v)
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
  -- NaN compares false to everything, so it would slip past the range check.
  if value ~= value then
    fail("%s must be a number, got NaN", path)
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
  if type(cfg.ui.thoughts) ~= "table" then
    fail("ui.thoughts must be a table")
  end
  if type(cfg.ui.thoughts.default_expanded) ~= "boolean" then
    fail("ui.thoughts.default_expanded must be a boolean")
  end
  if type(cfg.ui.thoughts.show_collapsed_header) ~= "boolean" then
    fail("ui.thoughts.show_collapsed_header must be a boolean")
  end

  if cfg.layout.min_width > cfg.layout.max_width then
    fail("layout.min_width must not exceed layout.max_width")
  end
  check_number(cfg.layout.min_width, 1, cfg.layout.max_width, "layout.min_width")
  check_number(cfg.layout.max_width, 1, 10000, "layout.max_width")
  check_number(cfg.layout.min_input_height, 1, 200, "layout.min_input_height")
  check_number(cfg.layout.max_input_height, 1, 200, "layout.max_input_height")
  if cfg.layout.min_input_height > cfg.layout.max_input_height then
    fail("layout.min_input_height must not exceed layout.max_input_height")
  end

  -- Transport limits: a bad value here either aborts on the first message or
  -- makes every prompt "too large", so validate eagerly.
  check_number(cfg.transport.max_line_bytes, 1024, 1024 * 1024 * 1024, "transport.max_line_bytes")
  check_number(cfg.transport.stderr_keep_bytes, 0, 1024 * 1024 * 1024, "transport.stderr_keep_bytes")
  check_number(cfg.transport.shutdown_timeout, 0, 600000, "transport.shutdown_timeout")
  check_number(cfg.transport.request_timeout, 0, 3600000, "transport.request_timeout")
  check_number(cfg.transport.prompt_timeout, 0, 24 * 3600 * 1000, "transport.prompt_timeout")

  check_enum(cfg.log.level, { "trace", "debug", "info", "warn", "error" }, "log.level")
  check_number(cfg.log.max_bytes, 0, 1024 * 1024 * 1024, "log.max_bytes")
  if type(cfg.log.protocol) ~= "boolean" then
    fail("log.protocol must be a boolean, got %s", type(cfg.log.protocol))
  end

  check_number(cfg.context.max_file_bytes, 0, 1024 * 1024 * 1024, "context.max_file_bytes")
  check_number(cfg.context.max_selection_lines, 0, 1000000, "context.max_selection_lines")
  check_number(cfg.ui.toolbar.animation_interval, 10, 60000, "ui.toolbar.animation_interval")

  if type(cfg.permissions.auto_allow) ~= "table" or not vim.islist(cfg.permissions.auto_allow) then
    fail("permissions.auto_allow must be a list")
  end
  if type(cfg.notices) ~= "boolean" then
    fail("notices must be a boolean, got %s", type(cfg.notices))
  end
  if cfg.cwd ~= nil and cfg.cwd ~= vim.NIL and type(cfg.cwd) ~= "string" then
    fail("cwd must be a string, got %s", type(cfg.cwd))
  end

  local agent = cfg.agents[cfg.agent]
  if not agent or type(agent.command) ~= "string" or agent.command == "" then
    fail("agents.%s.command must be a non-empty string", cfg.agent)
  end
  agent.args = agent.args or {}
  if not vim.islist(agent.args) then
    fail("agents.%s.args must be a list", cfg.agent)
  end
  if agent.env ~= nil then
    if type(agent.env) ~= "table" then
      fail("agents.%s.env must be a table", cfg.agent)
    end
    for k, v in pairs(agent.env) do
      if type(k) ~= "string" or type(v) ~= "string" then
        fail("agents.%s.env must map strings to strings", cfg.agent)
      end
    end
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
