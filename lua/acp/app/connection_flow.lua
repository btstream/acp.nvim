-- Connection flows that involve the user: the parked message after a login and
-- switching agents.
--
-- Both are multi-step and stateful — a retry timer, a teardown that samples work
-- before it is destroyed — so they do not belong inline in the controller.
local presenter = require("acp.app.presenter")

local M = {}

---@param deps {state: fun(): table, config: fun(): table, notify: fun(message: string, level: integer|nil),
---  connect: fun(), open: fun(), setup: fun(opts: table, action: table|nil)}
---@return table
function M.new(deps)
  return setmetatable({ deps = deps }, { __index = M })
end

function M:state()
  return self.deps.state()
end

function M:notify(message, level)
  return self.deps.notify(message, level)
end

---Send a message that was waiting for the session to come back after a login.
---
---The message is kept until it is actually accepted: after a terminal login the
---session is replayed first, and sending during a replay is refused.
---@return boolean sent
function M:flush_auth_retry()
  local S = self:state()
  local pending = S.conn.pending_auth_retry
  if not pending then
    return false
  end
  local runtime = S.sess.runtime
  local session = runtime and runtime.sessions[pending.session_id]
  if
    not S.sess.prompts
    or not session
    or session.needs_load
    or session.status ~= "idle"
    or session.prompt_task
    or #session.queue > 0
    or (runtime and runtime.replays[pending.session_id])
  then
    if pending.deadline and vim.uv.now() > pending.deadline then
      S.conn.pending_auth_retry = nil
      self:notify("logged in; send the message again", vim.log.levels.INFO)
    end
    return false
  end
  if S.sess.prompts:send(session, pending.text, pending.attachments, nil, pending.retrying ~= false) then
    S.conn.pending_auth_retry = nil
    return true
  end
  return false
end

---Poll for a session that can accept the parked message.
function M:schedule_auth_retry()
  local S = self:state()
  if not S.conn.pending_auth_retry or S.conn.auth_retry_timer then
    return
  end
  S.conn.auth_retry_timer = vim.defer_fn(function()
    S.conn.auth_retry_timer = nil
    local pending = S.conn.pending_auth_retry
    if not pending then
      return
    end
    if self:flush_auth_retry() then
      return
    end
    if vim.uv.now() > (pending.deadline or 0) then
      S.conn.pending_auth_retry = nil
      self:notify("logged in; send the message again", vim.log.levels.INFO)
      return
    end
    self:schedule_auth_retry()
  end, 200)
end

---Park a message for `flush_auth_retry`, replacing any older one.
---@param session_id string
---@param text string
---@param attachments table[]
function M:park_for_retry(session_id, text, attachments)
  local S = self:state()
  S.conn.pending_auth_retry = {
    session_id = session_id,
    text = text,
    attachments = attachments,
    retrying = true,
    deadline = vim.uv.now() + 30000,
  }
  self:schedule_auth_retry()
end

---Messages and running turns that a reconfiguration would lose.
---@return integer queued, integer running
function M:pending_work()
  local queued, running = 0, 0
  for _, session in pairs(self:state().sess.all) do
    queued = queued + #session.queue
    if session.status ~= "idle" then
      running = running + 1
    end
  end
  return queued, running
end

---Switch the agent, reusing the configuration for everything else.
---
---Switching tears down the connection and every session, so pending messages
---would be lost. Ask first instead of silently dropping them.
---@param name string|nil
function M:pick_agent(name)
  local S = self:state()
  if not S.config then
    return
  end
  local names = vim.tbl_keys(S.config.agents)
  table.sort(names)
  local self_ = self
  local function switch(target)
    if target == S.config.agent then
      self_:notify("already using " .. target, vim.log.levels.INFO)
      return
    end
    -- Sample before teardown: setup() clears the sessions that hold the queue.
    local queued, running = self_:pending_work()
    local opts = vim.deepcopy(S.config)
    opts.agent = target
    pcall(function()
      require("acp.inline").stop()
    end)
    self_.deps.setup(opts, { discard_queued = true })
    if queued > 0 or running > 0 then
      self_:notify(
        string.format(
          "Switching agents dropped %d queued message(s) and interrupted %d running turn(s)",
          queued,
          running
        ),
        vim.log.levels.WARN
      )
    end
    self_:notify("Switched to " .. target, vim.log.levels.INFO)
    self_.deps.open()
  end
  if name and name ~= "" then
    if not S.config.agents[name] then
      self:notify("unknown agent " .. name .. "; configured: " .. table.concat(names, ", "), vim.log.levels.WARN)
      return
    end
    switch(name)
    return
  end
  if #names == 1 then
    switch(names[1])
    return
  end
  local items = {}
  for _, candidate in ipairs(names) do
    local agent_cfg = S.config.agents[candidate]
    -- Show what would actually start: a managed install replaces the preset.
    local ok, launch = pcall(require("acp.manager.resolve").describe, S.config, candidate, S.config.launch_origin)
    local description
    if ok and launch.available then
      description = string.format(
        "[%s] %s",
        launch.source,
        table.concat(vim.list_extend({ launch.command }, launch.args or {}), " ")
      )
    elseif ok then
      description = "unavailable: " .. tostring(launch.error)
    else
      description = table.concat(vim.list_extend({ agent_cfg.command or "" }, agent_cfg.args or {}), " ")
    end
    items[#items + 1] = {
      label = candidate .. (candidate == S.config.agent and " (current)" or ""),
      description = description,
      value = candidate,
    }
  end
  presenter.select({
    title = "Agent",
    items = items,
    on_choice = switch,
  })
end

return M
