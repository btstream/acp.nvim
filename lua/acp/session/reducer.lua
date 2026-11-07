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
      parts[#parts + 1] = string.format("diff: %s", item.path or "?")
    elseif item.type == "terminal" then
      parts[#parts + 1] = string.format("terminal: %s", item.terminalId or "?")
    end
  end
  return table.concat(parts, "\n")
end

local function merge_list(current, incoming)
  if incoming == nil then
    return current
  end
  return incoming
end

---Apply one update to a session.
---@param session AcpSessionState
---@param update table
---@return boolean changed
function M.apply(session, update)
  if type(update) ~= "table" or type(update.sessionUpdate) ~= "string" then
    Log.warn("ignoring malformed session update")
    return false
  end
  local kind = update.sessionUpdate

  if kind == "user_message_chunk" then
    local text = text_of(update.content)
    if text ~= "" then
      session:user_chunk(text, update.messageId)
      return true
    end
    return false
  end

  if kind == "agent_message_chunk" then
    local block = session:append_text("agent", text_of(update.content), update.messageId)
    block.child = update._meta and update._meta["opencode/child-session"] or nil
    return true
  end

  if kind == "agent_thought_chunk" then
    local text = text_of(update.content)
    if text == "" then
      return false
    end
    session:append_text("thought", text, update.messageId)
    return true
  end

  if kind == "tool_call" then
    local id = update.toolCallId
    if not id then
      return false
    end
    local existing = session.tools[id]
    local block = existing
    if not block then
      block = session:append({
        id = "tool:" .. id,
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
      })
      session.tools[id] = block
    end
    block.title = update.title or block.title
    block.name = merge_list(block.name, update.name)
    block.tool_kind = update.kind or block.tool_kind
    block.status = update.status or block.status
    block.locations = merge_list(block.locations, update.locations)
    block.content = merge_list(block.content, update.content)
    block.raw_input = merge_list(block.raw_input, update.rawInput)
    block.raw_output = merge_list(block.raw_output, update.rawOutput)
    block.detail = tool_content_text(block.content)
    return true
  end

  if kind == "tool_call_update" then
    local id = update.toolCallId
    local block = id and session.tools[id]
    if not block then
      -- Update for an unknown tool call: create a placeholder so progress is not lost.
      block = session:append({
        id = "tool:" .. tostring(id),
        kind = "tool",
        text = "",
        title = update.title or tostring(id or "tool"),
        status = update.status or "pending",
        expanded = false,
      })
      if id then
        session.tools[id] = block
      end
    end
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
    block.detail = tool_content_text(block.content)
    return true
  end

  if kind == "plan" then
    local last = session.blocks[#session.blocks]
    if last and last.kind == "plan" then
      last.entries = update.entries or {}
      return true
    end
    session:append({ id = "plan:" .. session.turn, kind = "plan", text = "", entries = update.entries or {} })
    return true
  end

  if kind == "available_commands_update" then
    session.commands = update.availableCommands or {}
    return true
  end

  if kind == "current_mode_update" then
    session.current_mode = update.currentModeId
    return true
  end

  if kind == "config_option_update" then
    session.config_options = update.configOptions or {}
    return true
  end

  if kind == "session_info_update" then
    if update.title then
      session.title = update.title
    end
    local meta = update._meta or {}
    if meta["opencode/retry"] ~= nil then
      session.retry = meta["opencode/retry"]
      return true
    end
    if meta["opencode/compaction"] then
      local marker = meta["opencode/compaction"]
      session.compaction = marker
      if marker.status == "started" then
        session:append({
          id = "compaction:" .. tostring(marker.messageId),
          kind = "compaction",
          text = "",
          status = "in_progress",
        })
      else
        local found = false
        for _, b in ipairs(session.blocks) do
          if b.kind == "compaction" and b.status == "in_progress" then
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
          })
        end
      end
      return true
    end
    return update.title ~= nil
  end

  if kind == "usage_update" then
    session.usage = { used = update.used, size = update.size, cost = update.cost }
    return true
  end

  if kind == "notice" then
    session:append({
      id = "notice:" .. tostring(#session.blocks),
      kind = "notice",
      text = update.description or "",
      title = update.title,
      severity = update.severity,
    })
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
      })
    end
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
      })
    end
    block.text = block.text .. text_of(update.content)
    return true
  end

  Log.debug("unhandled session update kind: %s", kind)
  return false
end

---Extract the model select option name for the toolbar.
---@param session AcpSessionState
---@return string|nil model_label
---@return string|nil mode_label
function M.toolbar_labels(session)
  local model = session:option_by_category("model")
  local mode = session:option_by_category("mode")
  local model_label = model and state.option_label(model, model.currentValue) or nil
  local mode_label = mode and state.option_label(mode, mode.currentValue) or nil
  return model_label, mode_label
end

return M
