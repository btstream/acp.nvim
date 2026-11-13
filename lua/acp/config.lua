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

  -- Client capabilities. Each switch exists so a capability can be turned off
  -- while diagnosing an agent, even after the implementation lands.
  capabilities = {
    elicitation = { form = true, url = false },
    auth_terminal = true,
    terminal_output_meta = false,
    boolean_config_options = true,
    fs = false,
    terminal = false,
  },

  -- Working directory for sessions. Defaults to vim.fn.getcwd().
  cwd = nil,

  completion = {
    native = true, -- keep <C-x><C-u>; external sources are explicitly configured
    max_items = 200, -- native menu only; frameworks/pickers receive the full index
    picker = "vim", -- vim.ui.select, fzf-lua, snacks or telescope
    files = {
      backend = "auto", -- rg -> fd -> git -> asynchronous builtin walker
      command = false, -- optional argv; must emit NUL-delimited project-relative paths
      root = false, -- git root derived from session.cwd, or session.cwd outside git
      hidden = true,
      ignored = false,
      cache_ms = 10000,
      max_bytes = 16 * 1024 * 1024,
      max_projects = 4,
    },
  },

  memory = {
    max_block_bytes = 1024 * 1024,
    max_session_bytes = 16 * 1024 * 1024,
    max_cached_sessions = 8,
    max_total_bytes = 64 * 1024 * 1024,
    max_queued_messages = 16,
    max_queue_bytes = 4 * 1024 * 1024,
    max_drafts = 20,
  },

  log = {
    level = "warn",
    max_bytes = 1024 * 1024,
    -- When true, protocol payloads are logged at debug level with secrets redacted.
    protocol = false,
  },

  transport = {
    -- Maximum size of a single newline delimited JSON message. Large edits and
    -- tool outputs are delivered as one message, so this is well above the
    -- normal chunk size; exceeding it still closes the connection.
    max_line_bytes = 32 * 1024 * 1024,
    -- How many bytes of stderr to keep for diagnostics.
    stderr_keep_bytes = 64 * 1024,
    -- Milliseconds to wait for graceful shutdown before killing the process.
    shutdown_timeout = 2000,
    -- Milliseconds to wait for a response to a regular request.
    request_timeout = 30000,
    -- Per-method overrides. npx-based adapters can take a long time to boot.
    timeouts = {
      initialize = 120000,
      session_new = 60000,
      session_load = 120000,
    },
    -- Absolute ceiling for a prompt turn, in milliseconds. Prompts may run for
    -- minutes, so this is deliberately generous; it exists only so a wedged
    -- agent cannot hang the turn forever. 0 disables it.
    prompt_timeout = 6 * 600000,
    -- Bound queued decoded-line payloads and yield between dispatch batches.
    -- 0 means no total cap: memory grows instead of disconnecting.
    max_pending_bytes = 64 * 1024 * 1024,
    -- Spill complete unread lines asynchronously above this working-set target.
    -- 0 keeps everything in memory. This is not a hard memory bound: incoming
    -- callbacks, incomplete lines, JSON decoding and in-flight I/O also retain data.
    spill_bytes = 64 * 1024 * 1024,
    -- After decoding, split text updates larger than this into ordered parts so
    -- reduce/render can yield between them. 0 disables chunking.
    text_chunk_bytes = 64 * 1024,
    dispatch_budget_ms = 4,
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
      -- Draw a header when collapsed. Turning this off hides completed
      -- thoughts entirely, with no way to expand them from the transcript.
      show_collapsed_header = true,
      -- Show reasoning live while it streams, and close it once finished.
      expand_while_streaming = true,
      collapse_on_finish = true,
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

    -- Override any highlight group, e.g.
    --   highlights = { AcpUser = { fg = "#ff0000" } }
    -- Definitions given here replace the built-in ones. Groups can also be set
    -- from anywhere with `vim.api.nvim_set_hl`.
    ---@type table<string, table>
    highlights = {},

    render = {
      -- Opt-in: keep all text, but parse/paint code syntax near the viewport.
      lazy_syntax = false,
      profile = false,
      budget_ms = 4,
      overscan = 1,
      -- Above this many rows a full commit is written in slices. 0 disables.
      commit_rows = 2000,
      pagination = {
        -- Opt-in: native search/selection see only materialised history.
        enabled = false,
        page_blocks = 64,
        max_blocks = 192,
        page_bytes = 256 * 1024,
      },
    },

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

    -- Divider drawn between conversation turns.
    ---@type { form: "dot"|"turn"|"off" }
    separator = {
      -- "dot"  a thin rule with a centred dot
      -- "turn" the same rule with the turn number in the middle
      -- "off"  no divider
      form = "dot",
    },

    -- File-modifying tool calls (`edit`, `write`, `patch`) render their change
    -- as a diff inside the card.
    ---@type { context: integer, max_lines: integer, max_bytes: integer, syntax: boolean, max_syntax_rows: integer }
    diff = {
      -- Unchanged lines kept around each hunk.
      context = 3,
      -- Ceiling on rendered diff rows; the rest is summarised in one row.
      max_lines = 800,
      -- A larger old+new payload is not diffed at all (`diff too large`).
      max_bytes = 512 * 1024,
      -- Colour the diff rows with the file's own syntax.
      syntax = true,
      -- Above this many rows the colour is skipped: parsing is cheap per row but
      -- a first paint of a huge diff should still be instant.
      max_syntax_rows = 800,
    },
  },

  -- Buffer-local mappings for the two views.
  --
  -- Each view lists its own actions because the same action can want a
  -- different key in the composer and in the transcript (`add_selection` is
  -- `<C-]>` while typing but `S` while reading). A value is one of:
  --
  --   "<key>"                 one key, bound to every mode the action declares
  --   { "<key>", "<key>" }    several keys
  --   { n = "..", i = ".." }  per-mode keys
  --   false                   leave the action unbound
  --
  -- See `acp.ui.keymaps`: it owns which modes each action declares, and
  -- `config.validate` rejects keys it cannot use.
  keymaps = {
    input = {
      -- "<C-s>" while typing, and as the stop key when the composer is empty.
      send = "<C-s>",
      pick_file = false,
      -- Reads an image from the system clipboard while composing. This
      -- deliberately overrides `i_CTRL-V` (literal insert) in the composer and
      -- `CTRL-V` (blockwise Visual) in its Normal mode, matching the terminal
      -- agent UIs. The terminal itself never forwards image bytes.
      paste_image = "<C-v>",
      cancel = "<C-c>",
      close_panel = "q",
      add_selection = "<C-]>",
      -- Normal mode uses a letter, insert mode an Alt combination. `<C-m>` must
      -- not be used: in a terminal it is the same key as <CR>.
      pick_model = { n = "M", i = "<M-m>" },
      pick_mode = { n = "m", i = "<M-b>" },
      pick_session = "L",
    },
    chat = {
      close_panel = "q",
      -- Both keys focus the composer: `i` is the Vim habit, `<C-s>` the one
      -- shared with the composer's own send key.
      focus_input = { "i", "<C-s>" },
      toggle_block = "<Tab>",
      prev_block = "[b",
      next_block = "]b",
      open_location = "<CR>",
      help = "g?",
      add_selection = "S",
      add_file = "F",
      add_diagnostics = "R",
      pick_model = "M",
      pick_mode = "m",
      new_session = "<C-n>",
      pick_session = "L",
      scroll_bottom = "G",
      scroll_top = "gg",
    },
    -- Inline editing. `visual` applies to the captured selection, `normal`
    -- inserts at the cursor.
    inline = {
      normal = "<leader>ai",
      visual = "<leader>ai",
    },
  },

  permissions = {
    ---@type "select"|"native"
    prompt = "select",
    -- option kinds that are selected automatically (use with care)
    auto_allow = {},
    -- show diff/command details in the permission picker
    show_details = true,
  },

  context = {
    max_file_bytes = 512 * 1024,
    max_selection_lines = 2000,

    -- Images are sent as ACP `image` blocks, which requires the agent's
    -- promptCapabilities.image. Only the path is kept while composing; base64
    -- is produced at send time. The default keeps one image plus its base64
    -- and JSON overhead inside `memory.max_queue_bytes`.
    images = {
      enabled = true,
      max_bytes = 3 * 1024 * 1024,
      max_per_message = 4,
      -- "auto" follows WAYLAND_DISPLAY / DISPLAY / TERMUX / pngpaste /
      -- powershell.exe. Set false to disable reading, or an argv whose stdout
      -- is the image (for an existing screenshot helper).
      clipboard = "auto",
      -- What a pasted or mentioned image path becomes. "link" keeps the file a
      -- resource_link; "inline" embeds the bytes for that message only.
      path_mode = "link",
      -- Cached clipboard images are content-addressed under
      -- stdpath("state")/acp/images and pruned by age and total size.
      ttl_hours = 24,
      max_cache_bytes = 64 * 1024 * 1024,
    },
  },

  inline = {
    enabled = true,
    -- How a finished inline request is returned to the buffer.
    --   "diff"  review every hunk before it is applied
    --   "write" apply immediately, still as one undoable change
    -- `by_filetype` overrides `mode` for exact filetypes, then for the first
    -- component of a compound filetype, then for "*". A buffer marked with the
    -- diff UI's "always accept" wins over all of them.
    review = {
      mode = "diff",
      by_filetype = {},
    },
    -- No visual selection: "cursor" lets the request decide what to change
    -- (the cursor is only a hint). "context" instead bounds edits to the
    -- visible context window around the cursor.
    scope = "cursor",
    -- Whole-line selections are what both Zed and CodeCompanion use for inline
    -- edits; turn this off to replace only the exact characters.
    expand_selection = true,
    -- Context shared above and below the selection, in bytes.
    context_bytes = 50000,
    max_copy_bytes = 8 * 1024 * 1024,
    -- A sibling copy keeps relative imports and project-root detection working.
    -- "state" writes to the state directory instead.
    copy_dir = "sibling",
    -- Allow the agent's write tools on files other than the copy.
    allow_writes = false,
    -- Allow commands and other non-read tools.
    allow_commands = false,
    -- Floating windows used by inline editing. Colours are not set here: the
    -- groups named below are defined by `ui.highlights` and can be overridden
    -- there or with `nvim_set_hl`.
    window = {
      -- Any `nvim_open_win()` border: "none", "single", "double", "rounded",
      -- "solid", "shadow", or an 8-element table of characters.
      border = "rounded",
      -- "left" | "center" | "right"
      title_pos = "left",
      -- "minimal" hides the number/sign columns; "default" keeps window options.
      style = "minimal",
      highlights = {
        normal = "AcpInlinePrompt",
        border = "AcpInlineBorder",
        title = "AcpInlineTitle",
      },
      prompt = {
        -- "cursor" anchors near the cursor (flipping above when there is no
        -- room below); "window" anchors at the source window's top-left.
        placement = "cursor",
        -- Requested size. The result is clamped to the screen.
        width = 72,
        height = 3,
        -- Screen-cell offset from the anchor, applied before clamping.
        offset = { row = 0, col = 0 },
        -- Re-anchor when the cursor moves in the source window.
        follow_cursor = true,
      },
      review = {
        -- Where the review opens. "buffer" uses real side-by-side windows in a
        -- new tabpage; "float" renders the card-style view inside a floating
        -- window, since the side-by-side view needs real windows.
        target = "buffer",
        -- "3-column" is original | result | proposal; "2-column" drops the
        -- read-only original and shows result | proposal.
        layout = "3-column",
        -- Below this many columns the tabbed view falls back to the card
        -- renderer, which needs far less width.
        min_split_width = 90,
        -- Unchanged lines kept around each change: shown around each card in
        -- the fallback, and left unfolded around each hunk in the columns.
        -- `syntax` colours the card rows with the file's own syntax.
        context = 3,
        syntax = true,
        -- Ceiling on rendered card rows.
        max_rows = 4000,
        -- Jump to the next pending hunk after accepting/rejecting one.
        advance = false,
        -- Side-by-side window options: fold unchanged context, and keep the
        -- columns scrolling and moving together.
        fold = true,
        sync_scroll = true,
        -- Relative line numbers, counted in real lines (filler rows are
        -- skipped). Off by default: absolute numbers can be compared across
        -- columns.
        relative_number = false,
        -- Show the accept/reject keys after the hunk under the cursor.
        hints = true,
        -- Width of the fold column. 0 hides it and gains three columns of code.
        foldcolumn = 1,
        -- Float geometry. Only used when target = "float".
        placement = "center",
        width = 140,
        height = 25,
      },
    },
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
  M.normalize_keymaps(cfg)
  local completion = cfg.completion
  if type(completion) ~= "table" or type(completion.files) ~= "table" then
    fail("completion and completion.files must be tables")
  end
  local files = completion.files
  check_enum(completion.picker, { "vim", "fzf-lua", "snacks", "telescope" }, "completion.picker")
  check_enum(files.backend, { "auto", "rg", "fd", "git", "builtin" }, "completion.files.backend")
  for _, key in ipairs({ "hidden", "ignored" }) do
    if type(files[key]) ~= "boolean" then
      fail("completion.files.%s must be a boolean", key)
    end
  end
  if type(completion.native) ~= "boolean" then
    fail("completion.native must be a boolean")
  end
  for _, spec in ipairs({
    { completion.max_items, 1, 10000, "completion.max_items" },
    { files.cache_ms, 0, 3600000, "completion.files.cache_ms" },
    { files.max_bytes, 1024, 1024 * 1024 * 1024, "completion.files.max_bytes" },
    { files.max_projects, 1, 64, "completion.files.max_projects" },
  }) do
    check_number(unpack(spec))
    if spec[1] % 1 ~= 0 then
      fail("%s must be an integer", spec[4])
    end
  end
  if files.root ~= false and type(files.root) ~= "string" and type(files.root) ~= "function" then
    fail("completion.files.root must be false, a string or a function")
  end
  if type(files.root) == "string" and files.root:find("\0", 1, true) then
    fail("completion.files.root must not contain NUL")
  end
  if files.command ~= false then
    if type(files.command) ~= "table" or not vim.islist(files.command) or #files.command == 0 then
      fail("completion.files.command must be false or a non-empty argv list")
    end
    for _, arg in ipairs(files.command) do
      if type(arg) ~= "string" or arg:find("\0", 1, true) then
        fail("completion.files.command arguments must be strings without NUL")
      end
    end
    if files.command[1] == "" then
      fail("completion.files.command executable must not be empty")
    end
  end
  for _, key in ipairs({ "max_block_bytes", "max_session_bytes", "max_total_bytes", "max_queue_bytes" }) do
    check_number(cfg.memory[key], 1024, 1024 * 1024 * 1024, "memory." .. key)
  end
  for _, key in ipairs({ "max_cached_sessions", "max_queued_messages", "max_drafts" }) do
    check_number(cfg.memory[key], 1, 10000, "memory." .. key)
  end
  if cfg.memory.max_block_bytes > cfg.memory.max_session_bytes then
    fail("memory.max_block_bytes must not exceed memory.max_session_bytes")
  end
  check_enum(cfg.agent, vim.tbl_keys(cfg.agents), "agent")
  check_enum(cfg.layout.backend, { "native", "external" }, "layout.backend")
  check_enum(cfg.layout.position, { "right", "left" }, "layout.position")
  check_number(cfg.layout.width, 0.05, 1000, "layout.width")
  check_number(cfg.layout.input_height, 1, 200, "layout.input_height")
  check_enum(cfg.ui.picker, { "vim", "internal" }, "ui.picker")
  check_enum(cfg.ui.session_picker, { "snacks", "internal" }, "ui.session_picker")
  check_enum(cfg.ui.title.placement, { "auto", "winbar", "off" }, "ui.title.placement")
  check_enum(cfg.ui.toolbar.placement, { "auto", "winbar", "off" }, "ui.toolbar.placement")
  check_enum(cfg.ui.separator.form, { "dot", "turn", "off" }, "ui.separator.form")
  if type(cfg.ui.diff) ~= "table" then
    fail("ui.diff must be a table")
  end
  local render = cfg.ui.render
  if type(render) ~= "table" or type(render.pagination) ~= "table" then
    fail("ui.render and ui.render.pagination must be tables")
  end
  for _, key in ipairs({ "lazy_syntax", "profile" }) do
    if type(render[key]) ~= "boolean" then
      fail("ui.render." .. key .. " must be a boolean")
    end
  end
  if type(render.pagination.enabled) ~= "boolean" then
    fail("ui.render.pagination.enabled must be a boolean")
  end
  check_number(render.budget_ms, 1, 100, "ui.render.budget_ms")
  check_number(render.commit_rows, 0, 1000000, "ui.render.commit_rows")
  check_number(render.overscan, 0, 5, "ui.render.overscan")
  for _, key in ipairs({ "page_blocks", "max_blocks" }) do
    check_number(render.pagination[key], 1, 10000, "ui.render.pagination." .. key)
    if render.pagination[key] % 1 ~= 0 then
      fail("ui.render.pagination." .. key .. " must be an integer")
    end
  end
  if render.pagination.max_blocks < render.pagination.page_blocks then
    fail("ui.render.pagination.max_blocks must be at least page_blocks")
  end
  check_number(render.pagination.page_bytes, 1024, 1024 * 1024 * 1024, "ui.render.pagination.page_bytes")
  check_number(cfg.ui.diff.context, 0, 100, "ui.diff.context")
  check_number(cfg.ui.diff.max_lines, 1, 100000, "ui.diff.max_lines")
  check_number(cfg.ui.diff.max_bytes, 1024, 1024 * 1024 * 1024, "ui.diff.max_bytes")
  check_number(cfg.ui.diff.max_syntax_rows, 0, 100000, "ui.diff.max_syntax_rows")
  if type(cfg.ui.diff.syntax) ~= "boolean" then
    fail("ui.diff.syntax must be a boolean")
  end
  check_enum(cfg.permissions.prompt, { "select", "native" }, "permissions.prompt")
  if type(cfg.ui.thoughts) ~= "table" then
    fail("ui.thoughts must be a table")
  end
  -- `vim.islist({})` is true, so an empty table has to be allowed: `ui = {}`
  -- must not fail just because the defaults leave this map empty.
  if type(cfg.ui.highlights) ~= "table" or (next(cfg.ui.highlights) ~= nil and vim.islist(cfg.ui.highlights)) then
    fail("ui.highlights must be a table of group -> definition")
  end
  if type(cfg.ui.thoughts.default_expanded) ~= "boolean" then
    fail("ui.thoughts.default_expanded must be a boolean")
  end
  if type(cfg.ui.thoughts.show_collapsed_header) ~= "boolean" then
    fail("ui.thoughts.show_collapsed_header must be a boolean")
  end
  if type(cfg.ui.thoughts.expand_while_streaming) ~= "boolean" then
    fail("ui.thoughts.expand_while_streaming must be a boolean")
  end
  if type(cfg.ui.thoughts.collapse_on_finish) ~= "boolean" then
    fail("ui.thoughts.collapse_on_finish must be a boolean")
  end

  check_number(cfg.layout.min_width, 1, 10000, "layout.min_width")
  check_number(cfg.layout.max_width, 1, 10000, "layout.max_width")
  if cfg.layout.min_width > cfg.layout.max_width then
    fail("layout.min_width must not exceed layout.max_width")
  end
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
  if type(cfg.transport.timeouts) ~= "table" then
    fail("transport.timeouts must be a table, got %s", type(cfg.transport.timeouts))
  end
  for _, method in ipairs({ "initialize", "session_new", "session_load" }) do
    check_number(cfg.transport.timeouts[method], 0, 24 * 3600 * 1000, "transport.timeouts." .. method)
  end
  check_number(cfg.transport.prompt_timeout, 0, 24 * 3600 * 1000, "transport.prompt_timeout")
  -- 0 disables the total cap; any positive value must still be usable.
  check_number(cfg.transport.max_pending_bytes, 0, 1024 * 1024 * 1024, "transport.max_pending_bytes")
  if cfg.transport.max_pending_bytes > 0 and cfg.transport.max_pending_bytes < 1024 then
    fail("transport.max_pending_bytes must be 0 or at least 1024")
  end
  check_number(cfg.transport.spill_bytes, 0, 1024 * 1024 * 1024, "transport.spill_bytes")
  if cfg.transport.spill_bytes > 0 and cfg.transport.spill_bytes < 1024 then
    fail("transport.spill_bytes must be 0 or at least 1024")
  end
  check_number(cfg.transport.text_chunk_bytes, 0, 1024 * 1024, "transport.text_chunk_bytes")
  if cfg.transport.text_chunk_bytes > 0 and cfg.transport.text_chunk_bytes < 1024 then
    fail("transport.text_chunk_bytes must be 0 or at least 1024")
  end
  check_number(cfg.transport.dispatch_budget_ms, 1, 100, "transport.dispatch_budget_ms")

  check_enum(cfg.log.level, { "trace", "debug", "info", "warn", "error" }, "log.level")
  check_number(cfg.log.max_bytes, 0, 1024 * 1024 * 1024, "log.max_bytes")
  if type(cfg.log.protocol) ~= "boolean" then
    fail("log.protocol must be a boolean, got %s", type(cfg.log.protocol))
  end

  check_number(cfg.context.max_file_bytes, 0, 1024 * 1024 * 1024, "context.max_file_bytes")
  check_number(cfg.context.max_selection_lines, 0, 1000000, "context.max_selection_lines")

  local inline = cfg.inline
  if type(inline) ~= "table" then
    fail("inline must be a table")
  end
  if type(inline.enabled) ~= "boolean" then
    fail("inline.enabled must be a boolean")
  end
  check_enum(inline.scope, { "cursor", "context" }, "inline.scope")
  check_enum(inline.copy_dir, { "sibling", "state" }, "inline.copy_dir")
  if type(inline.expand_selection) ~= "boolean" then
    fail("inline.expand_selection must be a boolean")
  end
  if type(inline.allow_writes) ~= "boolean" then
    fail("inline.allow_writes must be a boolean")
  end
  if type(inline.allow_commands) ~= "boolean" then
    fail("inline.allow_commands must be a boolean")
  end
  check_number(inline.context_bytes, 1024, 8 * 1024 * 1024, "inline.context_bytes")
  check_number(inline.max_copy_bytes, 1024, 64 * 1024 * 1024, "inline.max_copy_bytes")
  local window = inline.window
  if type(window) ~= "table" then
    fail("inline.window must be a table")
  end
  local border_ok = type(window.border) == "table"
  if border_ok then
    if vim.islist(window.border) then
      if #window.border ~= 8 then
        fail("inline.window.border must be a name or a table of 8 characters")
      end
      for _, char in ipairs(window.border) do
        if type(char) ~= "string" or vim.fn.strdisplaywidth(char) > 1 then
          fail("inline.window.border characters must be strings of at most one display cell")
        end
      end
    else
      border_ok = false
    end
  end
  if not border_ok then
    check_enum(window.border, { "none", "single", "double", "rounded", "solid", "shadow" }, "inline.window.border")
  end
  check_enum(window.title_pos, { "left", "center", "right" }, "inline.window.title_pos")
  check_enum(window.style, { "minimal", "default" }, "inline.window.style")
  if type(window.highlights) ~= "table" then
    fail("inline.window.highlights must be a table")
  end
  for _, name in ipairs({ "normal", "border", "title" }) do
    local group = window.highlights[name]
    if type(group) ~= "string" or group == "" or group:find("%s") then
      fail("inline.window.highlights.%s must be a non-empty highlight group name", name)
    end
  end
  local prompt = window.prompt
  if type(prompt) ~= "table" then
    fail("inline.window.prompt must be a table")
  end
  check_enum(prompt.placement, { "cursor", "window" }, "inline.window.prompt.placement")
  check_number(prompt.width, 10, 1000, "inline.window.prompt.width")
  check_number(prompt.height, 1, 100, "inline.window.prompt.height")
  if type(prompt.offset) ~= "table" then
    fail("inline.window.prompt.offset must be a table")
  end
  check_number(prompt.offset.row, -1000, 1000, "inline.window.prompt.offset.row")
  check_number(prompt.offset.col, -1000, 1000, "inline.window.prompt.offset.col")
  if type(prompt.follow_cursor) ~= "boolean" then
    fail("inline.window.prompt.follow_cursor must be a boolean")
  end
  local review = inline.review
  if type(review) ~= "table" then
    fail("inline.review must be a table")
  end
  check_enum(review.mode, { "diff", "write" }, "inline.review.mode")
  local overrides = review.by_filetype
  if overrides == nil then
    overrides = {}
  end
  if type(overrides) ~= "table" or (next(overrides) ~= nil and vim.islist(overrides)) then
    fail("inline.review.by_filetype must be a table of filetype -> mode")
  end
  local count = 0
  for pattern, value in pairs(overrides) do
    count = count + 1
    if type(pattern) ~= "string" or pattern == "" or pattern:find("%s") then
      fail("inline.review.by_filetype keys must be non-empty filetypes without whitespace")
    end
    if type(value) == "table" then
      if (next(value) ~= nil and vim.islist(value)) or type(value.mode) ~= "string" then
        fail("inline.review.by_filetype[%q] must be a mode or a table with a mode", pattern)
      end
      value = value.mode
    end
    check_enum(value, { "diff", "write" }, "inline.review.by_filetype[" .. pattern .. "]")
  end
  if count > 256 then
    fail("inline.review.by_filetype has %d entries; at most 256 are supported", count)
  end
  local review_window = window.review
  if type(review_window) ~= "table" then
    fail("inline.window.review must be a table")
  end
  check_enum(review_window.placement, { "center", "cursor" }, "inline.window.review.placement")
  check_enum(review_window.target, { "buffer", "float" }, "inline.window.review.target")
  check_number(review_window.width, 20, 2000, "inline.window.review.width")
  check_number(review_window.height, 3, 500, "inline.window.review.height")
  check_enum(review_window.layout, { "3-column", "2-column" }, "inline.window.review.layout")
  check_number(review_window.min_split_width, 10, 2000, "inline.window.review.min_split_width")
  check_number(review_window.max_rows, 10, 1000000, "inline.window.review.max_rows")
  check_number(review_window.context, 0, 1000, "inline.window.review.context")
  check_number(review_window.foldcolumn, 0, 20, "inline.window.review.foldcolumn")
  for _, key in ipairs({ "advance", "syntax", "fold", "sync_scroll", "relative_number", "hints" }) do
    if type(review_window[key]) ~= "boolean" then
      fail("inline.window.review.%s must be a boolean", key)
    end
  end

  local images = cfg.context.images
  if type(images) ~= "table" then
    fail("context.images must be a table")
  end
  if type(images.enabled) ~= "boolean" then
    fail("context.images.enabled must be a boolean")
  end
  check_enum(images.path_mode, { "link", "inline" }, "context.images.path_mode")
  check_number(images.max_bytes, 1024, 64 * 1024 * 1024, "context.images.max_bytes")
  check_number(images.max_per_message, 1, 64, "context.images.max_per_message")
  if images.max_per_message % 1 ~= 0 then
    fail("context.images.max_per_message must be an integer")
  end
  check_number(images.ttl_hours, 0, 24 * 365, "context.images.ttl_hours")
  check_number(images.max_cache_bytes, 0, 1024 * 1024 * 1024, "context.images.max_cache_bytes")
  if images.clipboard ~= "auto" and images.clipboard ~= false then
    if type(images.clipboard) ~= "table" or not vim.islist(images.clipboard) or #images.clipboard == 0 then
      fail('context.images.clipboard must be "auto", false or a non-empty argv list')
    end
    for _, arg in ipairs(images.clipboard) do
      if type(arg) ~= "string" or arg == "" or arg:find("\0", 1, true) then
        fail("context.images.clipboard arguments must be non-empty strings without NUL")
      end
    end
  end
  -- base64 inflates by 4/3, and the JSON envelope adds a little more. A limit
  -- that cannot fit the transport would only fail after the user pressed send.
  local encoded = math.ceil(images.max_bytes * 4 / 3) + 64 * 1024
  if encoded > cfg.transport.max_line_bytes then
    fail(
      "context.images.max_bytes (%d) encodes to %d bytes, which exceeds transport.max_line_bytes (%d)",
      images.max_bytes,
      encoded,
      cfg.transport.max_line_bytes
    )
  end

  check_number(cfg.ui.toolbar.animation_interval, 10, 60000, "ui.toolbar.animation_interval")

  if type(cfg.permissions.auto_allow) ~= "table" or not vim.islist(cfg.permissions.auto_allow) then
    fail("permissions.auto_allow must be a list")
  end
  if type(cfg.permissions.show_details) ~= "boolean" then
    fail("permissions.show_details must be a boolean")
  end
  if type(cfg.notices) ~= "boolean" then
    fail("notices must be a boolean, got %s", type(cfg.notices))
  end
  local caps = cfg.capabilities
  if type(caps) ~= "table" then
    fail("capabilities must be a table, got %s", type(caps))
  end
  if type(caps.elicitation) ~= "table" then
    fail("capabilities.elicitation must be a table, got %s", type(caps.elicitation))
  end
  for _, key in ipairs({ "form", "url" }) do
    if type(caps.elicitation[key]) ~= "boolean" then
      fail("capabilities.elicitation.%s must be a boolean, got %s", key, type(caps.elicitation[key]))
    end
  end
  for _, key in ipairs({ "auth_terminal", "terminal_output_meta", "boolean_config_options", "fs", "terminal" }) do
    if type(caps[key]) ~= "boolean" then
      fail("capabilities.%s must be a boolean, got %s", key, type(caps[key]))
    end
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

---Validate one keymaps entry.
---
---A value is a key, a list of keys, or a per-mode map of keys; `false` disables
---the binding. Anything else is a configuration mistake worth reporting: an
---unmapped action silently doing nothing is much harder to debug than an error
---at setup time.
---@param value any
---@param path string
local function check_keymap_value(value, path)
  if value == false or value == nil then
    return
  end
  local function key(lhs, where)
    if type(lhs) ~= "string" then
      fail("%s%s must be a string, got %s", path, where, type(lhs))
    end
    if lhs ~= "" and not pcall(vim.keycode, lhs) then
      fail("%s%s is not a valid key notation: %s", path, where, lhs)
    end
  end
  if type(value) == "string" then
    key(value, "")
    return
  end
  if type(value) ~= "table" then
    fail("%s must be a string, a list of strings, a mode map or false, got %s", path, type(value))
  end
  if vim.islist(value) then
    for i, lhs in ipairs(value) do
      key(lhs, "[" .. i .. "]")
    end
    return
  end
  for mode, keys in pairs(value) do
    if not vim.tbl_contains({ "n", "i", "v", "x", "t", "c" }, mode) then
      fail("%s has an unknown mode %q", path, mode)
    end
    if type(keys) == "string" then
      key(keys, "." .. mode)
    elseif type(keys) == "table" and vim.islist(keys) then
      for i, lhs in ipairs(keys) do
        key(lhs, "." .. mode .. "[" .. i .. "]")
      end
    else
      fail("%s.%s must be a string or a list of strings", path, mode)
    end
  end
end

---Validate every entry of a resolved `keymaps` table.
---
---Expects a merged configuration, so every action's value in a view table is
---already the resolved one.
---@param cfg table
function M.normalize_keymaps(cfg)
  local keymaps = cfg.keymaps
  if type(keymaps) ~= "table" then
    fail("keymaps must be a table")
  end

  -- Lazy require: `acp.config` is loaded very early, and the action table lives
  -- with the code that installs the mappings.
  local ok, layout = pcall(require, "acp.ui.keymaps")
  if not ok then
    fail("unable to load acp.ui.keymaps: %s", tostring(layout))
  end

  local views = {}
  local view_list = {}
  for view in pairs(layout.actions) do
    views[view] = true
    view_list[#view_list + 1] = view
  end
  table.sort(view_list)

  -- Actions are grouped by view, so a bare `keymaps.send` is a mistake: it has
  -- to say which view it belongs to. Naming the owning view turns "unknown
  -- entry" into an actionable message.
  for name in pairs(keymaps) do
    if not views[name] then
      local owners = {}
      for view, actions in pairs(layout.actions) do
        for _, spec in ipairs(actions) do
          if spec.action == name then
            owners[#owners + 1] = view
          end
        end
      end
      if #owners > 0 then
        fail(
          "keymaps.%s must be nested under a view: %s",
          name,
          table.concat(
            vim.tbl_map(function(view)
              return "keymaps." .. view .. "." .. name
            end, owners),
            " / "
          )
        )
      end
      fail("unknown keymaps entry %q; expected one of: %s", name, table.concat(view_list, ", "))
    end
  end

  for view in pairs(views) do
    local entries = keymaps[view]
    if entries == nil then
      keymaps[view] = {}
    elseif type(entries) ~= "table" then
      fail("keymaps.%s must be a table", view)
    else
      local known = {}
      for _, spec in ipairs(layout.view_actions(view)) do
        known[spec.action] = true
      end
      for action, value in pairs(entries) do
        if not known[action] then
          fail("unknown keymaps.%s action %q", view, action)
        end
        check_keymap_value(value, "keymaps." .. view .. "." .. action)
      end

      -- Two actions on one key in the same mode: the later mapping would win
      -- silently, so say which pair clashes instead.
      for _, claim in pairs(layout.claims(view, entries)) do
        if claim.conflict then
          if claim.lhs == claim.conflict_lhs then
            fail("keymaps.%s: %s and %s both use %s", view, claim.action, claim.conflict, claim.lhs)
          end
          -- Different spellings of one key (`<Tab>` and `<C-i>`): name both so
          -- the user can see why they clash.
          fail(
            "keymaps.%s: %s (%s) and %s (%s) are the same key",
            view,
            claim.action,
            claim.lhs,
            claim.conflict,
            claim.conflict_lhs
          )
        end
      end
    end
  end
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
  -- Never take more than 60% of the screen.
  cols = math.min(cols, math.max(1, math.floor(total * 0.6)))
  return cols
end

return M
