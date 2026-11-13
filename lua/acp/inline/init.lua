-- Inline transformations are normal prompt turns in the CURRENT session.
-- The existing prompt service owns task generations, cancellation and outbox
-- settlement. Only permissions for that one inline turn use a scoped policy.
local selection = require("acp.inline.selection")
local copy = require("acp.inline.copy")
local guard = require("acp.inline.guard")
local result = require("acp.inline.result")
local apply = require("acp.inline.apply")
local review = require("acp.inline.review")
local diff = require("acp.inline.diff_session")
local ui = require("acp.inline.ui")
local prompt_builder = require("acp.inline.prompt")
local M = {}
local current
local drafts = {}
vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(event)
    drafts[event.buf] = nil
  end,
})
local function state()
  return require("acp.controller").state()
end
local function notify(text, level)
  vim.notify("acp.nvim: " .. text, level or vim.log.levels.INFO)
end

local function live(inv)
  local s = state()
  return current == inv
    and s.client == inv.client
    and inv.client.generation == inv.generation
    and s.config == inv.config
    and s.runtime
    and s.runtime:owns(inv.session)
end
local function release(inv)
  copy.remove(inv.copy)
  if inv.group then
    pcall(vim.api.nvim_del_augroup_by_id, inv.group)
    inv.group = nil
  end
  -- Restore a mode the guard switched away from, but only if the session still
  -- exists and nobody changed the mode in the meantime.
  if inv.previous_mode and inv.session and inv.session.controls and inv.session.controls.mode then
    local current_mode = inv.session.controls.mode.current
    local target = inv.previous_mode
    inv.previous_mode = nil
    if current_mode ~= target then
      inv.session.current_mode = target
      for _, option in ipairs(inv.session.config_options or {}) do
        if option.category == "mode" then
          option.currentValue = target
        end
      end
      inv.session:refresh_controls()
      if inv.client and inv.client.set_mode then
        require("acp.async").run(function()
          inv.client:set_mode(inv.session.id, target)
        end)
      end
    end
  end
  if current == inv then
    current = nil
  end
end

---Whether a tool kind may run during an inline turn.
---
---`allow_commands` only covers `execute`. A delete or move is irreversible in a
---way a shell command usually is not, so those need `allow_kinds` explicitly.
---@param config table
---@param kind string|nil
---@return boolean
local function kind_allowed(config, kind)
  local inline = config.inline or {}
  for _, allowed in ipairs(inline.allow_kinds or {}) do
    if allowed == kind then
      return true
    end
  end
  if kind == "execute" then
    return inline.allow_commands == true
  end
  return false
end

-- Strict identity: NEVER authorize by basename/prefix or by state directory.
local function decide(inv, payload)
  local config = inv.config or state().config
  local tool = payload.tool_call or payload.toolCall or {}
  local allowed = not inv.cancelled and ({ read = true, search = true, think = true, fetch = true })[tool.kind] or false
  if not inv.cancelled and tool.kind == "edit" then
    local paths, unknown = {}, false
    for _, loc in ipairs(tool.locations or {}) do
      if type(loc.path) ~= "string" then
        unknown = true
      else
        paths[#paths + 1] = loc.path
      end
    end
    for _, content in ipairs(tool.content or {}) do
      if content.type == "diff" then
        if type(content.path) ~= "string" then
          unknown = true
        else
          paths[#paths + 1] = content.path
        end
      end
    end
    allowed = config.inline.allow_writes
    if not allowed and #paths > 0 and not unknown then
      allowed = true
      for _, path in ipairs(paths) do
        if not path:match("^/") and not path:match("^%a:[/\\]") then
          path = (inv.session and inv.session.cwd or vim.fn.getcwd()) .. "/" .. path
        end
        if not copy.is_copy_path(path, inv.copy) then
          allowed = false
          break
        end
      end
    end
  elseif not inv.cancelled and not allowed and tool.kind ~= "edit" then
    allowed = kind_allowed(config, tool.kind)
  end
  local wanted = allowed and "allow_once" or "reject_once"
  for _, option in ipairs(payload.options or {}) do
    if option.kind == wanted then
      return option.optionId
    end
  end
  return nil
end

function M.on_permission(inv, payload)
  local client = inv.client or state().client
  -- An allow_always option is not an acceptable substitute for allow_once.
  client:resolve_permission(payload.key, decide(inv, payload))
  return true
end

---Interaction policy: answer tool permissions owned by the running inline turn.
---
---Questions are left to the presenter: an elicitation or a question-shaped
---permission must reach the user, even mid-turn. Answering them automatically
---would let the agent pick its own answer, which is the opposite of asking.
---@param interaction table
---@return table|nil response
function M.policy(interaction)
  local inv = current
  if
    not inv
    or inv.phase ~= "running"
    or not live(inv)
    or interaction.session_id ~= inv.session.id
    or inv.session.turn ~= inv.turn
  then
    return nil
  end
  if interaction.type ~= "permission" then
    return nil
  end
  -- `Permissions.is_question` is the single place that recognises a question
  -- wrapped in a permission request (pi's select, Claude's ExitPlanMode).
  local permissions = require("acp.app.permissions")
  if permissions.question(interaction) then
    return nil
  end
  local choice = decide(inv, interaction.request or {})
  return { outcome = { outcome = choice and "selected" or "cancelled", optionId = choice } }
end

-- Observe notifications without stealing them from the chat reducer. ACP
-- notifications carry sessionId; local task/permission events carry session_id.
function M.handle(name, payload)
  local inv = current
  if not inv or inv.phase ~= "running" or not live(inv) then
    return false
  end
  if
    name == "permission_request"
    and payload
    and payload.session_id == inv.session.id
    and inv.session.turn == inv.turn
  then
    return M.on_permission(inv, payload)
  end
  return false
end

---Offer the three ways out after the agent wrote the source file directly.
---@param inv table
function M.offer_direct_write_recovery(inv)
  local bufnr = inv.selection.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    notify("the agent modified the source file directly; the buffer is gone", vim.log.levels.WARN)
    return
  end
  local path = inv.selection.path
  local verified = result.verify(inv.selection)
  require("acp.ui.picker").select({
    title = "The agent wrote the file directly. Keep which version?",
    items = {
      { label = "Reload from disk", description = "take the agent's write, discard the buffer", value = "reload" },
      {
        label = "Keep the buffer",
        description = verified and "leave your edits as they are; disk stays as the agent wrote it"
          or "the buffer changed too",
        value = "keep",
      },
      { label = "Show the difference", description = "compare the buffer with what is on disk", value = "diff" },
    },
    on_choice = function(choice)
      if choice == "reload" then
        local lines = guard.read_lines(path)
        if not lines then
          notify("unable to read the file from disk", vim.log.levels.WARN)
          return
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        notify("reloaded the file from disk")
      elseif choice == "diff" then
        local lines = guard.read_lines(path)
        if not lines then
          notify("unable to read the file from disk", vim.log.levels.WARN)
          return
        end
        local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local rows = require("acp.ui.diff").lines({
          { path = path or "", oldText = table.concat(current, "\n"), newText = table.concat(lines, "\n") },
        }, { cwd = inv.session and inv.session.cwd, width = math.max(20, vim.o.columns - 20) })
        local text = {}
        for _, row in ipairs(rows) do
          text[#text + 1] = row.text
        end
        vim.api.nvim_echo({ { table.concat(text, "\n"), "AcpMuted" } }, true, {})
      else
        notify("kept the buffer; the file on disk is unchanged")
      end
    end,
    on_cancel = function()
      notify("kept the buffer; the file on disk is unchanged")
    end,
  })
end

---Whether the agent's current mode edits without asking.
---
---Only the profile can answer this: the ACP mode id is agent-specific, and a
---client cannot infer "acceptEdits" semantics from the id alone in general.
---@param session table|nil
---@return boolean unsafe
---@return string|nil mode_id
function M.unsafe_mode(session)
  local control = session and session.controls and session.controls.mode
  if not control then
    return false, nil
  end
  return control.unsafe == true, control.current
end

---Ensure the agent is not in an auto-approving mode before an inline turn.
---
---`guard_mode` decides:
---   "off"    do nothing (the disk check remains the safety net)
---   "switch" temporarily move to the safest mode and restore it afterwards
---   "ask"    tell the user and continue; they can still stop the turn
---@param inv table
---@return boolean proceed
function M.guard_unsafe_mode(inv)
  local config = inv.config.inline
  if config.guard_mode == "off" then
    return true
  end
  local unsafe, mode_id = M.unsafe_mode(inv.session)
  if not unsafe then
    return true
  end
  local profile = inv.session.profile
  local label = mode_id or "the current mode"
  if config.guard_mode == "switch" then
    -- Pick a mode the agent reports as safe. There is no protocol name for
    -- "default", so prefer an entry that is neither auto-approving nor
    -- plan-only: switching into plan mode would change what the agent is
    -- willing to do, which is not what this guard is for.
    local control = inv.session.controls.mode
    local target
    for _, entry in ipairs(control.options or {}) do
      if not profile.unsafe_edit_mode(entry.value) and not profile.plan_mode(entry.value) then
        target = entry.value
        break
      end
    end
    if not target then
      notify(
        string.format("%s edits without asking and no neutral mode is available; continuing without switching", label),
        vim.log.levels.WARN
      )
      return true
    end
    inv.previous_mode = mode_id
    notify(string.format("switching to %s for this inline edit (was %s)", target, mode_id or "?"))
    -- Config options are the authoritative source for the derived controls, so
    -- both the option value and `current_mode` have to change together.
    inv.session.current_mode = target
    for _, option in ipairs(inv.session.config_options or {}) do
      if option.category == "mode" then
        option.currentValue = target
      end
    end
    inv.session:refresh_controls()
    local client = inv.client
    if client and client.set_mode then
      -- Fire and forget: the turn is about to start and a failure here only
      -- means the guard did not help, not that the edit cannot proceed.
      require("acp.async").run(function()
        client:set_mode(inv.session.id, target)
      end)
    end
    return true
  end
  notify(
    string.format(
      "%s edits files without asking; inline changes are still reviewed, and a direct write will be detected",
      label
    ),
    vim.log.levels.WARN
  )
  return true
end

function M.finish(inv, ok, response)
  if not live(inv) or inv.cancelled then
    return
  end
  if not ok then
    notify(
      "inline prompt failed: "
        .. (type(response) == "table" and (response.message or vim.inspect(response)) or tostring(response)),
      vim.log.levels.WARN
    )
    return
  end
  local reason = response and response.stopReason
  if reason and reason ~= "end_turn" then
    notify("inline result was not applied (" .. reason .. ")", vim.log.levels.WARN)
    return
  end
  if state().session ~= inv.session then
    notify("active session changed; inline result discarded", vim.log.levels.WARN)
    return
  end
  -- An agent that wrote the real file may already have applied (part of) the
  -- change. Applying the reviewed hunks on top would double it or conflict
  -- with the new disk content, so stop and let the user choose.
  local changed, why = guard.changed(inv.disk)
  if changed then
    notify(
      "the agent modified the source file directly (" .. (why or "disk changed") .. "); inline result not applied",
      vim.log.levels.WARN
    )
    M.offer_direct_write_recovery(inv)
    return
  end
  local verified, err = result.verify(inv.selection)
  if not verified then
    notify(err .. "; inline result discarded", vim.log.levels.WARN)
    return
  end
  local edited, read_err, eol = copy.read(inv.copy, inv.config.inline.max_copy_bytes)
  if not edited then
    notify(read_err, vim.log.levels.WARN)
    return
  end
  if eol ~= inv.selection.eol then
    notify("agent changed final-newline convention; inline result discarded", vim.log.levels.WARN)
    return
  end
  local plan = result.plan(inv.selection, edited)
  if plan.dropped > 0 then
    notify(string.format("dropped %d out-of-range change(s)", plan.dropped), vim.log.levels.WARN)
  end
  if #plan.hunks == 0 then
    notify("no editable changes; see the agent's reply in the current chat")
    return
  end
  local ft = vim.bo[inv.selection.bufnr].filetype
  local mode, source = review.resolve(ft, inv.config, inv.selection.bufnr)
  if inv.override then
    mode, source = inv.override, "one-off"
  end
  inv.review_mode, inv.review_source = mode, source
  if mode == "write" then
    local applied, why = apply.hunks(inv.selection.bufnr, inv.selection.original, plan.hunks)
    if not applied then
      notify(tostring(why), vim.log.levels.WARN)
      return
    end
    notify("inline applied · write (" .. source .. "); u to undo")
  else
    local opened, why = diff.open({
      bufnr = inv.selection.bufnr,
      original = inv.selection.original,
      selection = inv.selection,
      lines = plan.lines,
      config = inv.config,
      on_finish = function(accepted, total)
        notify(string.format("inline: accepted %d/%d hunks", accepted, total))
      end,
    })
    if not opened then
      notify(tostring(why), vim.log.levels.WARN)
    end
  end
end

function M.submit(inv, prompt)
  if current ~= inv or inv.phase ~= "prompt" then
    return false
  end
  if not live(inv) or state().session ~= inv.session then
    notify("session or connection changed", vim.log.levels.WARN)
    ui.close()
    return false
  end
  if inv.session.status ~= "idle" or inv.session.prompt_task or #inv.session.queue > 0 then
    notify("wait for the current session's turn and queue to finish", vim.log.levels.WARN)
    return false
  end
  local valid, why = result.verify(inv.selection)
  if not valid then
    notify(why .. "; reopen inline for a fresh selection", vim.log.levels.WARN)
    ui.close()
    return false
  end
  if not M.guard_unsafe_mode(inv) then
    ui.close()
    return false
  end
  local path, err = copy.create(inv.selection, inv.config)
  if not path then
    notify(err, vim.log.levels.WARN)
    return false
  end
  -- Remember the source file's state before the agent can touch it. An agent
  -- with an auto-approving mode, or one that ignores the copy instruction, can
  -- write the real file mid-turn; applying reviewed hunks on top would then
  -- discard or duplicate work.
  inv.disk = guard.capture(inv.selection.path)
  inv.copy, inv.prompt = path, prompt
  local request = prompt_builder.build(inv)
  if #request + 65536 > inv.config.transport.max_line_bytes then
    copy.remove(path)
    inv.copy = nil
    notify("inline prompt exceeds transport limit", vim.log.levels.WARN)
    return false
  end
  inv.phase = "running"
  inv.turn = inv.session.turn + 1
  drafts[inv.selection.bufnr] = nil
  ui.close("submit")
  -- The hook lives inside the existing scoped prompt task. It is never an
  -- independent coroutine which can outlive cancellation or reconfiguration.
  local accepted = require("acp.controller").send_inline(inv.session, request, {
    -- A generated inline prompt is mostly instructions; the transcript shows
    -- the user's request, not the whole envelope.
    local_user = { display_text = "inline: " .. (prompt ~= "" and prompt or "edit request") },
    on_result = function(ok, value)
      local success, problem = xpcall(function()
        M.finish(inv, ok, value)
      end, debug.traceback)
      if not success then
        notify("inline result rejected: " .. tostring(problem), vim.log.levels.ERROR)
      end
    end,
    on_finally = function()
      release(inv)
    end,
  })
  if not accepted then
    release(inv)
    return false
  end
  return true
end

function M.open(opts)
  opts = opts or {}
  if opts.review and opts.review ~= "diff" and opts.review ~= "write" then
    notify("inline review must be diff or write", vim.log.levels.WARN)
    return false
  end
  local s = state()
  if not s.config or not s.config.inline.enabled then
    notify("inline editing is disabled", vim.log.levels.WARN)
    return false
  end
  if not s.client or s.connection ~= "ready" or not s.session then
    notify("open an agent session before inline editing", vim.log.levels.WARN)
    return false
  end
  if current then
    notify("an inline operation is already open/running", vim.log.levels.WARN)
    return false
  end
  local buf = vim.api.nvim_get_current_buf()
  if diff.active(buf) then
    notify("finish the open inline review first", vim.log.levels.WARN)
    return false
  end
  local override
  if opts.mode then
    override = { mode = opts.mode, pos1 = opts.pos1, pos2 = opts.pos2 }
  end
  local sel, err = selection.capture(vim.api.nvim_get_current_win(), s.config, override)
  if not sel then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  local inv = {
    selection = sel,
    config = s.config,
    client = s.client,
    generation = s.client.generation,
    session = s.session,
    phase = "prompt",
    override = opts.review,
  }
  current = inv
  inv.group = vim.api.nvim_create_augroup("AcpInlineSource" .. sel.bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = inv.group,
    buffer = sel.bufnr,
    callback = function()
      M.stop()
      drafts[sel.bufnr] = nil
    end,
  })
  local mode = opts.review or review.resolve(sel.filetype, s.config, sel.bufnr)
  local agent = s.config.agent
  local opened = ui.open({
    source = sel.win,
    text = drafts[sel.bufnr],
    title = agent .. " · " .. mode,
    config = s.config,
    on_close = function(text)
      if current == inv and inv.phase == "prompt" then
        drafts[sel.bufnr] = text
        release(inv)
      end
    end,
    on_toggle_review = function()
      inv.override = (inv.override or mode) == "diff" and "write" or "diff"
      return agent .. " · " .. inv.override
    end,
    on_submit = function(text)
      M.submit(inv, text)
    end,
  })
  if not opened then
    release(inv)
    return false
  end
  return true
end

function M.stop(session)
  local inv = current
  if not inv or (session and (inv.session ~= session or inv.phase ~= "running")) then
    return false
  end
  if inv.phase == "prompt" then
    ui.close()
    release(inv)
    return true
  end
  inv.cancelled = true
  if live(inv) and inv.session.turn == inv.turn then
    inv.session:cancel_turn()
    inv.client:cancel(inv.session.id)
  end
  -- Keep the copy and reservation until prompt settlement; chat cannot overlap
  -- a cancelled request whose agent has not acknowledged cancellation yet.
  return true
end
function M.invalidate()
  local inv = current
  if inv then
    inv.cancelled = true
    if inv.phase == "running" and inv.client then
      pcall(inv.client.cancel, inv.client, inv.session.id)
    end
    ui.close()
    release(inv)
  end
  diff.close_all()
end
function M.is_active()
  return current ~= nil
end
function M.reset(buf)
  review.reset(buf or vim.api.nvim_get_current_buf())
end

---Exposed for tests: the tool-kind decision without a live session.
---@param inv table
---@param request table
---@return string|nil option_id
M._decide_for_test = function(inv, request)
  return decide(inv, request)
end

---Exposed for tests: the open inline turn, if any.
---@return table|nil
M._current = function()
  return current
end

return M
