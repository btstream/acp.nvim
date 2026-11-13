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
  return ""
end

local function tool_content_text(content)
  local parts = {}
  for _, item in ipairs(content or {}) do
    if item.type == "content" then
      local inner = item.content or {}
      if inner.type == "text" then
        parts[#parts + 1] = inner.text or ""
      elseif inner.type == "image" then
        parts[#parts + 1] = "[image]"
      end
    elseif item.type == "diff" then
      -- A diff with text is rendered as a diff; only the path-only form has to
      -- fall back to a summary line. Keeping it out of `detail` also means the
      -- collapsed preview shows the agent's own summary instead of a path.
      if item.oldText == nil and item.newText == nil and item.path then
        parts[#parts + 1] = string.format("diff: %s", item.path)
      end
    elseif item.type == "terminal" then
      parts[#parts + 1] = string.format("terminal: %s", item.terminalId or "?")
    end
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
  if #(block.content or {}) > 0 then
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
    tx:set(block, "child", update._meta and update._meta["opencode/child-session"] or nil)
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
        tool_kind = update.kind,
        status = update.status or "pending",
        locations = update.locations,
        content = update.content,
        raw_input = update.rawInput,
        raw_output = update.rawOutput,
        expanded = false,
        child = update._meta and update._meta["opencode/child-session"] or nil,
      }, tx)
      tx:set(session.tools, id, block)
    end
    tx:block(block)
    block.title = update.title or block.title
    block.name = merge_list(block.name, update.name)
    block.tool_kind = update.kind or block.tool_kind
    block.status = update.status or block.status
    block.locations = merge_list(block.locations, update.locations)
    block.content = merge_list(block.content, update.content)
    block.raw_input = merge_list(block.raw_input, update.rawInput)
    block.raw_output = merge_list(block.raw_output, update.rawOutput)
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
    if update.content ~= nil or block.detail == nil then
      block.detail = tool_content_text(block.content)
    end
    maybe_auto_expand(session, block)
    return true
  end

  if kind == "plan" then
    -- Plans can be interspersed with agent chunks, so looking only at the last
    -- block appended a fresh plan block on every update and grew without bound.
    -- Reuse the active plan of the current turn instead.
    local active
    for i = #session.blocks, 1, -1 do
      local candidate = session.blocks[i]
      if candidate.kind == "plan" then
        active = candidate
        break
      end
      if candidate.kind == "user" or candidate.kind == "agent" then
        break
      end
    end
    if active then
      tx:block(active)
      active.entries = update.entries or {}
      return true
    end
    session:append({ id = "plan:" .. session.turn, kind = "plan", text = "", entries = update.entries or {} }, tx)
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
    return true
  end

  if kind == "config_option_update" then
    local options = update.configOptions or {}
    if vim.deep_equal(session.config_options, options) then
      return false
    end
    tx:set(session, "config_options", options)
    return true
  end

  if kind == "session_info_update" then
    if update.title then
      tx:set(session, "title", update.title)
    end
    local meta = update._meta or {}
    if meta["opencode/retry"] ~= nil then
      tx:set(session, "retry", meta["opencode/retry"])
      return true
    end
    if meta["opencode/compaction"] then
      local marker = meta["opencode/compaction"]
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
    return update.title ~= nil
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
      id = "notice:" .. tostring(#session.blocks),
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
  elseif kind == "session_info_update" and update._meta and update._meta["opencode/compaction"] then
    for _, block in ipairs(session.blocks) do
      if block.kind == "compaction" then
        session:touch(block, false)
      end
    end
  end
  return true
end

return M
