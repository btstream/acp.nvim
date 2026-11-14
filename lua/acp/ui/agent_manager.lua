-- The agent manager window, modelled on `:Mason`.
--
-- One float lists every agent grouped by state (running, installed, available,
-- not managed). Keys act on the agent under the cursor; installs run in the
-- background, several at once, and their npm output streams under the row. The
-- window stays usable while that happens: it re-renders on every service event
-- and keeps the cursor on the same agent.
--
-- The window owns no decisions. It renders what `app/agent_manager` reports and
-- calls its actions; locking, npm and the transaction live behind that boundary.
local M = {}

local NS = vim.api.nvim_create_namespace("acp_agent_manager")
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local LIVE_LOG_LINES = 6
local DETAIL_LOG_LINES = 20

local HL = {
  AcpAgentsHeader = { link = "Title" },
  AcpAgentsHeading = { link = "Label" },
  AcpAgentsKey = { link = "Special" },
  AcpAgentsInstalled = { link = "DiagnosticOk" },
  AcpAgentsPending = { link = "DiagnosticWarn" },
  AcpAgentsError = { link = "DiagnosticError" },
  AcpAgentsMuted = { link = "Comment" },
  AcpAgentsName = { link = "Function" },
  AcpAgentsVersion = { link = "Number" },
  AcpAgentsUpdate = { link = "DiagnosticInfo" },
}

local function define_highlights()
  for name, spec in pairs(HL) do
    pcall(vim.api.nvim_set_hl, 0, name, vim.tbl_extend("force", { default = true }, spec))
  end
end

local PHASE_TEXT = {
  checking = "resolving version",
  installing = "installing",
  verifying = "verifying",
  committed = "finishing",
  removed = "removing",
}

---A line builder that records highlight spans as it goes.
local function builder()
  local b = { lines = {}, hls = {}, ids = {} }

  ---Append one line made of `{text, hl}` chunks.
  ---@param chunks table[]
  ---@param id string|nil agent the line belongs to (for cursor actions)
  function b.add(chunks, id)
    local text, col = "", 0
    local lnum = #b.lines
    for _, chunk in ipairs(chunks) do
      local piece = chunk[1] or ""
      if chunk[2] and piece ~= "" then
        b.hls[#b.hls + 1] = { lnum, col, col + #piece, chunk[2] }
      end
      text = text .. piece
      col = col + #piece
    end
    b.lines[#b.lines + 1] = text
    b.ids[#b.lines] = id
  end

  function b.blank()
    b.add({ { "" } })
  end

  return b
end

---Which section a row belongs to.
---@param row table
---@return "running"|"installed"|"available"|"external"
function M.section(row)
  if row.task then
    return "running"
  end
  if row.status == "installed" or row.status == "broken" then
    return "installed"
  end
  if row.installable then
    return "available"
  end
  return "external"
end

---Whether an external command can be found.
---@param command string|nil
---@return boolean
local function executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

---@param row table
---@return string
local function command_line(row)
  local command = row.command or ""
  if row.args and #row.args > 0 then
    command = command .. " " .. table.concat(row.args, " ")
  end
  return command
end

---Append the last `count` log lines, indented.
local function add_log(b, row, count)
  local log = row.log or {}
  local first = math.max(1, #log - count + 1)
  for index = first, #log do
    b.add({ { "      " }, { log[index], "AcpAgentsMuted" } }, row.id)
  end
end

---The headline for one agent.
---@param b table
---@param row table
---@param opts table
local function add_row(b, row, opts)
  local chunks = { { "    " } }
  local section = M.section(row)
  local outcome = row.outcome
  if section == "running" then
    chunks[#chunks + 1] = { opts.spinner .. " ", "AcpAgentsPending" }
  elseif row.status == "broken" or (outcome and outcome.phase == "failed") then
    chunks[#chunks + 1] = { "✗ ", "AcpAgentsError" }
  elseif section == "installed" then
    chunks[#chunks + 1] = { "✓ ", "AcpAgentsInstalled" }
  elseif section == "external" then
    chunks[#chunks + 1] = { "● ", executable(row.command) and "AcpAgentsInstalled" or "AcpAgentsMuted" }
  else
    chunks[#chunks + 1] = { "○ ", "AcpAgentsMuted" }
  end
  chunks[#chunks + 1] = { row.id, "AcpAgentsName" }

  if section == "running" then
    local task = row.task
    local text = PHASE_TEXT[task.phase] or task.action
    if task.action == "uninstall" then
      text = "uninstalling"
    end
    chunks[#chunks + 1] = { " " }
    chunks[#chunks + 1] = { text, "AcpAgentsPending" }
    if task.version then
      chunks[#chunks + 1] = { " " .. task.version, "AcpAgentsVersion" }
    end
  elseif section == "installed" then
    if row.install and row.install.version then
      chunks[#chunks + 1] = { " " .. row.install.version, "AcpAgentsVersion" }
    end
    if row.status == "broken" then
      chunks[#chunks + 1] = { " broken — press i to reinstall", "AcpAgentsError" }
    elseif row.outdated then
      chunks[#chunks + 1] = { " → " .. row.latest, "AcpAgentsUpdate" }
      chunks[#chunks + 1] = { " (press u to update)", "AcpAgentsMuted" }
    end
  elseif section == "available" then
    chunks[#chunks + 1] = { " " .. tostring(row.package), "AcpAgentsMuted" }
    if row.available and row.source == "external" and executable(row.command) then
      chunks[#chunks + 1] = { "  using " .. command_line(row) .. " from PATH", "AcpAgentsMuted" }
    end
  else
    if row.available then
      local found = executable(row.command)
      chunks[#chunks + 1] = { " " .. command_line(row), "AcpAgentsMuted" }
      if not found then
        chunks[#chunks + 1] = { "  not found on PATH", "AcpAgentsError" }
      end
    else
      chunks[#chunks + 1] = { " unavailable", "AcpAgentsError" }
    end
  end
  if outcome and outcome.phase == "failed" and section ~= "running" then
    chunks[#chunks + 1] = { "  " .. (outcome.action or "") .. " failed", "AcpAgentsError" }
  end
  if row.current then
    chunks[#chunks + 1] = { "  (current)", "AcpAgentsKey" }
  end
  b.add(chunks, row.id)

  if section == "running" then
    add_log(b, row, LIVE_LOG_LINES)
  elseif not opts.expanded[row.id] and outcome and outcome.phase == "failed" then
    b.add({ { "      " }, { tostring(outcome.message), "AcpAgentsError" } }, row.id)
  end

  if opts.expanded[row.id] then
    local function detail(label, value, hl)
      if value ~= nil and value ~= "" then
        b.add({ { "      " }, { label .. ": ", "AcpAgentsHeading" }, { tostring(value), hl } }, row.id)
      end
    end
    detail("Title", row.title)
    if row.installable then
      detail("Package", row.package)
    end
    if row.latest then
      detail("Latest", row.latest, "AcpAgentsVersion")
    end
    detail("Homepage", row.homepage)
    if row.status ~= "not_installed" then
      detail("Location", row.root)
    end
    if row.available then
      detail("Launch", string.format("[%s] %s", tostring(row.source), command_line(row)))
    end
    detail("Problem", row.error, "AcpAgentsError")
    detail("Launch error", row.resolve_error, "AcpAgentsError")
    for _, requirement in ipairs(row.requires or {}) do
      detail("Needs", requirement)
    end
    for _, note in ipairs(row.notes or {}) do
      detail("Note", note, "AcpAgentsMuted")
    end
    if outcome and outcome.phase == "failed" then
      detail("Error", outcome.message, "AcpAgentsError")
    end
    if row.log and #row.log > 0 and section ~= "running" then
      b.add({ { "      " }, { "Last log:", "AcpAgentsHeading" } }, row.id)
      add_log(b, row, DETAIL_LOG_LINES)
    end
  end
end

local HELP = {
  { "i", "install the agent under the cursor" },
  { "u", "update it (no-op when already at the latest version)" },
  { "U", "update every outdated managed agent" },
  { "X", "uninstall the managed copy" },
  { "C", "check npm for newer versions" },
  { "<CR>", "expand / collapse details" },
  { "s", "switch the chat to this agent" },
  { "r", "refresh" },
  { "g?", "toggle this help" },
  { "q", "close" },
}

---Render the whole window.
---@param rows table[]
---@param opts {expanded?: table<string, boolean>, spinner?: string, help?: boolean,
---  checking?: boolean, toolchain?: string|nil}|nil
---@return {lines: string[], hls: table[], ids: table<integer, string>}
function M.render(rows, opts)
  opts = opts or {}
  opts.expanded = opts.expanded or {}
  opts.spinner = opts.spinner or SPINNER[1]
  local b = builder()
  b.add({ { " acp.nvim", "AcpAgentsHeader" }, { " · agents", "AcpAgentsMuted" } })
  b.add({
    { " " },
    { "i", "AcpAgentsKey" },
    { " install  " },
    { "u", "AcpAgentsKey" },
    { " update  " },
    { "U", "AcpAgentsKey" },
    { " update all  " },
    { "X", "AcpAgentsKey" },
    { " uninstall  " },
    { "C", "AcpAgentsKey" },
    { " check  " },
    { "s", "AcpAgentsKey" },
    { " use  " },
    { "g?", "AcpAgentsKey" },
    { " help" },
  })
  if opts.checking then
    b.add({ { " " .. opts.spinner .. " checking for newer versions…", "AcpAgentsPending" } })
  end
  if opts.toolchain then
    b.add({ { " ⚠ " .. opts.toolchain, "AcpAgentsError" } })
  end
  b.blank()

  if opts.help then
    b.add({ { " Keys", "AcpAgentsHeading" } })
    for _, entry in ipairs(HELP) do
      b.add({ { "    " }, { string.format("%-6s", entry[1]), "AcpAgentsKey" }, { entry[2] } })
    end
    b.blank()
  end

  local groups = { running = {}, installed = {}, available = {}, external = {} }
  for _, row in ipairs(rows) do
    local list = groups[M.section(row)]
    list[#list + 1] = row
  end
  local sections = {
    { "running", "Running" },
    { "installed", "Installed" },
    { "available", "Available" },
    { "external", "Not managed" },
  }
  for _, section in ipairs(sections) do
    local list = groups[section[1]]
    if #list > 0 then
      b.add({ { "  " .. section[2], "AcpAgentsHeading" }, { string.format(" (%d)", #list), "AcpAgentsMuted" } })
      for _, row in ipairs(list) do
        add_row(b, row, opts)
      end
      b.blank()
    end
  end
  return b
end

---@param deps {manager: table, on_use: fun(id: string), config: fun(): table}
---@return table
function M.new(deps)
  return setmetatable({
    deps = deps,
    win = nil,
    buf = nil,
    augroup = nil,
    expanded = {},
    help = false,
    ids = {},
    frame = 1,
    timer = nil,
  }, { __index = M })
end

function M:stop_timer()
  if self.timer then
    pcall(function()
      self.timer:stop()
      self.timer:close()
    end)
    self.timer = nil
  end
end

---Animate the spinner only while something is running.
function M:sync_timer()
  local manager = self.deps.manager
  local active = (manager.busy and manager:busy()) or (manager.is_checking and manager:is_checking())
  if active and not self.timer and self:is_open() then
    self.timer = vim.uv.new_timer()
    self.timer:start(
      100,
      100,
      vim.schedule_wrap(function()
        if not self:is_open() then
          self:stop_timer()
          return
        end
        self.frame = self.frame % #SPINNER + 1
        self:refresh()
      end)
    )
  elseif not active then
    self:stop_timer()
  end
end

function M:close()
  self:stop_timer()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win = nil
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

---The agent on the cursor line (or the nearest agent line above it).
---@return string|nil
function M:current_id()
  if not self:is_open() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
  return self.ids[lnum]
end

---Redraw from the manager's current state, keeping the cursor on its agent.
function M:refresh()
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local manager = self.deps.manager
  local cursor_id, offset
  if self:is_open() then
    local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
    cursor_id = self.ids[lnum]
    if cursor_id then
      -- Remember how far into the agent's block the cursor is.
      local first = lnum
      while first > 1 and self.ids[first - 1] == cursor_id do
        first = first - 1
      end
      offset = lnum - first
    end
  end

  local rendered = M.render(manager:list(), {
    expanded = self.expanded,
    spinner = SPINNER[self.frame],
    help = self.help,
    checking = manager.is_checking and manager:is_checking() or false,
    toolchain = self.toolchain_problem,
  })
  self.ids = rendered.ids
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, rendered.lines)
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  for _, hl in ipairs(rendered.hls) do
    pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, hl[1], hl[2], { end_col = hl[3], hl_group = hl[4] })
  end

  if self:is_open() then
    local target
    if cursor_id then
      for lnum = 1, #rendered.lines do
        if rendered.ids[lnum] == cursor_id then
          target = lnum + (offset or 0)
          if rendered.ids[target] ~= cursor_id then
            target = lnum
          end
          break
        end
      end
    end
    if not target then
      for lnum = 1, #rendered.lines do
        if rendered.ids[lnum] then
          target = lnum
          break
        end
      end
    end
    if target then
      pcall(vim.api.nvim_win_set_cursor, self.win, { target, 0 })
    end
  end
  self:sync_timer()
end

---Put the cursor on an agent's headline.
---@param id string
function M:focus_agent(id)
  for lnum = 1, vim.api.nvim_buf_line_count(self.buf) do
    if self.ids[lnum] == id then
      pcall(vim.api.nvim_win_set_cursor, self.win, { lnum, 0 })
      return
    end
  end
end

---@param lhs string
---@param fn fun()
function M:map(lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true })
end

---Run `fn(id)` for the agent under the cursor.
---@param fn fun(id: string)
---@return fun()
function M:on_agent(fn)
  return function()
    local id = self:current_id()
    if id then
      fn(id)
    else
      vim.notify("acp.nvim: move the cursor onto an agent", vim.log.levels.INFO)
    end
  end
end

---Check node/npm once per window open and surface a missing toolchain.
function M:probe_toolchain()
  local cfg = self.deps.config and self.deps.config() or {}
  local manager_cfg = type(cfg.manager) == "table" and cfg.manager or {}
  local problem
  if vim.fn.executable(manager_cfg.node or "node") ~= 1 then
    problem = "node was not found; managed agents need Node.js 22+"
  elseif vim.fn.executable(manager_cfg.npm or "npm") ~= 1 then
    problem = "npm was not found; installs need npm"
  end
  self.toolchain_problem = problem
end

function M:open()
  define_highlights()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
    self:refresh()
    return
  end
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "acp_agents"
  vim.bo[self.buf].modifiable = false
  local width = math.min(110, math.max(60, math.floor(vim.o.columns * 0.8)))
  local height = math.max(12, math.floor((vim.o.lines - vim.o.cmdheight) * 0.8))
  self.win = vim.api.nvim_open_win(self.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Agents ",
    title_pos = "center",
  })
  vim.wo[self.win].cursorline = true
  vim.wo[self.win].wrap = false
  self:probe_toolchain()
  self:refresh()

  local manager = self.deps.manager
  self:map(
    "i",
    self:on_agent(function(id)
      manager:install(id)
    end)
  )
  self:map(
    "u",
    self:on_agent(function(id)
      manager:update(id)
    end)
  )
  self:map("U", function()
    if manager.update_all then
      manager:update_all()
    end
  end)
  local uninstall = self:on_agent(function(id)
    manager:uninstall(id)
  end)
  self:map("X", uninstall)
  self:map("d", uninstall)
  self:map("C", function()
    if manager.check_outdated then
      manager:check_outdated()
      self:refresh()
    end
  end)
  self:map(
    "<CR>",
    self:on_agent(function(id)
      self.expanded[id] = not self.expanded[id] or nil
      self:refresh()
      self:focus_agent(id)
    end)
  )
  self:map(
    "s",
    self:on_agent(function(id)
      self:close()
      self.deps.on_use(id)
    end)
  )
  self:map("r", function()
    self:refresh()
  end)
  self:map("g?", function()
    self.help = not self.help
    self:refresh()
  end)
  self:map("q", function()
    self:close()
  end)
  self:map("<Esc>", function()
    self:close()
  end)

  self.augroup = vim.api.nvim_create_augroup("AcpAgentManager", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      self:stop_timer()
      self.win = nil
      self.buf = nil
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      vim.schedule(function()
        local manager = self.deps.manager
        if manager and (manager.asking or 0) > 0 then
          return
        end
        self:close()
      end)
    end,
  })

  -- Like Mason, look for newer versions in the background on open, at most
  -- once every ten minutes. Only `npm view`; nothing is installed.
  if manager.check_outdated then
    local last = manager.checked_at
    if not last or vim.uv.now() - last > 10 * 60 * 1000 then
      manager:check_outdated()
      self:refresh()
    end
  end
end

---Whether the window is showing.
---@return boolean
function M:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

return M
