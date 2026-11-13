-- Authentication: detect auth-required errors, run a login method, retry.
--
-- Three agents, three ways to log in, one flow: the agent offers authMethods,
-- each is either an interactive terminal command or an `authenticate` call.
-- A terminal login restarts the process; an agent login stays in the same
-- connection. Both re-run the operation that failed.
local async = require("acp.async")
local log = require("acp.log")
local presenter = require("acp.app.presenter")

local M, Auth = {}, {}
Auth.__index = Auth

-- ACP `auth_required` (spec §Error codes). Matched by code, never by message
-- text: agents word it differently ("Authentication required", "not logged
-- in", ...). Client-side failures use a different code on purpose; see
-- transport/jsonrpc.lua.
local AUTH_REQUIRED = -32000

-- An agent that keeps returning auth_required right after a successful login
-- (wrong account, expired credential) must not loop forever opening terminals.
local MAX_LOGIN_ATTEMPTS = 2

---Whether an RPC error asks the client to authenticate.
---@param err any
---@return boolean
function M.is_auth_error(err)
  return type(err) == "table" and err.code == AUTH_REQUIRED
end

---Methods carried by an auth error, when the agent included them.
---@param err any
---@return table[]|nil
function M.methods_from(err)
  if type(err) ~= "table" then
    return nil
  end
  local data = err.data
  if type(data) == "table" then
    if type(data.authMethods) == "table" then
      return data.authMethods
    end
    if type(data.auth_methods) == "table" then
      return data.auth_methods
    end
  end
  if type(err.authMethods) == "table" then
    return err.authMethods
  end
  return nil
end

local function shell_quote(value)
  if value == nil or value == "" then
    return "''"
  end
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

---Command and arguments for a terminal login.
---
---ACP is explicit: the descriptor cannot provide a command, and the client
---derives it from its own Agent configuration (authentication.md, "Terminal
---authentication"). Only `args` and `env` come from the agent. Both are merged
---onto the configured launch: args are appended, env overrides same-named
---variables.
---@param method table
---@param agent table
---@return {command: string, args: string[], env: table<string,string>|nil}
function M.terminal_spec(method, agent)
  local args = vim.list_extend(vim.list_extend({}, agent.args or {}), method.args or {})
  local env
  if type(agent.env) == "table" or type(method.env) == "table" then
    env = vim.tbl_extend("force", agent.env or {}, method.env or {})
  end
  return { command = agent.command, args = args, env = env }
end

---@param spec {command: string, args: string[], env: table<string,string>|nil}
---@return string
function M.command_line(spec)
  local parts = { shell_quote(spec.command) }
  for _, arg in ipairs(spec.args or {}) do
    parts[#parts + 1] = shell_quote(arg)
  end
  return table.concat(parts, " ")
end

---Windows that belong to the panel. A login terminal must neither replace
---them nor be counted as the "focus to return to" when the panel closes.
---@param win integer
---@return boolean
local function is_panel_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  return ft == "acp_chat" or ft == "acp_input"
end

---Pick where to put the login terminal: the remembered editor window when the
---panel knows one, otherwise any non-panel window, otherwise the current one.
---@param preferred integer|nil
---@return integer win
local function login_base_window(preferred)
  if preferred and vim.api.nvim_win_is_valid(preferred) and not is_panel_window(preferred) then
    return preferred
  end
  local current = vim.api.nvim_get_current_win()
  if not is_panel_window(current) then
    return current
  end
  local fallback
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not is_panel_window(win) then
      if not fallback or vim.api.nvim_win_get_height(win) > vim.api.nvim_win_get_height(fallback) then
        fallback = win
      end
    end
  end
  return fallback or current
end

---Open a terminal buffer and run `command` in it.
---@param command string
---@param opts {cwd: string|nil, env: table<string,string>|nil, on_exit: fun(code: integer)}
---@return integer|nil buf
local function start_terminal(command, opts)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "acp_login"
  local job = vim.fn.termopen(command, {
    cwd = opts.cwd,
    env = opts.env,
    on_exit = function(_, code)
      vim.schedule(function()
        opts.on_exit(code or 0)
      end)
    end,
  })
  if job <= 0 then
    vim.schedule(function()
      opts.on_exit(-1)
    end)
    return nil
  end
  vim.cmd("startinsert")
  return buf
end

---Default terminal runner: a split under an editor window, or a new tab.
---
---A login is a side errand: it must not replace the composer or the chat view,
---and a small editor must still be able to show it. When no split fits, a tab
---is opened instead of failing.
---@param command string
---@param opts {cwd: string|nil, env: table<string,string>|nil, base: integer|nil, on_exit: fun(code: integer)}
function M.open_terminal(command, opts)
  local cwd = opts.cwd or vim.fn.getcwd()
  local base = login_base_window(opts.base)
  local split = pcall(function()
    vim.api.nvim_set_current_win(base)
    vim.cmd("belowright split")
  end)
  if not split then
    -- No room for a horizontal split: use a tab rather than failing the login.
    local tabbed = pcall(vim.cmd, "tabnew")
    if not tabbed then
      error("no window available for the login terminal")
    end
  end
  return start_terminal(command, { cwd = cwd, env = opts.env, on_exit = opts.on_exit })
end

---@param opts {config: fun(): table, client: fun(): table|nil,
---  notify: fun(message: string, level: integer|nil),
---  restart: fun(), after_ready: fun(fn: fun()),
---  base_window: fun(): integer|nil,
---  open_terminal: fun(command: string, opts: table)|nil,
---  on_changed: fun()|nil}
function M.new(opts)
  return setmetatable({
    config = opts.config,
    get_client = opts.client,
    notify = opts.notify or function() end,
    restart = opts.restart or function() end,
    after_ready = opts.after_ready or function(fn)
      fn()
    end,
    base_window = opts.base_window,
    open_terminal = opts.open_terminal or M.open_terminal,
    on_changed = opts.on_changed or function() end,
    running = false,
    attempts = 0,
    cancelled = false,
  }, Auth)
end

---Abandon an in-flight login (the user stopped the agent on purpose).
function Auth:cancel()
  self.cancelled = true
  self.running = false
  self.attempts = 0
  self.on_changed()
end

---Whether a login is currently waiting on an interactive terminal.
---@return boolean
function Auth:is_running()
  return self.running
end

---Reset the failure counter, so a later unrelated login starts fresh.
function Auth:reset()
  self.attempts = 0
end

---The login methods the agent offered at initialize time.
---@return table[]
function Auth:methods()
  local client = self.get_client()
  local methods = client and client.auth_methods or nil
  return type(methods) == "table" and methods or {}
end

---Whether the agent supports logging out (`auth.logout`).
---@return boolean
function Auth:can_logout()
  local client = self.get_client()
  local caps = client and client.capabilities or nil
  local auth = type(caps) == "table" and caps.auth or nil
  return type(auth) == "table" and auth.logout ~= nil
end

---Run one method, then hand control back through `retry`.
---@param method table
---@param retry fun()|nil
function Auth:run(method, retry)
  local client = self.get_client()
  if type(method) ~= "table" or type(method.id) ~= "string" then
    self.notify("the agent did not offer a usable login method", vim.log.levels.WARN)
    return
  end
  local meta = type(method._meta) == "table" and method._meta["terminal-auth"] or nil
  local terminal = method.type == "terminal" or meta ~= nil

  if not terminal then
    if not client then
      self.notify("the agent is not connected", vim.log.levels.WARN)
      return
    end
    self.running = true
    async.run(function()
      local ok, err = client:authenticate(method.id)
      self.running = false
      if ok then
        self:reset()
        self.notify("Logged in", vim.log.levels.INFO)
        if retry then
          retry()
        end
      else
        local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
        self.notify("login failed: " .. message, vim.log.levels.ERROR)
      end
      self.on_changed()
    end)
    return
  end

  local agent = self.config().agents[self.config().agent] or {}
  local spec = M.terminal_spec(method, agent)
  local command = M.command_line(spec)
  -- The protocol asks clients to show what they are about to run: the args and
  -- env come from the agent, not from the user's own configuration.
  if #spec.args > 0 or next(spec.env or {}) ~= nil then
    local shown = { "$ " .. command }
    for key, value in pairs(spec.env or {}) do
      shown[#shown + 1] = string.format("  %s=%s", key, tostring(value))
    end
    self.notify("running login command:\n" .. table.concat(shown, "\n"), vim.log.levels.INFO)
  end
  log.info("running login command: %s", command)
  self.running = true
  self.cancelled = false
  self.on_changed()
  local opened, err = pcall(self.open_terminal, command, {
    cwd = self.config().cwd or vim.fn.getcwd(),
    env = spec.env,
    -- The panel remembers the editor window the user last worked in; placing
    -- the login there keeps the panel's own layout untouched.
    base = self.base_window and self.base_window() or nil,
    on_exit = function(code)
      self.running = false
      self.on_changed()
      if self.cancelled then
        self.cancelled = false
        return
      end
      if code ~= 0 then
        self.notify(string.format("login command exited with %d; still logged out", code), vim.log.levels.WARN)
        return
      end
      self.attempts = self.attempts + 1
      if self.attempts > MAX_LOGIN_ATTEMPTS then
        self.notify(
          string.format(
            "logged in but the agent still refuses; check its documentation (gave up after %d attempts)",
            MAX_LOGIN_ATTEMPTS
          ),
          vim.log.levels.ERROR
        )
        -- Stay stopped: an automatic retry loop must not reopen terminals
        -- forever. `:Acp login` resets the counter for a deliberate retry.
        return
      end
      self.notify("login finished; restarting the agent", vim.log.levels.INFO)
      -- A terminal login replaces the agent's credentials on disk, so the
      -- running process has to be restarted even though it still answers. The
      -- friendly `reconnect` is a no-op while the connection is ready.
      self.restart()
      if retry then
        self.after_ready(retry)
      end
    end,
  })
  if not opened then
    self.running = false
    self.on_changed()
    self.notify("unable to open a login terminal: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---Choose a method (single method runs directly) and log in.
---@param methods table[]|nil
---@param retry fun()|nil
function Auth:login(methods, retry)
  methods = methods or self:methods()
  if #methods == 0 then
    self.notify(
      "this agent did not report a login method; see its documentation to sign in, then reconnect",
      vim.log.levels.WARN
    )
    return false
  end
  if #methods == 1 then
    self:run(methods[1], retry)
    return true
  end
  local items = {}
  for _, method in ipairs(methods) do
    items[#items + 1] = {
      label = method.name or method.id,
      description = method.description,
      value = method,
    }
  end
  presenter.select({
    title = "Log in",
    items = items,
    on_choice = function(method)
      self:run(method, retry)
    end,
  })
  return true
end

---Handle an auth-required error for a failed operation.
---
---Returns false when the error is not an auth error, so callers can keep their
---normal error path.
---@param err any
---@param opts {retry: fun()|nil, methods: table[]|nil}|nil
---@return boolean handled
function Auth:require(err, opts)
  if not M.is_auth_error(err) then
    return false
  end
  local methods = (opts and opts.methods) or M.methods_from(err) or self:methods()
  self.notify("This agent requires a login", vim.log.levels.WARN)
  return self:login(methods, opts and opts.retry or nil)
end

---Log out, when the agent declares support.
---@return boolean started
function Auth:logout()
  local client = self.get_client()
  if not client then
    self.notify("the agent is not connected", vim.log.levels.WARN)
    return false
  end
  if not self:can_logout() then
    self.notify("this agent does not support logging out", vim.log.levels.WARN)
    return false
  end
  async.run(function()
    local ok, err = client:logout()
    if ok then
      self.notify("Logged out; new sessions will require logging in again (:Acp login)", vim.log.levels.INFO)
    else
      local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
      self.notify("logout failed: " .. message, vim.log.levels.ERROR)
    end
    self.on_changed()
  end)
  return true
end

return M
