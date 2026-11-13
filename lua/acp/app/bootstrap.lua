-- Service construction for `controller.setup`.
--
-- This used to be a 500-line function inside the controller. It is not logic —
-- every branch is "build this service, give it these callbacks" — so it lives
-- here and receives the controller's helpers through `ctx`. Keeping it in a
-- separate module is what lets the controller itself stay small.
local config_mod = require("acp.config")
local log = require("acp.log")
local work = require("acp.ui.work_scheduler")
local highlights = require("acp.ui.highlights")
local layout = require("acp.layout")
local drafts = require("acp.storage.drafts")
local Runtime = require("acp.session.runtime")
local Catalog = require("acp.app.catalog")
local Permissions = require("acp.app.permissions")
local Elicitation = require("acp.app.elicitation")
local Interactions = require("acp.app.interactions")
local Options = require("acp.app.options")
local Chrome = require("acp.ui.chrome")
local Sessions = require("acp.app.sessions")
local Prompts = require("acp.app.prompts")
local Auth = require("acp.app.auth")
local Connection = require("acp.app.connection")
local Panel = require("acp.ui.panel")
local Chat = require("acp.ui.chat")
local Input = require("acp.ui.input")
local Status = require("acp.app.status")
local Attachments = require("acp.app.attachments")
local Events = require("acp.app.events")
local ConnectionFlow = require("acp.app.connection_flow")

local M = {}

---Reconfigure everything: state, services, views and keymaps.
---
---@param ctx table controller helpers and entry points
---@param opts table|nil user configuration
---@param action {discard_queued?: boolean}|nil
function M.build(ctx, opts, action)
  local S = ctx.state
  local cfg = ctx.cfg
  local notify = ctx.notify

  local merged = config_mod.merge(config_mod.defaults, opts or {})
  local ok, err = pcall(config_mod.validate, merged)
  if not ok then
    error(err, 0)
  end
  config_mod.remember(merged)
  if not (action and action.discard_queued == true) then
    for _, session in pairs(S.sess.all) do
      if #session.queue > 0 or (session.outbox and session.outbox.reserved) then
        error(
          "acp.nvim: cannot reconfigure with queued messages; drain them first or explicitly pass { discard_queued = true } as the second setup argument",
          0
        )
      end
    end
  end
  if S.view.input then
    pcall(S.view.input.save_draft, S.view.input)
  end
  ctx.invalidate_operations()
  S.config = merged

  S.conn.flow = ConnectionFlow.new({
    state = function()
      return S
    end,
    config = cfg,
    notify = notify,
    connect = ctx.connect,
    open = ctx.open,
    setup = ctx.setup or function(next_opts, next_action)
      return M.build(ctx, next_opts, next_action)
    end,
  })

  S.view.status = Status.new({
    state = function()
      return S
    end,
    config = cfg,
    chrome = function()
      return S.view.chrome
    end,
  })

  log.setup(merged.log)
  work.configure(merged.ui.render.budget_ms)
  highlights.setup(merged.ui.highlights)
  layout.setup(merged)

  -- Reconfiguring means a different agent, cwd or UI: drop the old runtime
  -- state instead of mixing sessions from two configurations.
  ctx.stop_spinner()
  if S.view.chrome then
    S.view.chrome:destroy()
  end

  -- Release the previous panel: windows belong to the previous Chat/Input
  -- objects, which are replaced below. Leaving them open would strand windows
  -- that nothing tracks.
  if S.view.panel then
    S.view.panel:set_views(S.view.chat, S.view.input)
    S.view.panel:destroy()
  end

  if S.conn.client then
    pcall(S.conn.client.shutdown, S.conn.client, true)
    S.conn.client = nil
  end
  S.sess.current = nil
  S.sess.all = {}
  S.sess.runtime = Runtime.new(
    merged.memory,
    S.sess.all,
    merged.ui.thoughts,
    require("acp.agents").get(merged.agents[merged.agent], merged.agent)
  )
  S.sess.titles, S.sess.cwds = {}, {}
  -- Titles and cwds are cached per agent: switching agents must not show one
  -- agent's session titles for another's sessions, and switching back restores
  -- what was already learned.
  S.sess.agent_store = S.sess.agent_store or {}
  local store = S.sess.agent_store[merged.agent]
  if not store then
    store = { titles = {}, cwds = {} }
    S.sess.agent_store[merged.agent] = store
  end
  S.sess.titles, S.sess.cwds = store.titles, store.cwds
  S.sess.catalog = Catalog.new({
    titles = function()
      return S.sess.titles
    end,
    cwds = function()
      return S.sess.cwds
    end,
    client = function()
      return S.conn.client
    end,
    connection = function()
      return S.conn.phase
    end,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    on_changed = ctx.refresh_chrome,
    notify = notify,
  })
  S.view.permissions = Permissions.new({
    config = cfg,
    valid = function(interaction)
      return interaction ~= nil
        and interaction.state == "pending"
        and ctx.ui_current(S.conn.client, ctx.Operations.generation)
    end,
    answer = function(interaction, option_id)
      ctx.resolve_permission(interaction.id, option_id, false)
    end,
    dismiss = function(interaction)
      ctx.resolve_permission(interaction.id, nil, true)
    end,
    notify = notify,
    session = function()
      return S.sess.current
    end,
  })
  S.view.elicitation = Elicitation.new({
    answer = function(interaction, response)
      S.view.interactions:answer(interaction.id, response)
    end,
    notify = notify,
  })
  S.view.interactions = Interactions.new({
    on_open = function(interaction)
      local session = interaction.session_id and S.sess.all[interaction.session_id] or nil
      local block = session and interaction.tool_call_id and session.tools[interaction.tool_call_id] or nil
      if not block then
        return
      end
      block.awaiting = interaction.type == "elicitation" and "answer" or "approval"
      block.interaction_id = interaction.id
      session:touch(block, false)
      if session == S.sess.current and S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
    on_settle = function(interaction)
      local session = interaction.session_id and S.sess.all[interaction.session_id] or nil
      local block = session and interaction.tool_call_id and session.tools[interaction.tool_call_id] or nil
      if not block then
        return
      end
      block.awaiting, block.interaction_id = nil, nil
      session:touch(block, false)
      if session == S.sess.current and S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
    policies = {
      -- Only the current inline turn may answer without the user.
      function(interaction)
        return require("acp.inline").policy(interaction)
      end,
      function(interaction)
        return S.view.permissions:auto(interaction)
      end,
    },
    presenters = {
      permission = {
        present = function(interaction)
          if not S.view.permissions.valid(interaction) then
            return false
          end
          return S.view.permissions:present(interaction)
        end,
        dismiss = function()
          S.view.permissions:dismiss_presented()
        end,
      },
      elicitation = {
        present = function(interaction)
          return S.view.elicitation:present(interaction)
        end,
        dismiss = function()
          S.view.elicitation:dismiss()
        end,
      },
    },
    on_changed = ctx.refresh_chrome,
    notify = notify,
  })

  S.view.options = Options.new({
    config = cfg,
    current = ctx.current,
    client = function()
      return S.conn.client
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    ui_current = ctx.ui_current,
    run = function(key, client, session, fn, on_error)
      return ctx.Operations:run(key, client, session, fn, on_error)
    end,
    on_changed = ctx.refresh_chrome,
    notify = notify,
  })
  S.view.chrome = Chrome.new({
    config = cfg,
    current = ctx.current,
    session_label = ctx.session_label,
    waiting = ctx.waiting_permission,
    chat = function()
      return S.view.chat
    end,
    input = function()
      return S.view.input
    end,
  })
  S.sess.service = Sessions.new({
    config = cfg,
    runtime = function()
      return S.sess.runtime
    end,
    catalog = S.sess.catalog,
    client = function()
      return S.conn.client
    end,
    connection = function()
      return S.conn.phase
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    new_local = ctx.new_local_session,
    resolve_cwd = ctx.resolve_cwd,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    cancel_session = function(session, except)
      return ctx.Operations:cancel_session(session, except)
    end,
    current = ctx.current,
    activate = ctx.activate_session,
    render = function()
      if S.view.chat then
        S.view.chat:render(true)
      end
    end,
    dispatch_queued = ctx.dispatch_queued,
    on_changed = ctx.refresh_chrome,
    on_replaying = function(value)
      S.conn.replaying = value
      if S.conn.client and S.conn.client.mark_phase then
        S.conn.client:mark_phase(value and "replay" or nil)
      end
      if not value then
        ctx.flush_auth_retry()
      end
    end,
    on_creating = function(value)
      S.conn.creating_session = value
    end,
    prune = ctx.prune_sessions,
    auth = function()
      return S.view.auth
    end,
    notify = notify,
  })
  S.sess.prompts = Prompts.new({
    config = cfg,
    runtime = function()
      return S.sess.runtime
    end,
    client = function()
      return S.conn.client
    end,
    connection = function()
      return S.conn.phase
    end,
    run = function(key, client, session, fn, on_error, on_finally)
      return ctx.Operations:run(key, client, session, fn, on_error, on_finally)
    end,
    auth = function()
      return S.view.auth
    end,
    retry = function(session_id, text, attachments)
      -- Never send from inside the failed turn: the client may be about to be
      -- replaced (a terminal login restarts it) and the captured session is
      -- stale. Park the message and flush it as soon as the session is usable.
      S.conn.flow:park_for_retry(session_id, text, attachments)
      return true
    end,
    selected = function(session)
      return S.sess.current == session
    end,
    on_turn_start = function(session)
      if S.view.chat and S.sess.current == session then
        S.view.chat.follow = true
        S.view.chat:schedule_render()
      end
    end,
    on_turn_end = function(session)
      if S.sess.current == session then
        ctx.stop_spinner()
      end
    end,
    on_changed = ctx.refresh_chrome,
    on_render = function(session)
      if S.view.chat and S.sess.current == session then
        S.view.chat:schedule_render()
      end
    end,
    add_block = ctx.add_system_block,
    prune = ctx.prune_sessions,
    dispatch_queued = ctx.dispatch_queued,
    refresh_title = ctx.refresh_session_title,
    notify = notify,
  })
  S.view.auth = Auth.new({
    config = cfg,
    client = function()
      return S.conn.client
    end,
    notify = notify,
    restart = function()
      S.conn.service:restart()
    end,
    base_window = function()
      return layout.saved_focus()
    end,
    after_ready = function(fn)
      -- The reconnect may already have finished by the time the login terminal
      -- exits (a fast agent, or a synchronous start); run immediately then.
      if S.conn.phase == "ready" and S.conn.client and S.conn.client:is_ready() then
        pcall(fn)
        return
      end
      S.conn.auth_after_ready = S.conn.auth_after_ready or {}
      S.conn.auth_after_ready[#S.conn.auth_after_ready + 1] = fn
    end,
    on_changed = ctx.refresh_chrome,
  })
  S.conn.service = Connection.new({
    config = cfg,
    resolve_cwd = ctx.resolve_cwd,
    state = function()
      return S
    end,
    generation = function()
      return ctx.Operations.generation
    end,
    reset_operations = ctx.invalidate_operations,
    on_event = function(name, payload)
      return ctx.on_client_event(name, payload)
    end,
    notify = notify,
    on_changed = ctx.refresh_chrome,
    on_ready = function()
      local reload_id = S.conn.service:take_pending_reload()
      if reload_id then
        ctx.reload_session(reload_id)
      elseif S.sess.current and S.sess.current.needs_load then
        ctx.reload_session(S.sess.current.id)
      elseif not S.sess.current then
        ctx.new_session()
      end
      local queued = S.conn.auth_after_ready
      S.conn.auth_after_ready = nil
      for _, fn in ipairs(queued or {}) do
        pcall(fn)
      end
      ctx.flush_auth_retry()
    end,
    on_start_failed = function(err)
      if
        S.view.auth
        and S.view.auth:require(err, {
          retry = function()
            ctx.connect()
          end,
        })
      then
        return
      end
      local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
      notify("failed to start agent: " .. message, vim.log.levels.ERROR)
    end,
    runtime_lost = function()
      S.sess.runtime:connection_lost()
    end,
    reset_permissions = function()
      if S.view.interactions then
        S.view.interactions:cancel_all("connection reset")
      end
    end,
    interactions = function()
      return S.view.interactions
    end,
    stop_animation = ctx.stop_spinner,
    on_render = function()
      if S.view.chat then
        S.view.chat:schedule_render()
      end
    end,
  })
  S.conn.phase = "stopped"
  S.conn.replaying = false
  S.conn.creating_session = false

  S.view.attachments = Attachments.new({
    state = function()
      return S
    end,
    config = cfg,
    notify = notify,
    refresh_chrome = ctx.refresh_chrome,
    focus = M.focus,
  })
  S.conn.events = Events.new({
    state = function()
      return S
    end,
    refresh_chrome = ctx.refresh_chrome,
    notify = notify,
    add_block = ctx.add_system_block,
    prune = ctx.prune_sessions,
    on_exit = function(payload)
      return S.conn.service:lost(payload)
    end,
  })

  S.view.panel = Panel.new({
    config = cfg,
    notify = notify,
    on_windows_ready = function()
      ctx.update_chat_title()
      ctx.refresh_chrome()
    end,
  })

  S.view.chat = Chat.new({ config = merged })
  S.view.chat.on_pending_new = function()
    ctx.update_chat_title()
  end
  S.view.input = Input.new({
    config = merged,
    on_submit = function(text, attachments)
      ctx.submit(text, attachments)
    end,
    on_cancel = function()
      ctx.cancel()
    end,
  })
  S.view.input.on_refresh = function()
    ctx.update_input_toolbar()
  end
  S.view.input.on_draft = function(key, text, attachments, owner)
    local session = owner or S.sess.all[key]
    if not session then
      return
    end
    drafts.put(session.cwd, session.id, text, attachments)
  end
  S.view.attachments:flush(S.view.input)

  -- Mappings and completion belong to buffers, not windows. Hiding, reopening
  -- or repairing a missing view reuses these buffers and needs no reattachment.
  local window = ctx.install_window({
    state = function()
      return S
    end,
    config = cfg,
    refresh_chrome = ctx.refresh_chrome,
    stop_spinner = ctx.stop_spinner,
    update_title = ctx.update_chat_title,
    prune_sessions = ctx.prune_sessions,
    sync_spinner = ctx.sync_spinner,
  })
  -- The inline editor is a leaf module: give it the application hooks it needs
  -- instead of letting it require the controller back.
  require("acp.inline").setup({
    state = function()
      return S
    end,
    send = function(session, text, hooks)
      return ctx.send_inline(session, text, hooks)
    end,
    is_question = function(interaction)
      return Permissions.question(interaction)
    end,
  })
  S.view.panel:set_views(S.view.chat, S.view.input)

  -- Re-attach the active session to the freshly created views.
  if S.sess.current then
    S.view.chat:set_session(S.sess.current)
    S.view.input:switch_session(S.sess.current.id, nil, S.sess.current)
  end

  -- Click regions in the winbar only respond when the mouse is enabled. Say so
  -- once instead of leaving the user with a toolbar that looks clickable but
  -- is not.
  if merged.ui.toolbar.placement ~= "off" and not S.view.click_hint_shown then
    S.view.click_hint_shown = true
    vim.schedule(function()
      if not vim.o.mouse:find("[anvi]") then
        vim.notify(
          string.format(
            "acp.nvim: 'mouse' is %q, so the model/mode toolbar is not clickable. "
              .. "Enable mouse support (e.g. set mouse=nvi) or use <M-m> / <M-b>.",
            vim.o.mouse
          ),
          vim.log.levels.INFO
        )
      end
    end)
  end
end

return M
