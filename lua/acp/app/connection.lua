-- Agent connection lifecycle: create the client, start it, disconnect and
-- reconnect. Session restoration is delegated back to the controller, because
-- the decision depends on the currently selected session.
local log = require("acp.log")
local client_mod = require("acp.protocol.client")
local capabilities = require("acp.protocol.capabilities")
local work_scheduler = require("acp.ui.work_scheduler")

local Connection = {}
Connection.__index = Connection

---@param opts {config: fun(): table, resolve_cwd: fun(): string,
---  state: fun(): table, generation: fun(): integer, reset_operations: fun(),
---  on_event: fun(name: string, payload: any, client: table),
---  notify: fun(message: string, level: integer|nil), on_changed: fun(),
---  on_ready: fun(), on_start_failed: fun(err: any), on_stopped: fun(),
---  runtime_lost: fun(), reset_permissions: fun(), stop_animation: fun(),
---  interactions: fun(): table|nil, on_render: fun()}
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
    pending_reload = nil,
  }, Connection)
end

local function build_client_capabilities(config)
  return capabilities.client(config)
end

-- Exposed for the protocol conformance tests.
Connection.client_capabilities = build_client_capabilities

---Open the panel's agent process, starting it when needed.
function Connection:connect()
  local S = self.state()
  if S.connection == "starting" then
    return
  end
  -- A stopped client carries old event bindings and an old RPC generation.
  -- Reopening after a crash uses a fresh client just like explicit reconnect.
  if S.client and not S.client:is_ready() then
    local previous = S.client
    self.reset_operations()
    self.runtime_lost()
    S.client = nil
    previous:shutdown(true)
  end
  S.connection = "starting"
  self.on_changed()

  local cfg = self.config()
  if not S.client then
    local client
    local generation = self.generation()
    client = client_mod.new({
      agent = cfg.agents[cfg.agent],
      cwd = self.resolve_cwd(),
      client_capabilities = build_client_capabilities(cfg),
      scheduler = work_scheduler.shared,
      interactions = self.interactions and self.interactions() or nil,
      limits = cfg.transport,
      on_event = function(name, payload)
        local function dispatch()
          if self.state().client == client and self.generation() == generation then
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
    S.client = client
  end

  if not S.client:is_ready() then
    local client = S.client
    local generation = self.generation()
    S.client:start(function(ok, err)
      vim.schedule(function()
        -- The connection may have been replaced or torn down between `start`
        -- and this callback; adopt the result only for the live client.
        if self.state().client ~= client or self.generation() ~= generation then
          return
        end
        if ok then
          self.state().connection = "ready"
          self.on_changed()
          self.on_ready()
        else
          self.state().connection = "disconnected"
          self.on_changed()
          self.on_start_failed(err)
        end
      end)
    end)
  else
    S.connection = "ready"
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
  local client = S.client
  S.client = nil
  if client then
    client:shutdown()
  end
  S.connection = "stopped"
  self.stop_animation()
  self.on_render()
  self.on_changed()
end

---Reconnect after a crash or an explicit disconnect.
function Connection:reconnect()
  local S = self.state()
  if S.connection == "starting" or S.connection == "ready" then
    return
  end
  local previous = S.session
  self.reset_operations()
  self.runtime_lost()
  self.reset_permissions()
  self.pending_reload = previous and previous.id or nil
  if S.client then
    S.client:shutdown(true)
    S.client = nil
  end
  S.connection = "stopped"
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
  local session = S.session
  local interrupted = session and session.status ~= "idle" or false
  self.reset_operations()
  self.runtime_lost()
  S.connection = "disconnected"
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
  if S.client then
    S.client:shutdown(true)
    S.client = nil
  end
  log.debug("agent process terminated")
end

return Connection
