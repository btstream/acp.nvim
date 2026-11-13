-- Inline transformations are normal prompt turns in the CURRENT session.
-- The existing prompt service owns task generations, cancellation and outbox
-- settlement. Only permissions for that one inline turn use a scoped policy.
local selection = require("acp.inline.selection")
local copy = require("acp.inline.copy")
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
  if current == inv then
    current = nil
  end
end

-- Strict identity: NEVER authorize by basename/prefix or by state directory.
local function decide(inv, payload)
  local config = inv.config or state().config
  local tool = payload.tool_call or {}
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
    allowed = config.inline.allow_commands
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

---Interaction policy: answer permissions owned by the running inline turn.
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
  local path, err = copy.create(inv.selection, inv.config)
  if not path then
    notify(err, vim.log.levels.WARN)
    return false
  end
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
return M
