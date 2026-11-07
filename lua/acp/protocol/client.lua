-- ACP client: process lifecycle, initialization, sessions and prompts.
local Log = require("acp.log")
local rpcmod = require("acp.transport.jsonrpc")
local process = require("acp.transport.process")
local async = require("acp.async")

local M = {}

local PROTOCOL_VERSION = 1
local CLIENT_INFO = { name = "acp.nvim", title = "acp.nvim", version = "0.1.0" }

local REQUEST_TIMEOUT = 30000

---@class AcpClient
---@field rpc AcpRpc
---@field proc AcpProcess|nil
---@field capabilities table
---@field auth_methods table[]
---@field on_event fun(name: string, payload: any)
---@field permissions table<string, {respond: fun(result:any), session_id: string}>
---@field generation integer
local Client = {}
Client.__index = Client

---@param opts {agent: table, cwd: string, client_capabilities: table, limits?: table, on_event: fun(name: string, payload: any)}
---@return AcpClient
function M.new(opts)
  local self = setmetatable({
    agent = opts.agent,
    cwd = opts.cwd,
    limits = opts.limits,
    client_capabilities = opts.client_capabilities,
    on_event = opts.on_event or function() end,
    permissions = {},
    permission_seq = 0,
    generation = 0,
    proc = nil,
    rpc = nil,
    capabilities = {},
    auth_methods = {},
    starting = false,
    initialized = false,
  }, Client)

  return self
end

function Client:emit(name, payload)
  local ok, err = pcall(self.on_event, name, payload)
  if not ok then
    Log.error("event handler %s failed: %s", name, err)
  end
end

---Start the agent process and initialize the connection.
---@param cb fun(ok: boolean, err: any)
function Client:start(cb)
  if self.starting or self.initialized then
    if cb then
      cb(true, nil)
    end
    return
  end
  self.starting = true
  local generation = self.generation + 1
  self.generation = generation

  async.run(function()
    local ok, err = self:do_start(generation)
    self.starting = false
    if cb then
      cb(ok, err)
    end
  end)
end

function Client:do_start(generation)
  local cfg = self.agent
  local limits = self.limits or {}
  local max_line = limits.max_line_bytes or 8 * 1024 * 1024
  local stderr_keep = limits.stderr_keep_bytes or 64 * 1024

  local proc, err = process.spawn({
    command = cfg.command,
    args = cfg.args,
    cwd = self.cwd,
    env = cfg.env,
    max_line_bytes = max_line,
    stderr_keep_bytes = stderr_keep,
    shutdown_timeout = limits.shutdown_timeout,
    on_line = function(line)
      self:on_line(line)
    end,
    on_exit = function(code, stderr)
      self:handle_exit(code, stderr, generation)
    end,
  })
  if not proc then
    self:emit("connection_error", err)
    return false, err
  end
  self.proc = proc
  self.generation = generation

  self.rpc = rpcmod.new({
    send = function(payload)
      return proc:write(payload)
    end,
  })
  self:install_handlers()

  self:emit("starting", {})
  local ok, result = self:request("initialize", {
    protocolVersion = PROTOCOL_VERSION,
    clientCapabilities = self.client_capabilities,
    clientInfo = CLIENT_INFO,
  }, REQUEST_TIMEOUT)

  if not ok then
    self:emit("connection_error", result)
    self:shutdown(true)
    return false, result
  end
  if type(result) ~= "table" then
    self:emit("connection_error", "invalid initialize response")
    self:shutdown(true)
    return false, "invalid initialize response"
  end
  if result.protocolVersion ~= PROTOCOL_VERSION then
    local msg = string.format("unsupported ACP protocol version: %s", tostring(result.protocolVersion))
    self:emit("connection_error", msg)
    self:shutdown(true)
    return false, msg
  end

  self.capabilities = result.agentCapabilities or {}
  self.auth_methods = result.authMethods or {}
  self.agent_info = result.agentInfo or {}
  self.initialized = true
  Log.info("initialized with %s", self.agent_info.name or "agent")
  self:emit("ready", {
    capabilities = self.capabilities,
    auth_methods = self.auth_methods,
    agent_info = self.agent_info,
  })
  return true, nil
end

---Send a request and block the current coroutine until it resolves.
---@param method string
---@param params any
---@param timeout integer|nil
---@return boolean ok, any value
function Client:request(method, params, timeout)
  local settled = false
  local id
  local co = coroutine.running()
  id = self.rpc:request(method, params, function(ok, value)
    if settled then
      return
    end
    settled = true
    if co then
      async.resume(co, ok, value)
    end
  end)
  if not id then
    return false, { message = "connection closed" }
  end
  if timeout then
    vim.defer_fn(function()
      if settled then
        return
      end
      settled = true
      Log.warn("request %s timed out after %dms", method, timeout)
      self.rpc:cancel(id)
      if co then
        async.resume(co, false, { code = -32000, message = "request timed out: " .. method })
      end
    end, timeout)
  end
  return coroutine.yield()
end

function Client:on_line(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then
    Log.error("invalid JSON from agent: %s", vim.trim(line:sub(1, 500)))
    return
  end
  if Log.protocol_enabled() then
    Log.debug("<- %s", Log.redact(line, 2000))
  end
  if not self.rpc then
    return
  end
  self.rpc:handle(decoded)
end

function Client:install_handlers()
  self.rpc:on_notification("session/update", function(params)
    self:emit("session_update", params)
  end)
  self.rpc:on_notification("elicitation/complete", function(params)
    self:emit("elicitation_complete", params)
  end)
  self.rpc:on_request("session/request_permission", function(params, respond, respond_error)
    self:handle_permission(params, respond, respond_error)
  end)
  self.rpc:on_request("fs/read_text_file", function(_, _, respond_error)
    respond_error(-32601, "fs/read_text_file is not supported by this client")
  end)
  self.rpc:on_request("fs/write_text_file", function(_, _, respond_error)
    respond_error(-32601, "fs/write_text_file is not supported by this client")
  end)
end

function Client:handle_permission(params, respond, respond_error)
  if type(params) ~= "table" then
    respond_error(-32602, "invalid permission request")
    return
  end
  local session_id = params.sessionId
  local tool_call = params.toolCall or {}
  local options = params.options or {}
  self.permission_seq = self.permission_seq + 1
  local key = "perm:" .. self.permission_seq

  self.permissions[key] = {
    respond = respond,
    session_id = session_id,
  }

  self:emit("permission_request", {
    key = key,
    session_id = session_id,
    tool_call = tool_call,
    options = options,
  })
end

---Answer a pending permission request.
---@param key string
---@param option_id string|nil nil means cancelled
function Client:resolve_permission(key, option_id)
  local entry = self.permissions[key]
  if not entry then
    return
  end
  self.permissions[key] = nil
  if option_id then
    entry.respond({ outcome = { outcome = "selected", optionId = option_id } })
  else
    entry.respond({ outcome = { outcome = "cancelled" } })
  end
  self:emit("permission_resolved", { key = key, option_id = option_id })
end

---Cancel all pending permission requests (used on session cancel).
---@param session_id string
function Client:cancel_permissions(session_id)
  local keys = vim.tbl_keys(self.permissions)
  for _, key in ipairs(keys) do
    local entry = self.permissions[key]
    if not session_id or entry.session_id == session_id then
      self:resolve_permission(key, nil)
    end
  end
end

---Create a new session.
---@param cwd string
---@return boolean ok, any value
function Client:new_session(cwd)
  return self:request("session/new", {
    cwd = cwd,
    mcpServers = {},
  }, REQUEST_TIMEOUT)
end

---Load an existing session (replays history through session/update).
---@param session_id string
---@param cwd string
---@return boolean ok, any value
function Client:load_session(session_id, cwd)
  return self:request("session/load", {
    sessionId = session_id,
    cwd = cwd,
    mcpServers = {},
  }, REQUEST_TIMEOUT)
end

---List sessions known to the agent.
---@param cwd string|nil
---@param cursor string|nil opaque pagination cursor
---@return boolean ok, any value
function Client:list_sessions(cwd, cursor)
  local params = {}
  if cwd then
    params.cwd = cwd
  end
  if cursor then
    params.cursor = cursor
  end
  return self:request("session/list", params, REQUEST_TIMEOUT)
end

---Delete a session from the agent's history.
---Only call this after checking `sessionCapabilities.delete`.
---@param session_id string
---@return boolean ok, any value
function Client:delete_session(session_id)
  local ok, result = self:request("session/delete", { sessionId = session_id }, REQUEST_TIMEOUT)
  if not ok and type(result) == "table" and result.code == -32002 then
    -- The spec says an unknown session counts as a successful delete.
    return true, {}
  end
  return ok, result
end

---Whether the agent supports a session capability such as "delete" or "list".
---@param name string
---@return boolean
function Client:has_session_capability(name)
  local caps = self:agent_capabilities().sessionCapabilities
  if type(caps) ~= "table" then
    return false
  end
  return caps[name] ~= nil
end

---@param session_id string
---@param blocks table[]
---@return boolean ok, any value
function Client:prompt(session_id, blocks)
  self:emit("prompt_started", { session_id = session_id })
  local ok, result = self:request("session/prompt", {
    sessionId = session_id,
    prompt = blocks,
  })
  self:emit("prompt_finished", { session_id = session_id, ok = ok, result = result })
  return ok, result
end

---@param session_id string
function Client:cancel(session_id)
  if not self.rpc then
    return
  end
  self:cancel_permissions(session_id)
  self.rpc:notify("session/cancel", { sessionId = session_id })
  self:emit("cancel_requested", { session_id = session_id })
end

---@param session_id string
---@param config_id string
---@param value string|boolean
---@return boolean ok, any value
function Client:set_config_option(session_id, config_id, value)
  local params = { sessionId = session_id, configId = config_id, value = value }
  if type(value) == "boolean" then
    params.type = "boolean"
  end
  return self:request("session/set_config_option", params, REQUEST_TIMEOUT)
end

---@param session_id string
---@param mode_id string
---@return boolean ok, any value
function Client:set_mode(session_id, mode_id)
  return self:request("session/set_mode", { sessionId = session_id, modeId = mode_id }, REQUEST_TIMEOUT)
end

---@param session_id string
---@return boolean ok, any value
function Client:authenticate(method_id)
  return self:request("authenticate", { methodId = method_id }, REQUEST_TIMEOUT)
end

function Client:handle_exit(code, stderr, generation)
  if generation ~= self.generation then
    return
  end
  self.initialized = false
  if self.rpc then
    self.rpc:close("agent process exited")
  end
  self.permissions = {}
  self:emit("exit", { code = code, stderr = stderr })
end

---Terminate the connection.
---@param force boolean|nil
function Client:shutdown(force)
  if self.rpc then
    self.rpc:close("client shutdown")
  end
  self.initialized = false
  if self.proc then
    self.proc:stop(force)
    self.proc = nil
  end
  self.rpc = nil
end

---@return boolean
function Client:is_ready()
  return self.initialized and self.proc ~= nil and self.proc:is_alive()
end

---@return table
function Client:agent_capabilities()
  return self.capabilities or {}
end

return M
