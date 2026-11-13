-- Agent connection lifecycle: create the client, start it, disconnect and
-- reconnect. Session restoration is delegated back to the controller, because
-- the decision depends on the currently selected session.
local log = require("acp.log")
local client_mod = require("acp.protocol.client")
local capabilities = require("acp.protocol.capabilities")
local work_scheduler = require("acp.ui.work_scheduler")
local Resolve = require("acp.manager.resolve")

local Connection = {}
Connection.__index = Connection

---@param opts {config: fun(): table, resolve_cwd: fun(): string,
---  state: fun(): table, generation: fun(): integer, reset_operations: fun(),
---  on_event: fun(name: string, payload: any, client: table),
---  notify: fun(message: string, level: integer|nil), on_changed: fun(),
---  on_ready: fun(), on_start_failed: fun(err: any), on_stopped: fun(),
---  runtime_lost: fun(), reset_permissions: fun(), stop_animation: fun(),
---  interactions: fun(): table|nil, on_render: fun(), store: fun(): table|nil,
---  locks: table|nil}
function Connection.new(opts)
  return setmetatable({
    config = opts.config,
    resolve_cwd = opts.resolve_cwd,
    state = opts.state,
    generation = opts.generation,
    reset_operations = opts.reset_operations,
    on_event = opts.on_event,
    notify = opts.notify,
    on_changed = opts.on_changed,
    on_ready = opts.on_ready,
    on_start_failed = opts.on_start_failed,
    on_stopped = opts.on_stopped,
    runtime_lost = opts.runtime_lost,
    reset_permissions = opts.reset_permissions,
    stop_animation = opts.stop_animation,
    interactions = opts.interactions,
    on_render = opts.on_render,
    store = opts.store,
    locks = opts.locks,
    lease = nil,
    pending_reload = nil,
  }, Connection)
end

local function build_client_capabilities(config)
  return capabilities.client(config)
end

-- Exposed for the protocol conformance tests.
Connection.client_capabilities = build_client_capabilities

---Take a lease on the release this launch uses, if it is a managed one.
---
---External installs are not owned by the manager, so there is nothing to
---protect; managed installs are pinned so update/uninstall in any instance can
---see that the release is live.
---@param launch table|nil
function Connection:hold_lease(launch)
  if not launch or launch.source ~= "managed" or not launch.install_id then
    return
  end
  if not self.locks then
    return
  end
  if self.lease and self.lease.install_id == launch.install_id then
    return
  end
  self:release_lease()
  local lease = self.locks:lease(launch.agent_id or "", launch.install_id)
  if lease then
    self.lease = lease
  end
end

---Drop the lease held for the running client.
function Connection:release_lease()
  if self.lease and self.locks then
    self.locks:unlease(self.lease)
  end
  self.lease = nil
end

---Open the panel's agent process, starting it when needed.
function Connection:connect()
  local S = self.state()
  if S.conn.phase == "starting" then
    return
  end
  -- A stopped client carries old event bindings and an old RPC generation.
  -- Reopening after a crash uses a fresh client just like explicit reconnect.
  if S.conn.client and not S.conn.client:is_ready() then
    local previous = S.conn.client
    self.reset_operations()
    self.runtime_lost()
    S.conn.client = nil
    previous:shutdown(true)
  end
  S.conn.phase = "starting"
  self.on_changed()

  local cfg = self.config()
  if not S.conn.client then
    local client
    local generation = self.generation()
    -- Resolve once, here: the conversation, the terminal login and the health
    -- check all use this spec, so a managed install never runs two versions.
    local launch, launch_err = Resolve.resolve(cfg, cfg.agent, cfg.launch_origin, self.store and self.store())
    if not launch then
      S.conn.phase = "disconnected"
      self.on_changed()
      self.on_start_failed({ message = launch_err })
      return
    end
    client = client_mod.new({
      agent = vim.tbl_extend("force", {}, cfg.agents[cfg.agent], {
        command = launch.command,
        args = launch.args,
        env = launch.env or cfg.agents[cfg.agent].env,
      }),
      launch = launch,
      cwd = self.resolve_cwd(),
      client_capabilities = build_client_capabilities(cfg),
      mcp_servers = cfg.mcp_servers,
      scheduler = work_scheduler.shared,
      interactions = self.interactions and self.interactions() or nil,
      limits = cfg.transport,
      on_event = function(name, payload)
        local function dispatch()
          if self.state().conn.client == client and self.generation() == generation then
            self.on_event(name, payload, client)
          end
        end
        -- Notifications reduce state within the transport's dispatch budget.
        -- Exit is deferred once so already-settled RPC continuations run first.
        if name == "exit" then
          vim.schedule(dispatch)
        else
          dispatch()
        end
      end,
    })
    S.conn.client = client
  end

  if not S.conn.client:is_ready() then
    local client = S.conn.client
    local generation = self.generation()
    S.conn.client:start(function(ok, err)
      vim.schedule(function()
        -- The connection may have been replaced or torn down between `start`
        -- and this callback; adopt the result only for the live client.
        if self.state().conn.client ~= client or self.generation() ~= generation then
          return
        end
        if ok then
          self.state().conn.phase = "ready"
          -- Pin the exact release this client runs: an install or update in any
          -- instance must not delete files under a live conversation.
          self:hold_lease(client.launch)
          self.on_changed()
          self.on_ready()
        else
          self.state().conn.phase = "disconnected"
          self.on_changed()
          self.on_start_failed(err)
        end
      end)
    end)
  else
    S.conn.phase = "ready"
    self:hold_lease(S.conn.client and S.conn.client.launch)
    self.on_changed()
    self.on_ready()
  end
end

---Stop the agent process without closing the panel.
function Connection:disconnect()
  local S = self.state()
  self.reset_operations()
  self.runtime_lost()
  self.reset_permissions()
  local client = S.conn.client
  S.conn.client = nil
  if client then
    client:shutdown()
  end
  self:release_lease()
  S.conn.phase = "stopped"
  self.stop_animation()
  self.on_render()
  self.on_changed()
end

---Reconnect after a crash or an explicit disconnect.
function Connection:reconnect()
  local S = self.state()
  if S.conn.phase == "starting" or S.conn.phase == "ready" then
    return
  end
  self:restart()
end

---Replace the agent process unconditionally.
---
---A terminal login changes credentials on disk, so the running process must be
---restarted even though the connection is still healthy. `reconnect` is a no-op
---in that state, which is why this path exists separately.
function Connection:restart()
  local S = self.state()
  local previous = S.sess.current
  self.reset_operations()
  self.runtime_lost()
  self.reset_permissions()
  self.pending_reload = previous and previous.id or nil
  if S.conn.client then
    S.conn.client:shutdown(true)
    S.conn.client = nil
  end
  S.conn.phase = "stopped"
  self:connect()
end

---Take and clear the session id that must be restored when ready.
---@return string|nil
function Connection:take_pending_reload()
  local id = self.pending_reload
  self.pending_reload = nil
  return id
end

---Handle the transport reporting that the agent process is gone.
---
---Returns whether a turn was interrupted, so the caller can surface the
---condition with its own user-facing wording.
---@param payload table|nil
---@return boolean interrupted
function Connection:lost(payload)
  local S = self.state()
  local session = S.sess.current
  local interrupted = session and session.status ~= "idle" or false
  self.reset_operations()
  self.runtime_lost()
  S.conn.phase = "disconnected"
  self:release_lease()
  self.stop_animation()
  -- The agent is gone: its pending permission prompts can never be answered,
  -- so clear them instead of leaving the picker (and the toolbar badge) up.
  self.reset_permissions()
  if payload and payload.stderr and payload.stderr ~= "" then
    log.info("agent stderr:\n%s", payload.stderr)
  end
  self.on_changed()
  self.on_render()
  return interrupted
end

function Connection:terminate()
  local S = self.state()
  if S.conn.client then
    S.conn.client:shutdown(true)
    S.conn.client = nil
  end
  self:release_lease()
  log.debug("agent process terminated")
end

return Connection
