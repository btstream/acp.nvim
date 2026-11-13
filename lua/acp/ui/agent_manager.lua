-- The agent manager window.
--
-- A read-only list of agents plus a keys hint, not a picker: the actions are
-- long-running (npm install) and the state has to keep updating while the window
-- stays open. The picker backends cannot do that.
--
-- The window owns no decisions. It renders what `app/agent_manager` reports and
-- calls its actions; everything else (confirmation, locks, npm) happens behind
-- that boundary.
local M = {}

---Colour/text for one status.
---@param row table
---@return string
local function status_text(row)
  if row.status == "installed" then
    return string.format("managed  installed  %s", row.install and row.install.version or "?")
  end
  if row.status == "broken" then
    return "managed  broken"
  end
  if row.source == "managed" then
    return "managed  missing"
  end
  if row.available then
    local command = row.command or ""
    if row.args and #row.args > 0 then
      command = command .. " " .. table.concat(row.args, " ")
    end
    return "external  " .. command
  end
  return "unavailable"
end

---One display line per agent.
---@param row table
---@return string
function M.row_line(row)
  local marker = row.current and "*" or " "
  return string.format("%s %-10s %s", marker, row.id, status_text(row))
end

---The full buffer content.
---@param rows table[]
---@param progress table|nil
---@param selected string|nil
---@return string[]
function M.render(rows, progress, selected)
  local lines = { "ACP Agents", "" }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = M.row_line(row)
  end
  lines[#lines + 1] = ""
  local current
  for _, row in ipairs(rows) do
    if row.id == selected then
      current = row
    end
  end
  if current then
    lines[#lines + 1] = "Selected: " .. current.title
    lines[#lines + 1] = "Package: " .. tostring(current.package)
    if current.install then
      lines[#lines + 1] = "Version: " .. tostring(current.install.version)
    end
    if current.root then
      lines[#lines + 1] = "Location: " .. current.root
    end
    if current.homepage then
      lines[#lines + 1] = "Source: " .. current.homepage
    end
    if current.error then
      lines[#lines + 1] = "Problem: " .. current.error
    end
    if current.resolve_error then
      lines[#lines + 1] = "Launch: " .. current.resolve_error
    end
    for _, requirement in ipairs(current.requires or {}) do
      lines[#lines + 1] = "Needs: " .. requirement
    end
  end
  if progress then
    lines[#lines + 1] = ""
    local text = string.format("%s: %s", progress.id or "?", progress.phase or "?")
    if progress.version then
      text = text .. " " .. progress.version
    end
    if progress.message then
      text = text .. " — " .. progress.message
    end
    lines[#lines + 1] = text
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "i install   u update   d uninstall   Enter use"
  lines[#lines + 1] = "r refresh   q close"
  return lines
end

---@param deps {manager: table, on_use: fun(id: string), config: fun(): table}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps, win = nil, buf = nil, augroup = nil, selected = nil }, { __index = M })
end

function M:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win = nil
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
end

---Redraw from the manager's current state.
function M:refresh()
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local rows = self.deps.manager:list()
  local progress = self.deps.manager.progress
  if not self.selected and #rows > 0 then
    -- Start on the configured agent when it is listed; otherwise the first row.
    self.selected = rows[1].id
    for _, row in ipairs(rows) do
      if row.current then
        self.selected = row.id
        break
      end
    end
  end
  local lines = M.render(rows, progress, self.selected)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  vim.bo[self.buf].modifiable = false
  -- Highlight the selected agent row so the detail block has an anchor.
  local ns = vim.api.nvim_create_namespace("acp_agent_manager")
  vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for index, row in ipairs(rows) do
    if row.id == self.selected then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, index + 1, 0, {
        line_hl_group = "AcpAgentManagerSelected",
        end_col = #lines[index + 2],
      })
    end
  end
end

---Move the selection to the row under the cursor.
function M:sync_selection()
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(self.win)[1]
  local line = vim.api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
  local id = line:match("^[%* ] (%S+)%s")
  if id then
    self.selected = id
    self:refresh()
  end
end

---Ask for one filetype-local mapping.
---@param mode string
---@param lhs string
---@param fn fun()
function M:map(mode, lhs, fn)
  vim.keymap.set(mode, lhs, fn, { buffer = self.buf, nowait = true, silent = true })
end

function M:open()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    self:refresh()
    return
  end
  local rows = self.deps.manager:list()
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].filetype = "acp_agents"
  vim.bo[self.buf].modifiable = false
  local width = math.min(100, math.max(60, vim.o.columns - 20))
  local height = math.max(12, math.min(#rows + 14, vim.o.lines - 6))
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Agent manager ",
    title_pos = "center",
  }
  self.win = vim.api.nvim_open_win(self.buf, true, opts)
  self:refresh()

  local manager = self.deps.manager
  self:map("n", "i", function()
    local id = self.selected
    if id then
      manager:install(id)
    end
  end)
  self:map("n", "u", function()
    local id = self.selected
    if id then
      manager:update(id)
    end
  end)
  self:map("n", "d", function()
    local id = self.selected
    if id then
      manager:uninstall(id)
    end
  end)
  self:map("n", "r", function()
    self:refresh()
  end)
  self:map("n", "q", function()
    self:close()
  end)
  self:map("n", "<CR>", function()
    local id = self.selected
    if not id then
      return
    end
    if not self.deps.manager:list()[1] then
      return
    end
    self:close()
    self.deps.on_use(id)
  end)
  self:map("n", "j", function()
    local row = vim.api.nvim_win_get_cursor(self.win)[1]
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.min(row + 1, #rows + 1), 0 })
    self:sync_selection()
  end)
  self:map("n", "k", function()
    local row = vim.api.nvim_win_get_cursor(self.win)[1]
    pcall(vim.api.nvim_win_set_cursor, self.win, { math.max(row - 1, 1), 0 })
    self:sync_selection()
  end)

  self.augroup = vim.api.nvim_create_augroup("AcpAgentManager", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      self.win = nil
      self.buf = nil
    end,
  })
end

---Whether the window is showing.
---@return boolean
function M:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

return M
