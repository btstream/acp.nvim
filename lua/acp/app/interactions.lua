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

-- Settled interactions stay queryable briefly (the controller and tests read
-- them right after answering), but the list is bounded: a long session must not
-- retain every tool-call payload it ever showed.
local RECENT_LIMIT = 32

---@param opts {policies: fun(interaction: AcpInteraction): table|nil,
---  presenters: table<string, {present: fun(interaction: AcpInteraction): boolean|nil, dismiss: fun(interaction: AcpInteraction)|nil}>,
---  on_open: fun(interaction: AcpInteraction)|nil,
---  on_settle: fun(interaction: AcpInteraction, response: table|nil)|nil,
---  on_changed: fun()|nil, notify: fun(message: string, level: integer|nil)|nil}
function M.new(opts)
  return setmetatable({
    policies = opts.policies or {},
    presenters = opts.presenters or {},
    on_open = opts.on_open or function() end,
    on_settle = opts.on_settle or function() end,
    on_changed = opts.on_changed or function() end,
    notify = opts.notify or function() end,
    items = {},
    order = {},
    recent = {},
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
  local interaction = self.items[id]
  if interaction then
    return interaction
  end
  for _, settled in ipairs(self.recent) do
    if settled.id == id then
      return settled
    end
  end
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
  -- Legacy callers pass the client's own key; make sure a retired entry with
  -- the same id cannot shadow this one in `get()`.
  for index = #self.recent, 1, -1 do
    if self.recent[index].id == id then
      table.remove(self.recent, index)
    end
  end

  for _, policy in ipairs(self.policies) do
    local response = policy(interaction)
    if response then
      self:answer(id, response)
      return interaction
    end
  end

  pcall(self.on_open, interaction)
  self.on_changed()
  self:show_next()
  return interaction
end

---@param interaction AcpInteraction
---@return boolean shown
function Interactions:_present(interaction)
  local presenter = self.presenters[interaction.type]
  if not presenter or not presenter.present then
    -- No surface for this kind: settle it now so it cannot block the queue.
    self.notify("unsupported agent request: " .. tostring(interaction.type), vim.log.levels.ERROR)
    if interaction.type == "elicitation" then
      self:answer(interaction.id, { action = "decline" })
    else
      self:cancel(interaction.id, "no presenter")
    end
    return false
  end
  local ok, shown = pcall(presenter.present, interaction)
  if not ok then
    -- A presenter that throws must not leave a permanently pending request.
    self.notify("unable to show the agent request: " .. tostring(shown), vim.log.levels.ERROR)
    if interaction.type == "elicitation" then
      self:answer(interaction.id, { action = "decline" })
    else
      self:cancel(interaction.id, "presenter failed")
    end
    return false
  end
  return shown ~= false
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
  if self:_present(next_item) == false and self.shown == next_item.id then
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
  if self:_present(interaction) == false and self.shown == id then
    self.shown = nil
  end
end

---Record a settled interaction, evicting the oldest beyond the cap.
---@param interaction AcpInteraction
function Interactions:_retire(interaction)
  self.items[interaction.id] = nil
  for index, candidate in ipairs(self.order) do
    if candidate == interaction then
      table.remove(self.order, index)
      break
    end
  end
  self.recent[#self.recent + 1] = interaction
  while #self.recent > RECENT_LIMIT do
    table.remove(self.recent, 1)
  end
end

---@param interaction AcpInteraction
function Interactions:_settle(interaction)
  if self.shown == interaction.id then
    self.shown = nil
    local presenter = self.presenters[interaction.type]
    if presenter and presenter.dismiss then
      pcall(presenter.dismiss, interaction)
    end
  end
  local respond = interaction.respond
  interaction.respond = nil
  if respond then
    pcall(respond, interaction.response)
  end
  pcall(self.on_settle, interaction, interaction.response)
  self:_retire(interaction)
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

---Complete an elicitation started earlier (URL mode).
---@param params table|nil
function Interactions:complete(params)
  local id = type(params) == "table" and (params.elicitationId or params.id) or nil
  if not id then
    return false
  end
  for _, interaction in ipairs(self.order) do
    if interaction.type == "elicitation" and interaction.request.elicitationId == id then
      return self:resolved(interaction.id)
    end
  end
  return false
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
  if rpc_id == nil then
    return false
  end
  for _, interaction in ipairs(self.order) do
    if interaction.rpc_id == rpc_id then
      interaction.state = "expired"
      if self.shown == interaction.id then
        self.shown = nil
        local presenter = self.presenters[interaction.type]
        if presenter and presenter.dismiss then
          pcall(presenter.dismiss, interaction)
        end
      end
      interaction.respond = nil
      -- The tool card clears its "awaiting" state from on_settle; a withdrawn
      -- request must not leave it waiting forever.
      pcall(self.on_settle, interaction, nil)
      self:_retire(interaction)
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

---@param session_id string|nil nil asks about every session
---@return boolean
function Interactions:waiting(session_id)
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
