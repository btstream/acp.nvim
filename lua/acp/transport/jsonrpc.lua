-- JSON-RPC 2.0 layer used on top of the ACP transport.
local Log = require("acp.log")

local M = {}

---@class AcpRpc
---@field next_id integer
---@field pending table<integer, {method: string, cb: fun(ok: boolean, value: any), cancelled?: boolean}>
---@field incoming table<integer, string>
---@field request_handlers table<string, fun(params: any, respond: fun(result: any), respond_error: fun(code: integer, message: string, data?: any))>
---@field notification_handlers table<string, fun(params: any)>
---@field send fun(payload: string): boolean
local Rpc = {}
Rpc.__index = Rpc

---@param opts {send: fun(payload: string): boolean}
---@return AcpRpc
function M.new(opts)
  return setmetatable({
    next_id = 0,
    pending = {},
    incoming = {},
    -- ids cancelled by us; late responses are ignored instead of being logged
    -- as unknown (and the set is bounded by a ring buffer).
    cancelled = {},
    cancelled_order = {},
    request_handlers = {},
    notification_handlers = {},
    send = opts.send,
    closed = false,
  }, Rpc)
end

local function encode(obj)
  local ok, encoded = pcall(vim.json.encode, obj)
  if not ok then
    Log.error("failed to encode JSON-RPC payload: %s", encoded)
    return nil
  end
  return encoded .. "\n"
end

---@param obj table
---@return boolean
function Rpc:write(obj)
  if self.closed then
    return false
  end
  local payload = encode(obj)
  if not payload then
    return false
  end
  if Log.protocol_enabled() then
    Log.debug("--> %s", payload)
  end
  return self.send(payload) ~= false
end

---Send a request. `cb` receives (ok, result_or_error).
---@param method string
---@param params any
---@param cb fun(ok: boolean, value: any)|nil
---@return integer|nil id
function Rpc:request(method, params, cb)
  if self.closed then
    if cb then
      cb(false, { code = -32000, message = "connection closed" })
    end
    return nil
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  if cb then
    self.pending[id] = { method = method, cb = cb }
  end
  local ok, sent = pcall(self.write, self, { jsonrpc = "2.0", id = id, method = method, params = params })
  if not ok or not sent then
    local entry = self.pending[id]
    self.pending[id] = nil
    if entry and entry.cb then
      entry.cb(false, { code = -32000, message = "failed to send request: " .. method })
    end
    return nil
  end
  return id
end

---Send a notification (no response expected).
---@param method string
---@param params any
function Rpc:notify(method, params)
  self:write({ jsonrpc = "2.0", method = method, params = params })
end

---Cancel an outgoing request using the JSON-RPC cancellation extension.
---@param id integer
function Rpc:cancel(id)
  local entry = self.pending[id]
  if not entry then
    return
  end
  -- Drop the entry immediately. Waiting for a response that may never arrive
  -- leaked one table per cancelled request (`pending` grew monotonically).
  self.pending[id] = nil
  self.cancelled[id] = true
  self.cancelled_order[#self.cancelled_order + 1] = id
  -- Bound the memory used to recognise late responses.
  while #self.cancelled_order > 256 do
    local oldest = table.remove(self.cancelled_order, 1)
    self.cancelled[oldest] = nil
  end
  self:write({ jsonrpc = "2.0", method = "$/cancel_request", params = { id = id } })
end

---@param id any
---@param result any
function Rpc:respond(id, result)
  self:write({ jsonrpc = "2.0", id = id, result = result })
end

---@param id any
---@param code integer
---@param message string
---@param data any
function Rpc:respond_error(id, code, message, data)
  self:write({
    jsonrpc = "2.0",
    id = id,
    error = { code = code, message = message, data = data },
  })
end

---Register a handler for agent to client requests.
---@param method string
---@param fn fun(params: any, respond: fun(result: any), respond_error: fun(code: integer, message: string, data?: any))
function Rpc:on_request(method, fn)
  self.request_handlers[method] = fn
end

---Register a handler for notifications.
---@param method string
---@param fn fun(params: any)
function Rpc:on_notification(method, fn)
  self.notification_handlers[method] = fn
end

local function dispatch_request(self, msg)
  local handler = self.request_handlers[msg.method]
  if not handler then
    Log.debug("unhandled agent request: %s", msg.method)
    self:respond_error(msg.id, -32601, "Method not found: " .. msg.method)
    return
  end
  self.incoming[msg.id] = msg.method
  local function reply(result)
    self.incoming[msg.id] = nil
    self:respond(msg.id, result)
  end
  local function reply_error(code, message, data)
    self.incoming[msg.id] = nil
    self:respond_error(msg.id, code, message, data)
  end
  local ok, err = pcall(handler, msg.params or vim.empty_dict(), reply, reply_error)
  if not ok then
    Log.error("request handler for %s failed: %s", msg.method, err)
    reply_error(-32603, "Internal error")
  end
end

---Route one decoded JSON value.
---@param msg any
---@param raw string|nil original payload, already logged by the client
function Rpc:handle(msg, raw)
  if type(msg) ~= "table" then
    Log.warn("ignoring non-object JSON-RPC message")
    return
  end
  -- The client already logs the raw line; re-encoding the decoded message just
  -- to log it again doubled the JSON cost for every large payload.
  if raw == nil and Log.protocol_enabled() then
    Log.debug("<-- %s", Log.redact(vim.json.encode(msg), 2000))
  end

  -- Notification
  if msg.method and msg.id == nil then
    if msg.method == "$/cancel_request" then
      local target = type(msg.params) == "table" and msg.params.id
      if target and self.incoming[target] then
        -- Agent cancelled one of its own pending requests.
        self.incoming[target] = nil
        self:respond_error(target, -32800, "Request cancelled")
      end
      return
    end
    local handler = self.notification_handlers[msg.method]
    if handler then
      local ok, err = pcall(handler, msg.params or vim.empty_dict())
      if not ok then
        Log.error("notification handler for %s failed: %s", msg.method, err)
      end
    else
      Log.debug("ignoring unknown notification: %s", msg.method)
    end
    return
  end

  -- Request from the agent
  if msg.method and msg.id ~= nil then
    dispatch_request(self, msg)
    return
  end

  -- Response
  if msg.id ~= nil then
    if self.cancelled[msg.id] then
      -- We asked to cancel this request; its response carries no useful value.
      return
    end
    local entry = self.pending[msg.id]
    if not entry then
      Log.debug("response for unknown request id %s", tostring(msg.id))
      return
    end
    self.pending[msg.id] = nil
    if entry.cancelled then
      Log.debug("ignoring response for cancelled request %s", entry.method)
      return
    end
    if msg.error then
      entry.cb(false, msg.error)
    else
      entry.cb(true, msg.result)
    end
    return
  end

  Log.warn("ignoring malformed JSON-RPC message")
end

---Reject every pending request. Used on disconnect.
---@param reason string
function Rpc:close(reason)
  if self.closed then
    return
  end
  self.closed = true
  local pending = self.pending
  self.pending = {}
  self.incoming = {}
  self.cancelled = {}
  self.cancelled_order = {}
  for _, entry in pairs(pending) do
    -- A failing callback used to abort the loop, leaving the remaining
    -- requests unresolved forever.
    pcall(entry.cb, false, { code = -32000, message = reason or "connection closed" })
  end
end

---Number of requests still awaiting a response.
---@return integer
function Rpc:pending_count()
  local n = 0
  for _ in pairs(self.pending) do
    n = n + 1
  end
  return n
end

return M
