-- Inline editing: prompt at a cursor or selection, agent edits a private copy,
-- the result is filtered to the editable range and returned to the buffer.
--
-- One request runs at a time. A dedicated ACP session keeps it away from the
-- chat queue, and the copy is the only file the agent may write.
local selection_mod = require("acp.inline.selection")
local copy_mod = require("acp.inline.copy")
local result_mod = require("acp.inline.result")
local apply_mod = require("acp.inline.apply")
local review_mod = require("acp.inline.review")
local diff_session = require("acp.inline.diff_session")
local ui = require("acp.inline.ui")

local M = {}
local current -- the one active invocation

local ALLOWED_KINDS = { read = true, search = true, think = true, fetch = true }

local function notify(message, level)
  vim.notify("acp.nvim: " .. message, level or vim.log.levels.INFO)
end

local function controller()
  return require("acp.controller").state()
end

local function cfg()
  local S = controller()
  return S.config
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

local function cleanup(invocation)
  if invocation.copy then
    copy_mod.remove(invocation.copy)
  end
  invocation.copy = nil
  if current == invocation then
    current = nil
  end
end

---@param invocation table
local function fail(invocation, message)
  notify(message, vim.log.levels.WARN)
  cleanup(invocation)
end

---Prompt text: the copy path, the editable scope, and nearby context.
---@param invocation table
---@param config table
---@return string
local function build_prompt(invocation, config)
  local selection = invocation.selection
  local lines = selection.original
  local ranges = selection.ranges
  local first, last = ranges[1].start_row, ranges[#ranges].end_row
  local budget = config.inline.context_bytes
  local before_start = math.max(0, first - 1)
  local before = {}
  local used = 0
  for row = first - 1, 0, -1 do
    local line = lines[row + 1] or ""
    if used + #line + 1 > budget / 2 then
      break
    end
    used = used + #line + 1
    table.insert(before, 1, line)
    before_start = row
  end
  local after = {}
  used = 0
  for row = last + 1, #lines - 1 do
    local line = lines[row + 1] or ""
    if used + #line + 1 > budget / 2 then
      break
    end
    used = used + #line + 1
    after[#after + 1] = line
  end

  local function numbered(from, list)
    local out = {}
    for i, line in ipairs(list) do
      out[#out + 1] = string.format("%6d\t%s", from + i, line)
    end
    return table.concat(out, "\n")
  end

  local marker_start = invocation.insertion and "<insert_here></insert_here>" or "<rewrite_this>"
  local marker_end = invocation.insertion and "" or "</rewrite_this>"
  local document = {}
  if #before > 0 then
    document[#document + 1] = numbered(before_start, before)
  end
  document[#document + 1] = marker_start
  if not invocation.insertion then
    document[#document + 1] = table.concat(
      vim.tbl_map(function(row)
        return string.format("%6d\t%s", row + 1, (lines[row + 1] or ""))
      end, vim.fn.range(first, last)),
      "\n"
    )
  end
  document[#document + 1] = marker_end
  if #after > 0 then
    document[#document + 1] = numbered(last + 2, after)
  end

  local scope
  if invocation.insertion then
    scope = string.format("Insert at the <insert_here> marker on line %d. Do not rewrite other lines.", first + 1)
  else
    scope = string.format(
      "You may only change lines %d-%d. Edits elsewhere will be reverted. Leave surrounding code untouched.",
      first + 1,
      last + 1
    )
  end

  return table.concat({
    string.format(
      "The Neovim buffer has been copied to `%s`. Edit that file in place, and only that file. Do not run commands.",
      invocation.copy
    ),
    scope,
    "Keep the file's existing indentation and line endings.",
    "The <document> below is context; line numbers are annotations, not file content.",
    "<document>",
    table.concat(document, "\n"),
    "</document>",
    "User request:",
    invocation.prompt,
  }, "\n\n")
end

---@param invocation table
local function stream_text(invocation, update)
  local content = update.content
  if type(content) ~= "table" then
    return
  end
  if content.type == "text" and type(content.text) == "string" then
    invocation.reply[#invocation.reply + 1] = content.text
  end
end

---Auto-answer a permission request. Returns true when consumed.
---@param invocation table
---@param payload table
---@return boolean
function M.on_permission(invocation, payload)
  local S = controller()
  local config = S.config
  if not config then
    return false
  end
  local tool = payload.tool_call or {}
  local allowed = false
  if ALLOWED_KINDS[tool.kind] then
    allowed = true
  elseif tool.kind == "edit" then
    local paths = {}
    for _, location in ipairs(tool.locations or {}) do
      paths[#paths + 1] = location.path
    end
    for _, item in ipairs(tool.content or {}) do
      if item.type == "diff" then
        paths[#paths + 1] = item.path
      end
    end
    if config.inline.allow_writes then
      allowed = true
    elseif #paths > 0 then
      allowed = true
      for _, path in ipairs(paths) do
        if not copy_mod.is_copy_path(path, config) and path ~= invocation.copy then
          allowed = false
          break
        end
      end
    end
  elseif config.inline.allow_commands then
    allowed = true
  end

  local wanted = allowed and "allow_once" or "reject_once"
  local choice
  for _, option in ipairs(payload.options or {}) do
    if option.kind == wanted then
      choice = option.optionId
      break
    end
  end
  if not choice then
    for _, option in ipairs(payload.options or {}) do
      if allowed and option.kind == "allow_always" then
        choice = option.optionId
      end
    end
  end
  S.client:resolve_permission(payload.key, choice)
  if invocation.on_status then
    invocation.on_status(allowed and "allow" or "reject", tool.kind or "tool")
  end
  return true
end

---Handle an event that belongs to the active inline session.
---@param name string
---@param payload table
---@return boolean consumed
function M.handle(name, payload)
  if not current or not payload or payload.session_id ~= current.session_id then
    return false
  end
  if name == "permission_request" then
    return M.on_permission(current, payload)
  end
  M.on_event(current, name, payload)
  return true
end

---@param invocation table
function M.on_event(invocation, name, payload)
  if name == "session_update" then
    local update = payload.update or {}
    if update.sessionUpdate == "agent_message_chunk" then
      stream_text(invocation, update)
    elseif update.sessionUpdate == "tool_call" then
      invocation.on_status("tool", update.title or update.kind or "tool")
    end
  elseif name == "prompt_finished" then
    M.finish(invocation, payload.ok, payload.result)
  end
end

---@param invocation table
local function show_reply(text)
  local lines = vim.split(text, "\n", { plain = true })
  local width = math.max(30, math.min(80, vim.o.columns - 8))
  local height = math.max(1, math.min(#lines, math.max(1, vim.o.lines - 8)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ACP Inline reply ",
  })
  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
end

---@param invocation table
---@param ok boolean
---@param result any
function M.finish(invocation, ok, result)
  if current ~= invocation then
    return
  end
  local S = controller()
  local config = S.config
  if config and S.client then
    S.client:cancel_permissions(invocation.session_id)
  end
  if not ok then
    local raw = type(result) == "table" and (result.message or vim.inspect(result)) or tostring(result)
    return fail(invocation, "inline prompt failed: " .. raw)
  end
  if invocation.stopped then
    return cleanup(invocation)
  end
  local selection = invocation.selection
  if not valid_buf(selection.bufnr) then
    return fail(invocation, "the buffer was closed; the result was discarded")
  end
  local edited = copy_mod.read(invocation.copy)
  if not edited then
    return fail(invocation, "the agent removed the inline copy")
  end

  local hunks = result_mod.hunks(selection.original, edited)
  if #hunks == 0 then
    local reply = vim.trim(table.concat(invocation.reply))
    cleanup(invocation)
    if reply ~= "" then
      return show_reply(reply)
    end
    return notify("the agent returned no changes")
  end
  local kept, dropped = result_mod.keep_editable(selection, hunks)
  if #kept == 0 then
    cleanup(invocation)
    return notify(string.format("all %d change(s) were outside the selection", dropped), vim.log.levels.WARN)
  end
  local conflict, reason = result_mod.verify(selection)
  if not conflict then
    cleanup(invocation)
    return notify(reason .. "; the result was discarded", vim.log.levels.WARN)
  end
  if dropped > 0 then
    invocation.on_status("warn", string.format("dropped %d out-of-range change(s)", dropped))
  end

  local new_lines = result_mod.apply_hunks(selection.original, kept)
  local mode = invocation.review or (review_mod.resolve(selection.filetype, config, selection.bufnr))
  if mode == "write" then
    local first = kept[1] and kept[1].new_start or 0
    cleanup(invocation)
    if not apply_mod.write(selection.bufnr, new_lines, first) then
      return notify("unable to write the inline result", vim.log.levels.WARN)
    end
    notify("inline change applied; u undoes it, g1 in a diff makes it permanent")
    return
  end

  cleanup(invocation)
  local diff_hunks = {}
  for _, hunk in ipairs(kept) do
    diff_hunks[#diff_hunks + 1] = {
      start_row = hunk.new_start,
      end_row = hunk.new_start + #hunk.new_lines - 1,
      new_lines = hunk.new_lines,
      original = hunk.old_lines,
    }
  end
  local win = vim.fn.bufwinid(selection.bufnr)
  if win ~= -1 and win ~= 0 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
  local opened = diff_session.open({
    bufnr = selection.bufnr,
    lines = new_lines,
    hunks = diff_hunks,
    on_status = function(index, total)
      notify(string.format("review hunk %d/%d", index + 1, total))
    end,
    on_finish = function(accepted, total)
      if accepted == 0 then
        notify("inline change rejected")
      else
        notify(string.format("inline change applied (%d/%d hunks)", accepted, total))
      end
    end,
  })
  if not opened then
    notify("unable to open the inline diff", vim.log.levels.WARN)
  end
end

---Start an inline prompt for the current window.
---@param opts {review?: "diff"|"write"}|nil
function M.open(opts)
  local S = controller()
  local config = S.config
  if not config or config.inline.enabled == false then
    return notify("inline editing is disabled (inline.enabled)", vim.log.levels.WARN)
  end
  if not S.client or S.connection ~= "ready" then
    return notify("no agent is running", vim.log.levels.WARN)
  end
  if current then
    return notify("an inline prompt is already running" .. (ui.is_open() and "" or " (a result is waiting)"))
  end
  if require("acp.inline.diff_session").active(vim.api.nvim_get_current_buf()) then
    return notify("finish or reject the open inline review first")
  end
  local win = vim.api.nvim_get_current_win()
  local override
  if opts and opts.mode then
    override = { mode = opts.mode, pos1 = opts.pos1, pos2 = opts.pos2 }
  end
  local selection, err = selection_mod.capture(win, config, override)
  if not selection then
    return notify(err or "nothing to edit")
  end
  local review = opts and opts.review
  if review then
    -- One-off override: remember it for this invocation only.
    local was = config.inline.review.mode
    config.inline.review.mode = review
    vim.schedule(function()
      config.inline.review.mode = was
    end)
  end
  local mode = select(1, review_mod.resolve(selection.filetype, config, selection.bufnr))
  local invocation = {
    selection = selection,
    review = mode,
    reply = {},
    on_status = function(kind, text)
      if ui.is_open() then
        ui.set_status(kind == "mode" and ("review " .. text) or (text or kind))
      end
    end,
  }
  current = invocation

  local opened = ui.open({
    source = win,
    row = selection.ranges[1].start_row,
    title = string.format("%s · %s", selection.filetype ~= "" and selection.filetype or "text", mode),
    on_close = function()
      if current == invocation and not invocation.session_id then
        cleanup(invocation)
      end
    end,
    on_toggle_review = function()
      invocation.review = invocation.review == "diff" and "write" or "diff"
      return "review " .. invocation.review
    end,
    on_submit = function(text)
      M.submit(invocation, text)
    end,
  })
  if not opened then
    cleanup(invocation)
    return notify("unable to open the inline prompt")
  end
end

---@param invocation table
---@param prompt string
function M.submit(invocation, prompt)
  if current ~= invocation then
    return
  end
  local S = controller()
  local config = S.config
  local selection = invocation.selection
  local copy, err = copy_mod.create(selection, config)
  if not copy then
    ui.close()
    return fail(invocation, err)
  end
  invocation.copy = copy
  invocation.prompt = prompt
  invocation.insertion = selection.insertion == true

  ui.close()
  if vim.api.nvim_win_is_valid(selection.win) then
    pcall(vim.api.nvim_set_current_win, selection.win)
  end

  -- Protocol requests must yield, so the whole request lives in a coroutine.
  require("acp.async").run(function()
    local cwd = S.session and S.session.cwd or vim.fn.getcwd()
    local ok, created = S.client:new_session(cwd)
    if not ok or type(created) ~= "table" or type(created.sessionId) ~= "string" then
      return fail(invocation, "unable to open an inline session")
    end
    invocation.session_id = created.sessionId
    selection.changedtick = vim.api.nvim_buf_get_changedtick(selection.bufnr)
    notify("inline: agent is editing" .. (invocation.review == "write" and " (direct)" or ""))
    local sent, sent_err = S.client:prompt(invocation.session_id, {
      { type = "text", text = build_prompt(invocation, config) },
    })
    if current ~= invocation then
      return
    end
    if not sent then
      local raw = type(sent_err) == "table" and (sent_err.message or vim.inspect(sent_err)) or tostring(sent_err)
      return fail(invocation, "inline prompt failed: " .. raw)
    end
  end, function(problem)
    if current == invocation then
      fail(invocation, tostring(problem))
    end
  end)
end

---Stop the active prompt, if any.
function M.stop()
  if not current then
    return false
  end
  local invocation = current
  invocation.stopped = true
  local S = controller()
  if S.client and invocation.session_id then
    S.client:cancel(invocation.session_id)
  end
  ui.close()
  cleanup(invocation)
  return true
end

---@return boolean
function M.is_active()
  return current ~= nil
end

---Clear the buffer's always-accept state.
---@param bufnr integer|nil
function M.reset(bufnr)
  review_mod.reset(bufnr or vim.api.nvim_get_current_buf())
end

return M
