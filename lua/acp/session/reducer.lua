-- Reduce ACP `session/update` payloads into session state.
local Log = require("acp.log")
local state = require("acp.session.state")

local M = {}

local function text_of(content)
  if type(content) ~= "table" then
    return ""
  end
  local t = content.type
  if t == "text" then
    return content.text or ""
  end
  if t == "resource" and type(content.resource) == "table" then
    local res = content.resource
    local uri = res.uri or ""
    if res.text then
      return string.format("\n\n`%s`\n```\n%s\n```\n", uri, res.text)
    end
    return string.format("[%s]", uri)
  end
  if t == "resource_link" then
    return string.format("[%s](%s)", content.name or content.uri or "", content.uri or "")
  end
  if t == "image" then
    return "[image]"
  end
  if t == "audio" then
    return "[audio]"
  end
  return ""
end

---Summary line for an embedded resource, preferring its URI over a text dump.
---@param resource table
---@return string
local function resource_summary(resource)
  local uri = type(resource.uri) == "string" and resource.uri or ""
  local lines = type(resource.text) == "string" and (select(2, resource.text:gsub("\n", "")) + 1) or nil
  if uri == "" then
    -- The protocol requires a URI, but a malformed resource must not render as
    -- an empty pair of backticks.
    return lines and string.format("[resource] (%d lines)", lines) or "[resource]"
  end
  if lines then
    return string.format("`%s` (%d lines)", uri, lines)
  end
  return string.format("`%s`", uri)
end

local function tool_content_text(content)
  local parts = {}
  for _, item in ipairs(content or {}) do
    -- A terminal the client created is rendered from its own buffer. Agents
    -- that never called `terminal/create` (pi) only send an id and put the
    -- output in `_meta`, so a bare id contributes no text. Pushing an empty
    -- string here made `detail` `""` instead of nil, which then looked like
    -- content when the card decided whether to fall back to `rawOutput`.
    if item.type ~= "terminal" then
      if item.type == "content" then
        local inner = item.content or {}
        if inner.type == "text" then
          parts[#parts + 1] = inner.text or ""
        elseif inner.type == "image" then
          parts[#parts + 1] = "[image]"
        elseif inner.type == "audio" then
          parts[#parts + 1] = "[audio]"
        end
      elseif item.type == "diff" then
        -- A diff with text is rendered as a diff; only the path-only form has
        -- to fall back to a summary line. Keeping it out of `detail` also
        -- means the collapsed preview shows the agent's own summary instead
        -- of a path.
        if item.oldText == nil and item.newText == nil and item.path then
          parts[#parts + 1] = string.format("diff: %s", item.path)
        end
      elseif item.type == "resource" and type(item.resource) == "table" then
        parts[#parts + 1] = resource_summary(item.resource)
      elseif item.type == "resource_link" then
        parts[#parts + 1] = string.format("[%s](%s)", item.name or item.uri or "", item.uri or "")
      end
    end
  end
  -- Empty means "nothing renderable", not "an empty summary". Callers use nil
  -- to decide whether a fallback (terminal output, rawOutput) is needed, and
  -- `""` would look like content that renders to nothing.
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

---Whether a tool call changes a file, and therefore deserves an open card.
---
---Only the tool kind and the update payload are consulted: the renderer decides
---what the diff actually looks like.
---@param block AcpBlock
---@return boolean
local function is_file_edit(block)
  local kind = block.tool_kind
  if kind == "edit" or kind == "write" or kind == "patch" then
    return true
  end
  for _, item in ipairs(block.content or {}) do
    if type(item) == "table" and item.type == "diff" then
      return true
    end
  end
  return false
end

---Whether the block already carries something a card could show.
---
---Auto-expanding on the very first `tool_call` (which often has an empty
---`rawInput`) would open an empty card and leave a caret pointing down at
---nothing. The next update with real content expands it instead.
---@param block AcpBlock
---@return boolean
local function has_payload(block)
  if block.detail ~= nil and block.detail ~= "" then
    return true
  end
  -- `detail` only holds the text summary, so it cannot decide alone: a diff,
  -- a client-rendered terminal buffer and `rawOutput` are all content with no
  -- summary. A content item that carries nothing at all (a bare `terminal` id)
  -- must not count, which is what this loop checks.
  for _, item in ipairs(block.content or {}) do
    if type(item) == "table" and item.type ~= "terminal" then
      return true
    end
  end
  if block.terminal_output and block.terminal_output ~= "" then
    return true
  end
  if block.raw_output ~= nil then
    return true
  end
  local input = block.raw_input
  if type(input) == "table" then
    for _, value in pairs(input) do
      if type(value) == "string" and value ~= "" then
        return true
      end
    end
  elseif type(input) == "string" then
    return input ~= ""
  end
  return false
end

---Open a file-edit card the first time its change shows up.
---
---A user who collapsed the card by hand keeps it collapsed; a session replayed
---from history or after a reconnect starts with every card closed, so reading
---old work does not unfold dozens of diffs.
---@param session AcpSessionState
---@param block AcpBlock
local function maybe_auto_expand(session, block)
  if block.toggled or session.historical or block.expanded then
    return
  end
  if is_file_edit(block) and has_payload(block) then
    block.expanded = true
  end
end

---Resolve the agent-specific tool name for a tool call.
---
---`toolCall.name` is the protocol field, but some agents only put the real
---name in their own `_meta` (Claude: `claudeCode.toolName`). The profile knows
---where; the reducer only stores the result.
---@param session table
---@param update table
---@return string|nil
local function profile_tool_name(session, update)
  local profile = session.profile
  if profile and profile.tool_name then
    local name = profile.tool_name(update)
    if type(name) == "string" and name ~= "" then
      return name
    end
  end
  return nil
end

---Terminal state carried in `_meta`, for agents that never call `terminal/create`.
---
---pi sends `terminal_info` / `terminal_output` / `terminal_exit` and no text
---content at all; Claude does the same once the client advertises
---`_meta.terminal_output`. `output` accumulates across deltas, so the reducer
---appends instead of replacing.
---@param update table
---@return table|nil state
local function terminal_meta(update)
  local meta = type(update) == "table" and update._meta or nil
  if type(meta) ~= "table" then
    return nil
  end
  local info = type(meta.terminal_info) == "table" and meta.terminal_info or nil
  local output = type(meta.terminal_output) == "table" and meta.terminal_output or nil
  local delta = type(meta.terminal_output_delta) == "table" and meta.terminal_output_delta or nil
  local exit = type(meta.terminal_exit) == "table" and meta.terminal_exit or nil
  if not (info or output or delta or exit) then
    return nil
  end
  return { info = info, output = output, delta = delta, exit = exit }
end

---Apply the terminal `_meta` state to a tool block.
---@param block AcpBlock
---@param update table
---@param tx table
local function apply_terminal_meta(block, update, tx)
  local state = terminal_meta(update)
  if not state then
    return
  end
  if state.info then
    tx:set(block, "terminal_id", state.info.terminal_id or state.info.terminalId or block.terminal_id)
    tx:set(block, "terminal_cwd", state.info.cwd or block.terminal_cwd)
    tx:set(block, "terminal_command", state.info.command or block.terminal_command)
  end
  -- `output` is a full snapshot; `delta` is an append. Agents use one or the
  -- other, and both may arrive in the same update.
  if state.output and type(state.output.data) == "string" then
    tx:set(block, "terminal_output", state.output.data)
  elseif state.delta and type(state.delta.data) == "string" then
    tx:set(block, "terminal_output", (block.terminal_output or "") .. state.delta.data)
  end
  if state.output then
    tx:set(block, "terminal_id", state.output.terminal_id or block.terminal_id)
  elseif state.delta then
    tx:set(block, "terminal_id", state.delta.terminal_id or block.terminal_id)
  end
  if state.exit then
    tx:set(block, "terminal_exit", state.exit.exit_code or state.exit.exitCode)
    tx:set(block, "terminal_signal", state.exit.signal)
    tx:set(block, "terminal_id", state.exit.terminal_id or block.terminal_id)
  end
end

---Ask the agent profile what an update carries beyond the protocol core.
---@param session table
---@param update table
---@return table|nil
local function profile_meta(session, update)
  local profile = session.profile
  if not profile or not profile.update_meta then
    return nil
  end
  local seen = profile.update_meta(update, session)
  return type(seen) == "table" and seen or nil
end

local function merge_list(current, incoming)
  if incoming == nil then
    return current
  end
  return incoming
end

---Undo journal for one update. Reducers mutate state in place; a failure
---halfway used to leave a block with the new title but the old status. Every
---write goes through here so a failed update can be dropped whole without
---losing block identity (the UI holds references to blocks).
local Tx = {}
Tx.__index = Tx

function Tx.new()
  return setmetatable({ log = {}, slots = {}, blocks = {}, order = {}, added = {}, added_list = {} }, Tx)
end

---@param tbl table
---@param key any
---@param value any
function Tx:set(tbl, key, value)
  local slots = self.slots[tbl]
  if not slots then
    slots = {}
    self.slots[tbl] = slots
  end
  local record = slots[key]
  if not record then
    local present = rawget(tbl, key) ~= nil
    record = { present = present, value = rawget(tbl, key) }
    slots[key] = record
    self.log[#self.log + 1] = { tbl = tbl, key = key, record = record }
  end
  tbl[key] = value
end

---Copy a block the first time it is mutated in this transaction.
---@param block table|nil
function Tx:block(block)
  if not block or self.blocks[block] then
    return
  end
  -- A shallow copy plus a length marker for the streaming chunk buffer is
  -- enough: later chunks truncate back to that length on rollback. Deep-copying
  -- the whole message on every chunk would reintroduce quadratic streaming.
  local fields = {}
  for key, value in pairs(block) do
    fields[key] = value
  end
  local parts = rawget(block, "_parts")
  self.blocks[block] = { fields = fields, mt = getmetatable(block), parts = parts and { parts, #parts } or nil }
  self.order[#self.order + 1] = block
end

---Record a block appended by this transaction.
---@param block table
function Tx:add(block)
  if not self.added[block] then
    self.added[block] = true
    self.added_list[#self.added_list + 1] = block
  end
end

function Tx:rollback(session)
  for i = #self.log, 1, -1 do
    local entry = self.log[i]
    if entry.record.present then
      entry.tbl[entry.key] = entry.record.value
    else
      entry.tbl[entry.key] = nil
    end
  end
  -- Appended blocks are always new; the journal restored the old arrays, so
  -- drop them from both the transcript and the tool index.
  if #self.added_list > 0 then
    local kept = {}
    for _, block in ipairs(session.blocks) do
      if not self.added[block] then
        kept[#kept + 1] = block
      end
    end
    session.blocks = kept
    for id, block in pairs(session.tools) do
      if self.added[block] then
        session.tools[id] = nil
      end
    end
  end
  for _, block in ipairs(self.order) do
    local snapshot = self.blocks[block]
    for key in pairs(block) do
      if snapshot.fields[key] == nil then
        block[key] = nil
      end
    end
    for key, value in pairs(snapshot.fields) do
      block[key] = value
    end
    if snapshot.parts then
      local parts, count = snapshot.parts[1], snapshot.parts[2]
      for i = #parts, count + 1, -1 do
        parts[i] = nil
      end
    end
    setmetatable(block, snapshot.mt)
  end
end

---Apply one update to a session.
---@param session AcpSessionState
---@param update table
---@param tx table|nil mutation journal
---@return boolean changed
local function reduce(session, update, tx)
  if type(update) ~= "table" or type(update.sessionUpdate) ~= "string" then
    Log.warn("ignoring malformed session update")
    return false
  end
  local kind = update.sessionUpdate

  -- Existing tools/plans mutate in place and do not pass through append().
  if kind == "tool_call" or kind == "tool_call_update" or kind == "plan" then
    session:finish_thought(nil, tx)
  end

  if kind == "user_message_chunk" then
    local text = text_of(update.content)
    if text ~= "" then
      session:user_chunk(text, update.messageId, tx)
      return true
    end
    return false
  end

  if kind == "agent_message_chunk" then
    local text = text_of(update.content)
    if text == "" then
      return false
    end
    local block = session:append_text("agent", text, update.messageId, tx)
    local seen = profile_meta(session, update)
    tx:set(block, "child", seen and seen.child or nil)
    return true
  end

  if kind == "agent_thought_chunk" then
    local text = text_of(update.content)
    if text == "" then
      return false
    end
    session:append_text("thought", text, update.messageId, tx)
    return true
  end

  if kind == "tool_call" then
    local id = update.toolCallId
    if id == nil then
      return false
    end
    local existing = session.tools[id]
    local block = existing
    if not block then
      block = session:append({
        id = "tool:" .. tostring(id),
        kind = "tool",
        text = "",
        title = update.title or "",
        name = update.name,
        tool_name = profile_tool_name(session, update),
        tool_kind = update.kind,
        status = update.status or "pending",
        locations = update.locations,
        content = update.content,
        raw_input = update.rawInput,
        raw_output = update.rawOutput,
        expanded = false,
        child = (function()
          local seen = profile_meta(session, update)
          return seen and seen.child or nil
        end)(),
      }, tx)
      apply_terminal_meta(block, update, tx)
      tx:set(session.tools, id, block)
    end
    tx:block(block)
    block.title = update.title or block.title
    block.name = merge_list(block.name, update.name)
    block.tool_name = profile_tool_name(session, update) or block.tool_name
    block.tool_kind = update.kind or block.tool_kind
    block.status = update.status or block.status
    block.locations = merge_list(block.locations, update.locations)
    block.content = merge_list(block.content, update.content)
    block.raw_input = merge_list(block.raw_input, update.rawInput)
    block.raw_output = merge_list(block.raw_output, update.rawOutput)
    apply_terminal_meta(block, update, tx)
    if update.content ~= nil or block.detail == nil then
      block.detail = tool_content_text(block.content)
    end
    maybe_auto_expand(session, block)
    return true
  end

  if kind == "tool_call_update" then
    local id = update.toolCallId
    if not id then
      -- An update without an id cannot be matched to a tool call; creating a
      -- placeholder would pollute the transcript with a bogus `tool:nil` row.
      Log.debug("dropping tool_call_update without toolCallId")
      return false
    end
    local block = session.tools[id]
    if not block then
      -- Update for an unknown tool call: create a placeholder so progress is not lost.
      block = session:append({
        id = "tool:" .. tostring(id),
        kind = "tool",
        text = "",
        title = update.title or tostring(id),
        status = update.status or "pending",
        expanded = false,
      }, tx)
      tx:set(session.tools, id, block)
    end
    tx:block(block)
    if update.title then
      block.title = update.title
    end
    if update.name then
      block.name = update.name
    end
    local tool_name = profile_tool_name(session, update)
    if tool_name then
      block.tool_name = tool_name
    end
    if update.kind then
      block.tool_kind = update.kind
    end
    if update.status then
      block.status = update.status
    end
    block.locations = merge_list(block.locations, update.locations)
    block.content = merge_list(block.content, update.content)
    block.raw_input = merge_list(block.raw_input, update.rawInput)
    block.raw_output = merge_list(block.raw_output, update.rawOutput)
    apply_terminal_meta(block, update, tx)
    if update.content ~= nil or block.detail == nil then
      block.detail = tool_content_text(block.content)
    end
    maybe_auto_expand(session, block)
    return true
  end

  if kind == "plan" then
    -- Plans can be interspersed with agent chunks, and agents often restate
    -- the whole list after every step. Reuse the plan of the current turn even
    -- when messages arrived in between. The turn number is the boundary: a new
    -- turn starts a new plan, whatever block kinds are in between.
    local active
    for i = #session.blocks, 1, -1 do
      local candidate = session.blocks[i]
      if candidate.kind == "plan" then
        if candidate.turn == session.turn then
          active = candidate
        end
        break
      end
    end
    if active then
      tx:block(active)
      active.entries = update.entries or {}
      return true
    end
    session:append({
      id = "plan:" .. session.turn,
      kind = "plan",
      text = "",
      entries = update.entries or {},
      turn = session.turn,
    }, tx)
    return true
  end

  if kind == "available_commands_update" then
    local commands = update.availableCommands or {}
    -- Re-rendering for an identical list is pure work; the winbar and
    -- transcript only care about the difference.
    if vim.deep_equal(session.commands, commands) then
      return false
    end
    tx:set(session, "commands", commands)
    return true
  end

  if kind == "current_mode_update" then
    if session.current_mode == update.currentModeId then
      return false
    end
    tx:set(session, "current_mode", update.currentModeId)
    -- Config options are authoritative, so a mode change must also update the
    -- value the controls were derived from. ExitPlanMode relies on this: the
    -- agent announces the new mode without a set_mode response.
    for _, option in ipairs(session.config_options or {}) do
      if option.category == "mode" then
        tx:block(nil)
        tx:set(option, "currentValue", update.currentModeId)
      end
    end
    session:refresh_controls(tx)
    return true
  end

  if kind == "config_option_update" then
    local options = update.configOptions or {}
    if vim.deep_equal(session.config_options, options) then
      return false
    end
    tx:set(session, "config_options", options)
    session:refresh_controls(tx)
    return true
  end

  if kind == "session_info_update" then
    if update.title then
      tx:set(session, "title", update.title)
    end
    -- `updatedAt` (and `createdAt`) are ISO-8601 strings from the agent; the
    -- session picker shows them so a replayed session is identifiable.
    if type(update.updatedAt) == "string" and update.updatedAt ~= "" then
      tx:set(session, "updated_at", update.updatedAt)
    end
    -- Agent-specific metadata is read by the profile: the reducer knows what
    -- to do with a retry marker or a compaction marker, not where an agent
    -- happens to store them.
    local meta_seen = profile_meta(session, update)
    if type(meta_seen) == "table" and meta_seen.retry ~= nil then
      tx:set(session, "retry", meta_seen.retry)
      return true
    end
    local marker = type(meta_seen) == "table" and meta_seen.compaction or nil
    if marker then
      tx:set(session, "compaction", marker)
      if marker.status == "started" then
        session:append({
          id = "compaction:" .. tostring(marker.messageId),
          kind = "compaction",
          text = "",
          status = "in_progress",
        }, tx)
      else
        local found = false
        for _, b in ipairs(session.blocks) do
          if b.kind == "compaction" and b.status == "in_progress" then
            tx:block(b)
            b.status = marker.status
            found = true
          end
        end
        if not found then
          session:append({
            id = "compaction:" .. tostring(marker.messageId),
            kind = "compaction",
            text = "",
            status = marker.status,
          }, tx)
        end
      end
      return true
    end
    return update.title ~= nil or type(update.updatedAt) == "string" and update.updatedAt ~= ""
  end

  if kind == "usage_update" then
    local usage = { used = update.used, size = update.size, cost = update.cost }
    if vim.deep_equal(session.usage, usage) then
      return false
    end
    tx:set(session, "usage", usage)
    return true
  end

  if kind == "notice" then
    session:append({
      id = state.next_id("notice"),
      kind = "notice",
      text = update.description or "",
      title = update.title,
      severity = update.severity,
    }, tx)
    return true
  end

  if kind == "compaction_update" then
    local id = update.compactionId
    local block
    for _, b in ipairs(session.blocks) do
      if b.kind == "compaction" and b.compaction_id == id then
        block = b
        break
      end
    end
    if not block then
      block = session:append({
        id = "compaction:" .. tostring(id),
        kind = "compaction",
        text = "",
        status = update.status,
        compaction_id = id,
      }, tx)
    end
    tx:block(block)
    block.status = update.status or block.status
    block.error = update.error or block.error
    if update.summary ~= nil then
      if type(update.summary) == "table" and #update.summary > 0 then
        local parts = {}
        for _, item in ipairs(update.summary) do
          parts[#parts + 1] = text_of(item)
        end
        block.text = table.concat(parts, "\n")
      else
        block.text = ""
      end
    end
    return true
  end

  if kind == "compaction_summary_chunk" then
    local id = update.compactionId
    local block
    for _, b in ipairs(session.blocks) do
      if b.kind == "compaction" and b.compaction_id == id then
        block = b
        break
      end
    end
    if not block then
      block = session:append({
        id = "compaction:" .. tostring(id),
        kind = "compaction",
        text = "",
        status = "in_progress",
        compaction_id = id,
      }, tx)
    end
    tx:block(block)
    state.append_block_text(block, text_of(update.content))
    return true
  end

  Log.debug("unhandled session update kind: %s", kind)
  return false
end

function M.apply(session, update)
  local tx = Tx.new()
  local ok, changed = pcall(reduce, session, update, tx)
  if not ok then
    tx:rollback(session)
    local kind = type(update) == "table" and update.sessionUpdate or "?"
    local id = type(update) == "table" and update.toolCallId or nil
    Log.error("dropping failed session update %s%s: %s", kind, id and (" (" .. tostring(id) .. ")") or "", changed)
    return false
  end
  if not changed then
    -- "No change" branches can still have side effects (closing a thought).
    -- Roll them back too so the result is one atomic unit.
    tx:rollback(session)
    return false
  end
  local kind = update.sessionUpdate
  if kind == "tool_call" or kind == "tool_call_update" then
    session:touch(
      session.tools[update.toolCallId],
      update.content ~= nil
        or update.rawInput ~= nil
        or update.rawOutput ~= nil
        or update.title ~= nil
        or update.name ~= nil
        or update.locations ~= nil
    )
  elseif kind == "plan" or kind == "compaction_update" or kind == "compaction_summary_chunk" then
    for i = #session.blocks, 1, -1 do
      local block = session.blocks[i]
      if
        (kind == "plan" and block.kind == "plan")
        or (block.kind == "compaction" and block.compaction_id == update.compactionId)
      then
        session:touch(block)
        break
      end
    end
  elseif kind == "session_info_update" and session.compaction ~= nil then
    -- A compaction marker was accepted for this update; repaint the card so a
    -- changed status is visible even when no block was appended.
    for _, block in ipairs(session.blocks) do
      if block.kind == "compaction" then
        session:touch(block, false)
      end
    end
  end
  return true
end

return M
