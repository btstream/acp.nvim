-- The single owner of agent requests that wait for a user answer.
--
-- Protocol layers only hand over the response callback; policies may answer
-- immediately, otherwise exactly one presenter is shown and the rest queue.
-- Every request settles once: answer, cancel, or expiry by `$/cancel_request`.
local M, Interactions = {}, {}
Interactions.__index = Interactions

---@class AcpInteraction
---@field id string
---@field type "permission"|"elicitation"
---@field session_id string|nil
---@field tool_call_id string|nil
---@field request table
---@field state "pending"|"answered"|"cancelled"|"expired"
---@field created integer
---@field rpc_id any

---@param opts {policies: fun(interaction: AcpInteraction): table|nil,
---  present: fun(interaction: AcpInteraction): boolean|nil,
---  dismiss: fun(interaction: AcpInteraction)|nil,
---  on_changed: fun()|nil, notify: fun(message: string, level: integer|nil)|nil}
function M.new(opts)
  return setmetatable({
    policies = opts.policies or {},
    present = opts.present or function() end,
    dismiss = opts.dismiss or function() end,
    on_changed = opts.on_changed or function() end,
    notify = opts.notify or function() end,
    items = {},
    order = {},
    sequence = 0,
    shown = nil,
  }, Interactions)
end

local function cancel_response(kind)
  if kind == "elicitation" then
    return { action = "cancel" }
  end
  return { outcome = { outcome = "cancelled" } }
end

---@param id string
---@return AcpInteraction|nil
function Interactions:get(id)
  return self.items[id]
end

---Register a request. Policies run synchronously; a non-nil response answers
---it without showing the presenter.
---@param kind "permission"|"elicitation"
---@param request table
---@param respond fun(response: table)
---@param rpc_id any
---@param id string|nil reuse an external key (legacy clients)
function Interactions:open(kind, request, respond, rpc_id, id)
  self.sequence = self.sequence + 1
  id = id or (kind == "permission" and "perm:" or "elicit:") .. self.sequence
  local interaction = {
    id = id,
    type = kind,
    session_id = request.sessionId or request.session_id,
    tool_call_id = request.toolCallId or (request.toolCall and request.toolCall.toolCallId),
    request = request,
    state = "pending",
    created = self.sequence,
    rpc_id = rpc_id,
    respond = respond,
  }
  self.items[id] = interaction
  self.order[#self.order + 1] = interaction

  for _, policy in ipairs(self.policies) do
    local response = policy(interaction)
    if response then
      self:answer(id, response)
      return interaction
    end
  end

  self.on_changed()
  self:show_next()
  return interaction
end

---Show the oldest request that is still pending and not already on screen.
function Interactions:show_next()
  if self.shown and self.items[self.shown] and self.items[self.shown].state == "pending" then
    return
  end
  self.shown = nil
  local next_item
  for _, interaction in ipairs(self.order) do
    if interaction.state == "pending" then
      next_item = interaction
      break
    end
  end
  if not next_item then
    return
  end
  self.shown = next_item.id
  local presented = self.present(next_item)
  if presented == false and self.shown == next_item.id then
    self.shown = nil
  end
end

---Present one specific pending request unless it is already on screen.
---@param id string
function Interactions:show(id)
  local interaction = self.items[id]
  if not interaction or interaction.state ~= "pending" or self.shown == id then
    return
  end
  self.shown = id
  if self.present(interaction) == false and self.shown == id then
    self.shown = nil
  end
end

---@param interaction AcpInteraction
function Interactions:_settle(interaction)
  if self.shown == interaction.id then
    self.shown = nil
    pcall(self.dismiss, interaction)
  end
  local respond = interaction.respond
  interaction.respond = nil
  if respond then
    pcall(respond, interaction.response)
  end
  self.on_changed()
  -- Defer opening the next picker until the previous one has closed.
  vim.schedule(function()
    self:show_next()
  end)
end

---Answer a pending request once.
---@param id string
---@param response table
---@return boolean
function Interactions:answer(id, response)
  local interaction = self.items[id]
  if not interaction or interaction.state ~= "pending" then
    return false
  end
  interaction.state = "answered"
  interaction.response = response
  self:_settle(interaction)
  return true
end

---Mark a request answered by an external path that already replied.
---@param id string
function Interactions:resolved(id)
  local interaction = self.items[id]
  if not interaction or interaction.state ~= "pending" then
    return false
  end
  interaction.state = "answered"
  interaction.respond = nil
  self:_settle(interaction)
  return true
end

---Cancel a pending request with its protocol-specific cancellation response.
---@param id string
---@param reason string|nil
---@return boolean
function Interactions:cancel(id, reason)
  local interaction = self.items[id]
  if not interaction or interaction.state ~= "pending" then
    return false
  end
  interaction.state = "cancelled"
  interaction.reason = reason
  interaction.response = cancel_response(interaction.type)
  self:_settle(interaction)
  return true
end

---The agent withdrew the request with `$/cancel_request`; the RPC layer has
---already replied, so expire without sending another response.
---@param rpc_id any
---@return boolean
function Interactions:on_remote_cancel(rpc_id)
  for _, interaction in ipairs(self.order) do
    if interaction.state == "pending" and interaction.rpc_id == rpc_id then
      interaction.state = "expired"
      if self.shown == interaction.id then
        self.shown = nil
        pcall(self.dismiss, interaction)
      end
      interaction.respond = nil
      self.on_changed()
      vim.schedule(function()
        self:show_next()
      end)
      return true
    end
  end
  return false
end

---@param session_id string|nil
---@return AcpInteraction[]
function Interactions:pending(session_id)
  local out = {}
  for _, interaction in ipairs(self.order) do
    if interaction.state == "pending" and (not session_id or interaction.session_id == session_id) then
      out[#out + 1] = interaction
    end
  end
  return out
end

---@param session_id string|nil
---@return boolean
function Interactions:waiting(session_id)
  if not session_id then
    return false
  end
  return #self:pending(session_id) > 0
end

---@param session_id string
function Interactions:cancel_session(session_id)
  for _, interaction in ipairs(self:pending(session_id)) do
    self:cancel(interaction.id, "session cancelled")
  end
end

---@param reason string|nil
function Interactions:cancel_all(reason)
  for _, interaction in ipairs(self:pending()) do
    self:cancel(interaction.id, reason)
  end
end

return M
