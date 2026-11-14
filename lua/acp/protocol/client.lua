-- ACP client: process lifecycle, initialization, sessions and prompts.
local Log = require("acp.log")
local rpcmod = require("acp.transport.jsonrpc")
local process = require("acp.transport.process")
local async = require("acp.async")
local capabilities = require("acp.protocol.capabilities")

local M = {}

local PROTOCOL_VERSION = 1
local CLIENT_INFO = { name = "acp.nvim", title = "acp.nvim", version = "0.1.0" }

local REQUEST_TIMEOUT = 30000
-- How long a cancelled turn may keep asking before its requests count as new.
local DRAIN_MS = 5000

---Resolve the effective request timeout from the client's transport limits.
---Per-method overrides come first, then the generic request timeout.
---@param self AcpClient
---@param method string
---@param fallback integer
---@return integer|nil
local function request_timeout(self, method, fallback)
  local limits = self.limits or {}
  local by_method = limits.timeouts
  local value = type(by_method) == "table" and by_method[method] or nil
  if type(value) ~= "number" then
    value = limits.request_timeout
  end
  if value == 0 then
    return nil
  end
  if type(value) == "number" and value > 0 then
    return math.floor(value)
  end
  return fallback
end

---@class AcpClient
---@field rpc AcpRpc
---@field proc AcpProcess|nil
---@field capabilities table
---@field auth_methods table[]
---@field scheduler table|nil
---@field interactions table|nil
---@field on_event fun(name: string, payload: any)
---@field permissions table<string, {respond: fun(result:any), session_id: string}>
---@field generation integer
local Client = {}
Client.__index = Client

---@param opts {agent: table, cwd: string, client_capabilities: table, limits?: table, scheduler?: table, interactions?: table, mcp_servers?: table[], launch?: table, on_event: fun(name: string, payload: any)}
---@return AcpClient
function M.new(opts)
  local self = setmetatable({
    agent = opts.agent,
    -- The exact spec this client was started with. The terminal login reads it
    -- so it runs the same release as the conversation, even if a newer one was
    -- installed in between.
    launch = opts.launch,
    cwd = opts.cwd,
    limits = opts.limits,
    declared_mcp_servers = opts.mcp_servers,
    scheduler = opts.scheduler,
    interactions = opts.interactions,
    client_capabilities = opts.client_capabilities,
    on_event = opts.on_event or function() end,
    permissions = {},
    permission_seq = 0,
    elicitations = {},
    elicitation_seq = 0,
    active_requests = {},
    -- session id -> rpc id of a prompt cancelled locally whose agent-side
    -- turn has not ended yet. See `Client:cancel`.
    draining = {},
    settles = {},
    timeout_extensions = {},
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
  if self.initialized then
    if cb then
      cb(true, nil)
    end
    return
  end
  self.start_waiters = self.start_waiters or {}
  if cb then
    self.start_waiters[#self.start_waiters + 1] = cb
  end
  if self.starting then
    return
  end
  self.starting = true
  local generation = self.generation + 1
  self.generation = generation

  self.start_co = async.run(function()
    self.start_co = coroutine.running()
    local ok, err = self:do_start(generation)
    self:finish_start(ok, err)
  end, function(err)
    -- `do_start` raised before the line above ran; reset the guard so a later
    -- `start` is not silently swallowed.
    self:shutdown(true, err)
  end)
end

function Client:finish_start(ok, err)
  self.starting = false
  local waiters = self.start_waiters or {}
  self.start_waiters = {}
  for _, cb in ipairs(waiters) do
    pcall(cb, ok, err)
  end
end

function Client:do_start(generation)
  local cfg = self.agent
  local limits = self.limits or {}
  local max_line = limits.max_line_bytes or 32 * 1024 * 1024
  local stderr_keep = limits.stderr_keep_bytes or 64 * 1024

  local proc, err = process.spawn({
    command = cfg.command,
    args = cfg.args,
    cwd = self.cwd,
    env = cfg.env,
    max_line_bytes = max_line,
    stderr_keep_bytes = stderr_keep,
    shutdown_timeout = limits.shutdown_timeout,
    max_pending_bytes = limits.max_pending_bytes,
    spill_bytes = limits.spill_bytes,
    dispatch_budget_ms = limits.dispatch_budget_ms,
    scheduler = self.scheduler,
    on_line = function(line)
      return self:on_line(line)
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
  }, request_timeout(self, "initialize", REQUEST_TIMEOUT))

  if not ok then
    self:emit("connection_error", result)
    self:shutdown(true, result)
    return false, result
  end
  if type(result) ~= "table" then
    self:emit("connection_error", "invalid initialize response")
    self:shutdown(true, "invalid initialize response")
    return false, "invalid initialize response"
  end
  if result.protocolVersion ~= PROTOCOL_VERSION then
    local msg = string.format("unsupported ACP protocol version: %s", tostring(result.protocolVersion))
    self:emit("connection_error", msg)
    self:shutdown(true, msg)
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
---@param extendable boolean|nil reset the timer via `touch_timeout(method)`
---@return boolean ok, any value
function Client:request(method, params, timeout, extendable)
  local settled = false
  local yielded, immediate = false, nil
  local id
  local co = coroutine.running()
  if not co then
    return false, { message = "request() must run inside a coroutine" }
  end
  local timer
  local rpc = self.rpc
  if not rpc then
    return false, { message = "connection closed" }
  end
  async.finally(function()
    if settled then
      return
    end
    settled = true
    self.timeout_extensions[method] = nil
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if id then
      if self.active_requests[method] == id then
        self.active_requests[method] = nil
      end
      rpc:cancel(id)
    end
  end)
  local function settle(ok, value)
    if settled then
      return
    end
    settled = true
    self.timeout_extensions[method] = nil
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if id and self.active_requests[method] == id then
      self.active_requests[method] = nil
    end
    if id then
      self.settles[id] = nil
    end
    if yielded then
      async.resume(co, ok, value)
    else
      immediate = { ok = ok, value = value }
    end
  end
  id = rpc:request(method, params, settle)
  if not id then
    settle(false, { message = "connection closed" })
  end
  if id then
    self.active_requests[method] = id
    self.settles[id] = settle
  end
  if timeout and timeout > 0 and not settled then
    local function arm()
      timer = vim.uv.new_timer()
      timer:start(timeout, 0, function()
        vim.schedule(function()
          if settled then
            return
          end
          Log.warn("request %s timed out after %dms", method, timeout)
          rpc:cancel(id)
          settle(false, { code = rpcmod.LOCAL_ERROR, message = "request timed out: " .. method })
        end)
      end)
    end
    arm()
    if extendable then
      self.timeout_extensions[method] = function()
        if settled or not timer then
          return
        end
        timer:stop()
        arm()
      end
    end
  end
  if immediate then
    return immediate.ok, immediate.value
  end
  yielded = true
  return coroutine.yield()
end

---Restart the timeout of an extendable request (used during session replay).
---@param method string
function Client:touch_timeout(method)
  local extend = self.timeout_extensions[method]
  if extend then
    extend()
  end
end

function Client:on_line(line)
  -- Decode JSON null as Lua nil. Otherwise vim.NIL leaks into reducers and
  -- string/number operations fail halfway through an update.
  local ok, decoded = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
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
  local dispatch = self:chunk_update(decoded)
  if dispatch then
    return dispatch
  end
  self.rpc:handle(decoded, line)
end

local TEXT_CHUNK = 64 * 1024
local CHUNK_KINDS = {
  agent_message_chunk = true,
  agent_thought_chunk = true,
  user_message_chunk = true,
}

---Move `stop` forward off a UTF-8 continuation byte.
---@param text string
---@param stop integer
---@return integer
local function utf8_boundary(text, stop)
  while stop < #text do
    local byte = text:byte(stop + 1)
    if byte and byte >= 0x80 and byte < 0xC0 then
      stop = stop + 1
    else
      break
    end
  end
  return stop
end

---Extract the text-bearing part of a streamed update, if it is chunkable.
---Tool content is a replacement, not an append. Keep it atomic: cumulative
---prefixes would copy O(n²) bytes and expose a completed tool with partial data.
---@param update table
---@return table|nil content prototype, string|nil text
local function chunkable(update)
  local kind = update.sessionUpdate
  if CHUNK_KINDS[kind] then
    local content = update.content
    if type(content) == "table" and content.type == "text" and type(content.text) == "string" then
      return content, content.text
    end
    return nil
  end
  return nil
end

---Return a lazy dispatcher for an oversized append-only text notification.
---Decoded slices go straight to RPC, never back through chunk detection. This
---also makes UTF-8 slices slightly above `size` safe and avoids JSON re-encoding.
---@param decoded table
---@return function|nil dispatch returns true while more slices remain
function Client:chunk_update(decoded)
  local size = (self.limits or {}).text_chunk_bytes or TEXT_CHUNK
  if size <= 0 then
    return nil
  end
  if type(decoded) ~= "table" or decoded.method ~= "session/update" or decoded.id ~= nil then
    return nil
  end
  local params = decoded.params
  local update = type(params) == "table" and params.update
  if type(update) ~= "table" then
    return nil
  end
  local content, text = chunkable(update)
  if not text or #text <= size then
    return nil
  end
  local rpc, offset = self.rpc, 1
  self.stats = self.stats or {}
  self.stats.chunked_messages = (self.stats.chunked_messages or 0) + 1
  return function()
    if self.rpc ~= rpc or not rpc or rpc.closed or offset > #text then
      return false
    end
    local stop = utf8_boundary(text, math.min(#text, offset + size - 1))
    local body = vim.tbl_extend("force", {}, content, { text = text:sub(offset, stop) })
    local payload_update = vim.tbl_extend("force", {}, update, { content = body })
    local payload_params = vim.tbl_extend("force", {}, params, { update = payload_update })
    offset = stop + 1
    self.stats.chunk_parts = (self.stats.chunk_parts or 0) + 1
    rpc:handle({ jsonrpc = decoded.jsonrpc or "2.0", method = "session/update", params = payload_params })
    return offset <= #text
  end
end

---Register a handler for a request from the agent. Unregistered methods keep
---the default -32601 response from the RPC layer.
---@param method string
---@param handler fun(params: any, respond: fun(result: any), respond_error: fun(code: integer, message: string, data?: any))
function Client:on_agent_request(method, handler)
  self.rpc:on_request(method, handler)
end

---Register a handler for a notification from the agent.
---@param method string
---@param handler fun(params: any)
function Client:on_agent_notification(method, handler)
  self.rpc:on_notification(method, handler)
end

---Whether the client advertised a capability subtree at initialize time.
---@param path string dotted path, e.g. "elicitation"
---@return boolean
function Client:declares(path)
  return capabilities.supports(self.client_capabilities, path)
end

function Client:install_handlers()
  if self.rpc then
    self.rpc.on_cancel_request = function(rpc_id)
      if self.interactions then
        self.interactions:on_remote_cancel(rpc_id)
      end
    end
    -- The response to a prompt we withdrew: the agent has now ended that turn.
    self.rpc.on_late_response = function(rpc_id)
      for session_id, prompt_id in pairs(self.draining) do
        if prompt_id == rpc_id then
          self.draining[session_id] = nil
        end
      end
    end
  end
  self:on_agent_notification("session/update", function(params)
    self:emit("session_update", params)
  end)
  self:on_agent_notification("elicitation/complete", function(params)
    if self.interactions then
      self.interactions:complete(params)
    end
    self:emit("elicitation_complete", params)
  end)
  self:on_agent_request("elicitation/create", function(params, respond, respond_error, rpc_id)
    if not self:declares("elicitation") then
      respond_error(-32601, "elicitation is not supported by this client")
      return
    end
    if self.interactions then
      self.interactions:open("elicitation", params or {}, respond, rpc_id)
      return
    end
    self.elicitation_seq = self.elicitation_seq + 1
    local key = "elicit:" .. self.elicitation_seq
    self.elicitations[key] = { respond = respond, session_id = params and params.sessionId }
    self:emit("elicitation_request", { key = key, request = params or {} })
  end)
  self:on_agent_request("session/request_permission", function(params, respond, respond_error, rpc_id)
    self:handle_permission(params, respond, respond_error, rpc_id)
  end)
  self:on_agent_request("fs/read_text_file", function(_, _, respond_error)
    respond_error(-32601, "fs/read_text_file is not supported by this client")
  end)
  self:on_agent_request("fs/write_text_file", function(_, _, respond_error)
    respond_error(-32601, "fs/write_text_file is not supported by this client")
  end)
end

function Client:handle_permission(params, respond, respond_error, rpc_id)
  if type(params) ~= "table" then
    respond_error(-32602, "invalid permission request")
    return
  end
  local session_id = params.sessionId
  local tool_call = params.toolCall or {}
  local options = params.options or {}
  -- A request from a turn the user cancelled. The client settles a cancelled
  -- prompt locally, so the next turn may already be running; without this the
  -- old turn's request would be shown to the user, or answered by the policy
  -- of a turn that never asked (ACP: answer it with `cancelled`).
  if session_id ~= nil and self.draining[session_id] ~= nil then
    Log.debug("cancelling a permission request from a cancelled turn")
    respond({ outcome = { outcome = "cancelled" } })
    return
  end
  self.permission_seq = self.permission_seq + 1
  local key = "perm:" .. self.permission_seq

  if self.interactions then
    self.interactions:open("permission", params, respond, rpc_id, key)
    return
  end

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
  if self.interactions then
    -- nil is the documented "cancelled" form. Emitting `selected` without an
    -- optionId is an invalid permission outcome.
    local response = option_id and { outcome = { outcome = "selected", optionId = option_id } }
      or { outcome = { outcome = "cancelled" } }
    if self.interactions:answer(key, response) then
      self:emit("permission_resolved", { key = key, option_id = option_id })
    end
    return
  end
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

---Answer a pending elicitation (legacy path without an interaction broker).
---@param key string
---@param response table
function Client:resolve_elicitation(key, response)
  if self.interactions then
    self.interactions:answer(key, response)
    return
  end
  local entry = self.elicitations[key]
  if not entry then
    return
  end
  self.elicitations[key] = nil
  entry.respond(response)
end

---Cancel all pending permission requests (used on session cancel).
---@param session_id string
function Client:cancel_permissions(session_id)
  if self.interactions then
    self.interactions:cancel_session(session_id)
    return
  end
  local keys = vim.tbl_keys(self.permissions)
  for _, key in ipairs(keys) do
    local entry = self.permissions[key]
    if not session_id or entry.session_id == session_id then
      self:resolve_permission(key, nil)
    end
  end
  for key, entry in pairs(self.elicitations) do
    if not session_id or entry.session_id == session_id then
      self.elicitations[key] = nil
      entry.respond({ action = "cancel" })
    end
  end
end

---MCP servers this agent can actually accept.
---
---ACP gates the transports on `mcpCapabilities`: stdio is baseline, while HTTP
---and SSE have to be advertised. Sending an unsupported transport would fail
---session creation for a configuration the agent never promised to handle.
---@return table[]
function Client:mcp_servers()
  local declared = self.declared_mcp_servers or {}
  if type(declared) ~= "table" or #declared == 0 then
    return {}
  end
  local caps = self:agent_capabilities().mcpCapabilities
  caps = type(caps) == "table" and caps or {}
  local out = {}
  for _, server in ipairs(declared) do
    local kind = server.type or "stdio"
    if kind == "stdio" or (kind == "http" and caps.http == true) or (kind == "sse" and caps.sse == true) then
      out[#out + 1] = server
    end
  end
  return out
end

---Create a new session.
---@param cwd string
---@return boolean ok, any value
function Client:new_session(cwd)
  return self:request("session/new", {
    cwd = cwd,
    mcpServers = self:mcp_servers(),
  }, request_timeout(self, "session_new", REQUEST_TIMEOUT))
end

---Load an existing session (replays history through session/update).
---@param session_id string
---@param cwd string
---@return boolean ok, any value
function Client:load_session(session_id, cwd)
  return self:request("session/load", {
    sessionId = session_id,
    cwd = cwd,
    mcpServers = self:mcp_servers(),
  }, request_timeout(self, "session_load", REQUEST_TIMEOUT), true)
end

---Resume an existing session without replaying its history.
---Only call this after checking `sessionCapabilities.resume`.
---@param session_id string
---@param cwd string
---@return boolean ok, any value
function Client:resume_session(session_id, cwd)
  return self:request("session/resume", {
    sessionId = session_id,
    cwd = cwd,
    mcpServers = self:mcp_servers(),
  }, request_timeout(self, "session_load", REQUEST_TIMEOUT))
end

---Close an active session on the agent side.
---Only call this after checking `sessionCapabilities.close`.
---@param session_id string
---@return boolean ok, any value
function Client:close_session(session_id)
  local ok, result =
    self:request("session/close", { sessionId = session_id }, request_timeout(self, "", REQUEST_TIMEOUT))
  if not ok and type(result) == "table" and result.code == -32002 then
    -- The spec treats closing an unknown session as success.
    return true, {}
  end
  return ok, result
end

---List sessions known to the agent.
---@param cwd string|nil
---@param cursor string|nil opaque pagination cursor
---@return boolean ok, any value
function Client:list_sessions(cwd, cursor)
  -- vim.json encodes `{}` as `[]`, which agents reject as invalid params.
  -- vim.empty_dict() keeps it an object.
  local params = vim.empty_dict()
  if cwd then
    params.cwd = cwd
  end
  if cursor then
    params.cursor = cursor
  end
  return self:request("session/list", params, request_timeout(self, "", REQUEST_TIMEOUT))
end

---Delete a session from the agent's history.
---Only call this after checking `sessionCapabilities.delete`.
---@param session_id string
---@return boolean ok, any value
function Client:delete_session(session_id)
  local ok, result =
    self:request("session/delete", { sessionId = session_id }, request_timeout(self, "", REQUEST_TIMEOUT))
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
  return capabilities.supports(self:agent_capabilities().sessionCapabilities, name)
end

---Whether the agent accepts a given prompt content type.
---
---Text and resource_link are mandatory for every agent; the richer types are
---advertised through promptCapabilities and omitted ones must be treated as
---unsupported.
---@param name "image"|"audio"|"embeddedContext"
---@return boolean
function Client:supports_prompt(name)
  return capabilities.supports(self:agent_capabilities().promptCapabilities, name)
end

---@param session_id string
---@param blocks table[]
---@param turn integer|nil turn number, echoed back so stale events can be ignored
---@return boolean ok, any value
function Client:prompt(session_id, blocks, turn)
  self:emit("prompt_started", { session_id = session_id, turn = turn })
  -- A prompt can legitimately run for minutes, so it gets its own timeout
  -- rather than the generic request one. Without any timeout an agent that
  -- ignores `session/cancel` left the turn, the spinner and the queue stuck.
  local timeout = (self.limits or {}).prompt_timeout
  if type(timeout) ~= "number" then
    timeout = 600000
  end
  local ok, result = self:request("session/prompt", {
    sessionId = session_id,
    prompt = blocks,
  }, timeout > 0 and timeout or nil)
  self:emit("prompt_finished", { session_id = session_id, ok = ok, result = result, turn = turn })
  return ok, result
end

---@param session_id string
function Client:cancel(session_id)
  if not self.rpc then
    return
  end
  self:cancel_permissions(session_id)
  -- The turn must be told first, then the pending RPC is withdrawn. The order
  -- matters: the agent needs session/cancel to stop work, and $/cancel_request
  -- only releases the response waiter.
  self.rpc:notify("session/cancel", { sessionId = session_id })
  local prompt_id = self.active_requests["session/prompt"]
  if prompt_id then
    local settle = self.settles[prompt_id]
    self.rpc:cancel(prompt_id)
    self.active_requests["session/prompt"] = nil
    -- Until the agent answers the withdrawn prompt, its permission requests
    -- belong to the cancelled turn. Bounded, so an agent that never answers
    -- cannot silence permission requests for the rest of the session.
    self.draining[session_id] = prompt_id
    vim.defer_fn(function()
      if self.draining[session_id] == prompt_id then
        self.draining[session_id] = nil
      end
    end, DRAIN_MS)
    -- Withdrawing the RPC also removes its response waiter. Settle it locally
    -- with the same stop reason the agent would have reported.
    if settle then
      settle(true, { stopReason = "cancelled" })
    end
  end
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
  return self:request("session/set_config_option", params, request_timeout(self, "", REQUEST_TIMEOUT))
end

---@param session_id string
---@param mode_id string
---@return boolean ok, any value
function Client:set_mode(session_id, mode_id)
  return self:request(
    "session/set_mode",
    { sessionId = session_id, modeId = mode_id },
    request_timeout(self, "", REQUEST_TIMEOUT)
  )
end

---@param session_id string
---@return boolean ok, any value
function Client:authenticate(method_id)
  return self:request("authenticate", { methodId = method_id }, request_timeout(self, "", REQUEST_TIMEOUT))
end

---Log out. Only call when the agent declared `auth.logout`.
---@return boolean ok, any value
function Client:logout()
  return self:request("logout", vim.empty_dict(), request_timeout(self, "", REQUEST_TIMEOUT))
end

function Client:handle_exit(code, stderr, generation)
  if generation ~= self.generation then
    return
  end
  self.initialized = false
  self:finish_start(false, { message = "agent process exited" })
  -- Answer every pending interaction before dropping them: otherwise the
  -- agent side waits forever and the UI keeps showing a dead prompt.
  if self.interactions then
    self.interactions:cancel_all("agent exited")
  end
  for key in pairs(self.permissions or {}) do
    pcall(self.resolve_permission, self, key, nil)
  end
  self.permissions = {}
  if self.rpc then
    self.rpc:close("agent process exited")
  end
  self:emit("exit", { code = code, stderr = stderr })
end

---Terminate the connection.
---@param force boolean|nil
function Client:shutdown(force, reason)
  if self.start_co then
    async.cancel(self.start_co)
    self.start_co = nil
  end
  if self.interactions then
    self.interactions:cancel_all("client shutdown")
  end
  for key in pairs(self.permissions or {}) do
    pcall(self.resolve_permission, self, key, nil)
  end
  self.permissions = {}
  self.starting = false
  if self.rpc then
    self.rpc:close("client shutdown")
  end
  self.initialized = false
  if self.proc then
    self.proc:stop(force)
    self.proc = nil
  end
  self.rpc = nil
  self:finish_start(false, reason or { message = "client shutdown" })
end

---@return boolean
function Client:is_ready()
  return self.initialized and self.proc ~= nil and self.proc:is_alive()
end

---@return table
function Client:agent_capabilities()
  return self.capabilities or {}
end

---Mark a protocol phase on the transport for diagnostics.
---@param phase string|nil "replay" while replaying agent history
function Client:mark_phase(phase)
  if self.proc then
    self.proc:mark_phase(phase)
  end
end

---Compact transport diagnostics, for overflow reporting and `:AcpDebug`.
---@return table|nil
function Client:transport_stats()
  if not self.proc then
    return nil
  end
  local stats = self.proc.stats
  if self.stats then
    for key, value in pairs(self.stats) do
      stats[key] = value
    end
  end
  return stats
end

return M
