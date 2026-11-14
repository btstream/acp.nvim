-- Client event dispatch.
--
-- The controller used to route every agent event through one long `if` chain.
-- This module keeps the routing in a table so a domain service can register its
-- own handler instead of growing that chain, and so tests can add a handler
-- without touching the controller.
local log = require("acp.log")

local M = {}
M.__index = M

---@param deps {state: fun(): table, refresh_chrome: fun(), notify: fun(message: string, level: integer|nil),
---  add_block: fun(text: string, kind: string|nil, target: table|nil),
---  prune: fun(), on_exit: fun(payload: table): boolean}
---@return table
function M.new(deps)
  local self = setmetatable({ deps = deps, handlers = {} }, M)
  self:install_defaults()
  return self
end

---Route one event. Unknown names are ignored, matching the old `if` chain.
---@param name string
---@param payload any
function M:dispatch(name, payload)
  local handler = self.handlers[name]
  if not handler then
    log.debug("unhandled client event %s", tostring(name))
    return
  end
  handler(payload)
end

---Register or replace a handler.
---
---Domain services call this to own their events. Replacing a handler is allowed
---on purpose: a test or an integration may want to observe an event without
---duplicating the default behaviour.
---@param name string
---@param fn fun(payload: any)
function M:register(name, fn)
  assert(type(name) == "string" and name ~= "", "event name required")
  assert(type(fn) == "function", "event handler must be a function")
  self.handlers[name] = fn
end

function M:install_defaults()
  local deps = self.deps

  self.handlers.starting = function()
    deps.state().conn.phase = "starting"
    deps.refresh_chrome()
  end

  self.handlers.ready = function()
    deps.state().conn.phase = "ready"
    deps.refresh_chrome()
  end

  self.handlers.session_update = function(payload)
    local S = deps.state()
    local update = payload.update or {}
    -- Replaying a long history can take longer than the generic timeout: every
    -- update that arrives proves the agent is still working.
    if S.conn.replaying and S.conn.client and S.conn.client.touch_timeout then
      S.conn.client:touch_timeout("session/load")
    end
    local session, changed, buffered = S.sess.runtime:apply(payload.sessionId, update)
    if not session then
      if not buffered then
        log.debug("dropping update for unknown session %s", tostring(payload.sessionId))
      end
      return
    end
    if changed then
      deps.prune()
    end
    if changed and S.sess.current == session and S.view.chat then
      S.view.chat:schedule_render()
      if not S.conn.replaying then
        deps.refresh_chrome()
      end
    end
  end

  self.handlers.permission_request = function(payload)
    local S = deps.state()
    local client = S.conn.client
    S.view.interactions:open("permission", {
      session_id = payload.session_id,
      toolCall = payload.tool_call,
      options = payload.options,
    }, function(response)
      local outcome = response.outcome or {}
      if client then
        client:resolve_permission(payload.key, outcome.outcome == "selected" and outcome.optionId or nil)
      end
    end, nil, payload.key)
  end

  self.handlers.elicitation_request = function(payload)
    local S = deps.state()
    local client = S.conn.client
    S.view.interactions:open("elicitation", payload.request or {}, function(response)
      if client then
        client:resolve_elicitation(payload.key, response)
      end
    end, nil, payload.key)
  end

  self.handlers.permission_resolved = function(payload)
    deps.state().view.interactions:resolved(payload.key)
    deps.refresh_chrome()
  end

  self.handlers.prompt_finished = function(payload)
    local S = deps.state()
    local session = S.sess.all[payload.session_id]
    if session and session.prompt_task then
      return -- its scoped task owns settlement
    end
    -- `send_now` settles the turn itself and may already have started the next
    -- queued turn. This event is delivered asynchronously, so only act when it
    -- still refers to the turn that is currently running: otherwise it used to
    -- mark a freshly started turn as idle, and the following prompt hit the
    -- agent's "session already has an active prompt" error.
    if session and session.status ~= "idle" and (payload.turn == nil or session.turn == payload.turn) then
      session:finish_turn(payload.ok and (payload.result and payload.result.stopReason) or "error")
      deps.refresh_chrome()
      if S.view.chat then
        S.view.chat:schedule_render()
      end
    end
  end

  self.handlers.exit = function(payload)
    if deps.on_exit(payload) then
      deps.add_block("Agent disconnected" .. "  :Acp reconnect", "error")
    end
    deps.notify("Agent disconnected" .. "  :Acp reconnect", vim.log.levels.WARN)
  end

  self.handlers.connection_error = function(payload)
    log.error("connection error: %s", vim.inspect(payload))
  end
end

return M
