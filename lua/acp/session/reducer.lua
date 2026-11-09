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
local function reduce(session, update)
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
    local text = text_of(update.content)
    if text == "" then
      return false
    end
    local block = session:append_text("agent", text, update.messageId)
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
    if update.content ~= nil or block.detail == nil then
      block.detail = tool_content_text(block.content)
    end
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
      })
      session.tools[id] = block
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
    if update.content ~= nil or block.detail == nil then
      block.detail = tool_content_text(block.content)
    end
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
      active.entries = update.entries or {}
      return true
    end
    session:append({ id = "plan:" .. session.turn, kind = "plan", text = "", entries = update.entries or {} })
    return true
  end

  if kind == "available_commands_update" then
    local commands = update.availableCommands or {}
    -- Re-rendering for an identical list is pure work; the winbar and
    -- transcript only care about the difference.
    if vim.deep_equal(session.commands, commands) then
      return false
    end
    session.commands = commands
    return true
  end

  if kind == "current_mode_update" then
    if session.current_mode == update.currentModeId then
      return false
    end
    session.current_mode = update.currentModeId
    return true
  end

  if kind == "config_option_update" then
    local options = update.configOptions or {}
    if vim.deep_equal(session.config_options, options) then
      return false
    end
    session.config_options = options
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
    local usage = { used = update.used, size = update.size, cost = update.cost }
    if vim.deep_equal(session.usage, usage) then
      return false
    end
    session.usage = usage
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
    state.append_block_text(block, text_of(update.content))
    return true
  end

  Log.debug("unhandled session update kind: %s", kind)
  return false
end

function M.apply(session, update)
  local changed = reduce(session, update)
  if not changed then
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

---Strip the provider prefix from a model name.
---
---Agents prefix model names with their provider ("commandcode/DeepSeek V4.1
---Flash", "anthropic/claude-sonnet-5-5"). The toolbar has little room and the
---provider adds little once a model is selected, so only the model part is
---shown. Picker entries keep the full name so two providers offering the same
---model stay distinguishable.
---@param name string|nil
---@return string|nil
function M.short_model_name(name)
  if type(name) ~= "string" or name == "" then
    return name
  end
  -- Only the display name matters. If it has no provider prefix there is
  -- nothing to strip, even when the value happens to carry one: the name is
  -- what the user already sees elsewhere.
  local _, rest = name:match("^([^/]+)/(.+)$")
  if rest and rest ~= "" then
    return rest
  end
  return name
end

---Extract the model and mode labels used by the composer toolbar.
---
---Called from the winbar, which Vim evaluates on every redraw (cursor moves,
---scrolls, resizes). The labels only change when the session's config options
---or current values change, so the result is memoised per option table.
---@param session AcpSessionState
---@return string|nil model_label
---@return string|nil mode_label
function M.toolbar_labels(session)
  local cached = session._toolbar_labels
  local opts = session.config_options
  local model = session:option_by_category("model")
  local mode = session:option_by_category("mode")
  local model_value = model and model.currentValue or nil
  local mode_value = mode and mode.currentValue or nil
  if
    cached
    and cached.options == opts
    and cached.model == model
    and cached.mode == mode
    and cached.model_value == model_value
    and cached.mode_value == mode_value
  then
    return cached.model_label, cached.mode_label
  end

  local model_label = model and state.option_label(model, model.currentValue) or nil
  model_label = M.short_model_name(model_label)
  local mode_label = mode and state.option_label(mode, mode.currentValue) or nil
  session._toolbar_labels = {
    options = opts,
    model = model,
    mode = mode,
    model_value = model_value,
    mode_value = mode_value,
    model_label = model_label,
    mode_label = mode_label,
  }
  return model_label, mode_label
end

return M
