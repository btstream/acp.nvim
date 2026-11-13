-- Prompt submission: validation, local queueing and turn settlement.
--
-- Only the scoped prompt task settles its turn and advances the outbox. The
-- controller keeps composer ownership: it decides whether a draft is cleared
-- after this module reports that the message was accepted.
local context = require("acp.context")
local capabilities = require("acp.protocol.capabilities")

local Prompts = {}
Prompts.__index = Prompts

---@param opts {config: fun(): table, runtime: fun(): table,
---  client: fun(): table|nil, connection: fun(): string,
---  auth: fun(): table|nil,
---  retry: fun(session_id: string, text: string, attachments: table[]|nil): boolean,
---  run: fun(key: string, client: table|nil, session: table|nil,
---  fn: fun(task: table), on_error: fun(err: any, task: table)|nil,
---  on_finally: fun(task: table, owned: boolean)|nil): table,
---  selected: fun(session: table): boolean,
---  on_turn_start: fun(session: table), on_turn_end: fun(session: table),
---  on_changed: fun(), on_render: fun(session: table),
---  add_block: fun(message: string, kind: string, session: table),
---  prune: fun(), dispatch_queued: fun(session: table),
---  refresh_title: fun(session: table),
---  notify: fun(message: string, level: integer|nil)}
function Prompts.new(opts)
  return setmetatable({
    config = opts.config,
    get_runtime = opts.runtime,
    get_client = opts.client,
    connection = opts.connection,
    get_auth = opts.auth,
    retry = opts.retry,
    run = opts.run,
    selected = opts.selected,
    on_turn_start = opts.on_turn_start,
    on_turn_end = opts.on_turn_end,
    on_changed = opts.on_changed,
    on_render = opts.on_render,
    add_block = opts.add_block,
    prune = opts.prune,
    dispatch_queued = opts.dispatch_queued,
    refresh_title = opts.refresh_title,
    notify = opts.notify,
  }, Prompts)
end

---Undo a turn that will be retried after a login. The user's message stays in
---the transcript (it was never delivered); only the turn state is closed.
---@param session table
---@param turn integer
function Prompts:drop_turn(session, turn)
  if not session or session.turn ~= turn then
    return
  end
  session.pending_user = nil
  session:finish_turn("error")
end

---Send a message to `session`, queueing it when a turn is already active.
---@param session table
---@param text string
---@param attachments table[]|nil
---@param hooks table|nil
---@param retrying boolean|nil reuse the existing user block (login retry)
---@return boolean accepted
function Prompts:send(session, text, attachments, hooks, retrying)
  if not session then
    self.notify("No active session", vim.log.levels.WARN)
    return false
  end
  local client = self.get_client()
  if self.connection() ~= "ready" or not client then
    self.notify("No agent process is running", vim.log.levels.WARN)
    return false
  end
  if client.is_ready and not client:is_ready() then
    return false
  end
  local runtime = self.get_runtime()
  if session.needs_load or runtime.replays[session.id] then
    self.notify("Wait for this session's history to load before sending", vim.log.levels.WARN)
    return false
  end

  -- Expand @file mentions into attachments before queueing.
  -- Snapshot token positions: later edits/undo in the composer must not mutate
  -- a queued prompt or the local transcript of a message already sent.
  attachments = vim.deepcopy(attachments or {})
  if not hooks and text and text:find("@", 1, true) then
    local mentioned = context.mentions(text, self.config(), session.cwd)
    if #mentioned > 0 then
      local merged = vim.deepcopy(attachments or {})
      for _, att in ipairs(mentioned) do
        local duplicate = false
        for _, existing in ipairs(merged) do
          if existing.path == att.path and existing.kind == att.kind then
            duplicate = true
            break
          end
        end
        if not duplicate then
          merged[#merged + 1] = att
        end
      end
      attachments = merged
    end
  end

  local cfg = self.config()
  local image_count = 0
  for _, att in ipairs(attachments or {}) do
    if att.kind == "image" then
      image_count = image_count + 1
      if cfg.context.images.enabled == false or image_count > cfg.context.images.max_per_message then
        self.notify("Image attachments are disabled or exceed context.images.max_per_message", vim.log.levels.WARN)
        return false
      end
      if not capabilities.prompt(client, "image") and att.inline ~= false then
        self.notify("This agent does not accept images; switch models or remove the attachment", vim.log.levels.WARN)
        return false
      end
    end
  end

  if session.status == "running" or session.status == "cancelling" then
    if hooks then
      self.notify("Wait for the current turn to finish before submitting inline", vim.log.levels.WARN)
      return false
    end
    -- Session already has an active turn (or one being cancelled): queue
    -- locally instead of starting a second overlapping prompt.
    if not runtime:enqueue(session, text, attachments) then
      self.notify("Message queue memory limit reached; keep this draft until a turn finishes", vim.log.levels.WARN)
      return false
    end
    self.on_changed()
    return true
  end

  -- The agent advertises whether it can decode images. A resource_link is
  -- always allowed, so only refuse when this attachment would really become an
  -- `image` block; otherwise let the turn fail later with a protocol error.
  local blocks, block_err = context.to_prompt(text, attachments, cfg)
  if block_err then
    -- An image that disappeared from the cache must not become a silent
    -- omission: the user would send a prompt referencing something the agent
    -- never received.
    self.notify("Cannot attach image: " .. block_err, vim.log.levels.WARN)
    return false
  end
  if #blocks == 0 then
    return false
  end

  local turn
  if retrying then
    -- The user block is already in the transcript from the failed attempt.
    turn = runtime:rebegin_turn(session)
  else
    turn = runtime:begin_turn(session, text, attachments)
  end
  self.on_turn_start(session)
  self.on_changed()

  local operation = self.run("prompt:" .. session.id, client, session, function(task)
    session.prompt_task = task
    local function add_error(message)
      self.add_block(message, "error", session)
    end
    local ok, result = task:call("prompt", session.id, blocks, turn)
    if session.turn ~= turn then
      return
    end
    if not ok then
      task.status = "failed"
      local raw = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
      local lowered = tostring(raw):lower()
      local auth = self.get_auth and self.get_auth()
      local handled = auth
        and auth:require(result, {
          retry = function()
            -- A terminal login replaces the client, so this turn cannot
            -- continue: park the message and let the owner replay it.
            if self.retry then
              self.retry(session.id, text, attachments, true)
            end
          end,
        })
      if handled then
        -- The login flow owns the message and the retry; the transcript must
        -- not keep an optimistic user block that would then appear twice.
        self:drop_turn(session, turn)
        self.prune()
        self.on_turn_end(session)
        self.on_changed()
        self.on_render(session)
        self.dispatch_queued(session)
        return
      elseif lowered:match("already has an active") then
        -- The agent still has a turn running that this client does not know
        -- about (for example another editor sharing the session). Do not
        -- silently swallow it: explain the state and how to recover.
        add_error(
          raw
            .. "\n\n"
            .. "The agent still considers a turn active for this session. "
            .. "Use :Acp cancel to ask it to stop, or :Acp reconnect to start a fresh connection."
        )
      elseif lowered:match("limit") or lowered:match("quota") or lowered:match("rate") then
        -- Provider-side quota problems are not plugin errors; give the user
        -- the one action that actually helps.
        add_error(
          raw
            .. "\n\n"
            .. "This is a provider-side limit, not an acp.nvim error. Click the model name in the toolbar, press <M-m> while typing, or run :Acp model."
        )
      else
        -- Agent-specific advice comes last: the generic classifications above
        -- are protocol-wide, while a profile hint knows this agent's quirks.
        local profile = session.profile
        local hint = profile and profile.error_hint and profile.error_hint(result) or nil
        add_error("prompt failed: " .. raw .. (hint and ("\n\n" .. hint) or ""))
      end
      runtime:finish_turn(session, turn, "error")
    else
      runtime:finish_turn(session, turn, result and result.stopReason or "end_turn")
    end
    if hooks and hooks.on_result then
      hooks.on_result(ok, result)
    end
    self.prune()
    self.on_turn_end(session)
    self.on_changed()
    self.on_render(session)
    -- The agent auto-generates a title from the first exchange, and it is only
    -- exposed through session/list, so refresh once the turn has settled.
    self.refresh_title(session)
  end, function(err, task)
    if task:current() then
      self.add_block("prompt failed: " .. tostring(err), "error", session)
      runtime:finish_turn(session, turn, "error")
    end
  end, function(task, owned)
    if hooks and hooks.on_finally then
      hooks.on_finally(task, owned)
    end
    if session.prompt_task == task then
      session.prompt_task = nil
    end
    if not owned or not runtime:owns(session) or session.turn ~= turn then
      return
    end
    if session.status ~= "idle" then
      runtime:finish_turn(session, turn, "error")
    end
    if self.selected(session) then
      self.on_turn_end(session)
      self.on_changed()
      self.on_render(session)
    end
    -- Only this task owns turn settlement and queue advancement. Selection is
    -- irrelevant, and the old operation is gone before a queued turn starts.
    self.dispatch_queued(session)
  end)
  return operation.status == "running" or operation.status == "succeeded"
end

---Queue the next accepted message for a background session.
---@param session table
function Prompts:dispatch(session)
  self.dispatch_queued(session)
end

return Prompts
