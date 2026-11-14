-- Submitting and cancelling turns.
--
-- The composer, the public API and inline all funnel through here. The subtle
-- parts are that a message is only cleared from the composer once it was really
-- accepted, and that a second cancel must end the turn locally rather than wait
-- for an agent that may never answer.
local M = {}

---@param deps {state: fun(): table, refresh_chrome: fun(), notify: fun(message: string, level: integer|nil),
---  cancel_session: fun(session: table)}}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps }, { __index = M })
end

function M:state()
  return self.deps.state()
end

---Append a local block to a session (defaults to the selected one).
---@param text string
---@param kind string|nil
---@param target table|nil
function M:add_system_block(text, kind, target)
  local S = self:state()
  local session = target or S.sess.current
  if not session then
    return
  end
  session:append({ id = "sys:" .. tostring(#session.blocks), kind = kind or "error", text = text })
  if S.view.chat and S.sess.current == session then
    S.view.chat:schedule_render()
  end
end

---Send a message to `target`, or to the selected session.
---@param text string
---@param attachments table[]|nil
---@param target table|nil
---@return boolean accepted
function M:send(text, attachments, target)
  local S = self:state()
  if not S.sess.prompts then
    return false
  end
  return S.sess.prompts:send(target or S.sess.current, text, attachments)
end

---Inline is a normal turn in the selected session, not a new ACP session.
function M:send_inline(session, text, hooks)
  local S = self:state()
  if session ~= S.sess.current or not S.sess.prompts then
    return false
  end
  return S.sess.prompts:send(session, text, nil, hooks)
end

---Submit from the composer.
---@param text string
---@param attachments table[]
function M:submit(text, attachments)
  local S = self:state()
  if not S.sess.current then
    self.deps.notify("No active session", vim.log.levels.WARN)
    return
  end
  -- Only clear the composer when the message was actually accepted; clearing
  -- after a no-op send silently discarded what the user typed.
  local session, input = S.sess.current, S.view.input
  local accepted = self:send(text, attachments)
  if accepted and input then
    if S.view.input == input and S.sess.current == session then
      input:clear()
    else
      input:discard_draft(session)
    end
  end
  self.deps.refresh_chrome()
end

---Cancel the active turn.
function M:cancel()
  local S = self:state()
  local session = S.sess.current
  if not session then
    return
  end
  local inline = package.loaded["acp.inline"]
  if inline and inline.stop(session) then
    self.deps.refresh_chrome()
    return
  end
  if session.status == "cancelling" then
    -- A second cancel request must not be a no-op: end the turn locally and
    -- release its task instead of waiting for an agent that may never reply.
    -- Finish the turn and withdraw the old prompt *before* cancelling the task:
    -- the task finalizer dispatches the next queued message synchronously, so
    -- the opposite order would let this cancel hit that brand-new prompt.
    local task = session.prompt_task
    session:finish_turn("cancelled")
    if S.conn.client then
      S.conn.client:cancel(session.id)
    end
    self.deps.cancel_session(session)
    -- The finalizer usually cleared it already; only drop it when the queued
    -- dispatch did not install a new task in the meantime.
    if session.prompt_task == task then
      session.prompt_task = nil
    end
    self.deps.refresh_chrome()
    if S.view.chat then
      S.view.chat:schedule_render()
    end
    return
  end
  if not session:cancel_turn() then
    return
  end
  if S.conn.client then
    S.conn.client:cancel(session.id)
  end
  self.deps.refresh_chrome()
  if S.view.chat then
    S.view.chat:schedule_render()
  end
end

return M
