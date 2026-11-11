-- Framework-independent completion requests. Positions are UTF-8 byte columns;
-- adapters must advertise that encoding instead of relying on LSP defaults.
local mentions = require("acp.completion.mentions")
local files = require("acp.completion.files")
local M = {}
local bindings = {}

function M.attach(buf, getter, config)
  if bindings[buf] then
    M.detach(buf)
  end
  bindings[buf] = { getter = getter, config = config or require("acp.config").defaults, requests = {} }
end

function M.detach(buf)
  local binding = bindings[buf]
  bindings[buf] = nil
  if binding then
    for cancel in pairs(binding.requests) do
      cancel()
    end
  end
end

function M.cancel(buf, kind)
  local binding = bindings[buf]
  if not binding then
    return
  end
  local jobs = {}
  for cancel, owner in pairs(binding.requests) do
    if not kind or owner == kind then
      jobs[#jobs + 1] = cancel
    end
  end
  for _, cancel in ipairs(jobs) do
    cancel()
  end
end

function M.binding(buf)
  return bindings[buf]
end

function M.cwd(binding, session)
  local path = session and session.cwd or binding.config.cwd
  if type(path) ~= "string" or path == "" then
    path = vim.fn.getcwd()
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false })
end

function M.available(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].filetype == "acp_input"
    and vim.bo[buf].modifiable
    and bindings[buf] ~= nil
end

function M.context(line, col)
  local head = line:sub(1, col)
  if head:match("^/%S*$") then
    local suffix = line:sub(col + 1):match("^%S*") or ""
    return { kind = "command", first = 0, last = col + #suffix, query = head:sub(2) }
  end
  return mentions.context(line, col)
end

function M.item(query, row, label, inserted, kind, description)
  return {
    label = label,
    filterText = label,
    kind = kind,
    insertTextFormat = 1,
    documentation = description and { kind = "plaintext", value = description } or nil,
    textEdit = {
      newText = inserted,
      range = {
        start = { line = row, character = query.first },
        ["end"] = { line = row, character = query.last },
      },
    },
  }
end

-- Captured identity is checked before each layout batch and delivery. A slow
-- index from the previous session must never populate a new session's menu.
function M.request(buf, row, col, callback)
  local binding = bindings[buf]
  if not binding or not M.available(buf) then
    callback({})
    return function() end
  end
  local session = binding.getter()
  local cwd = M.cwd(binding, session)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local query = M.context(line, col)
  if not query then
    callback({})
    return function() end
  end
  local done, unsubscribe, cancel = false, nil, nil
  local function deliver(items, err)
    if done then
      return
    end
    done = true
    binding.requests[cancel] = nil
    unsubscribe = nil
    local cb = callback
    callback = nil
    cb(items or {}, err)
  end
  cancel = function()
    local stop = unsubscribe
    unsubscribe = nil
    if stop then
      stop()
    end
    deliver({})
  end
  binding.requests[cancel] = "completion"
  local function fresh()
    local current = binding.getter()
    return bindings[buf] == binding
      and M.available(buf)
      and vim.api.nvim_get_current_buf() == buf
      and vim.api.nvim_buf_get_changedtick(buf) == tick
      and current == session
      and M.cwd(binding, current) == cwd
      and vim.api.nvim_win_get_cursor(0)[1] == row + 1
      and vim.api.nvim_win_get_cursor(0)[2] == col
  end
  local function valid()
    if done then
      return false
    end
    if not fresh() then
      cancel()
      return false
    end
    return true
  end
  if query.kind == "command" then
    vim.schedule(function()
      if not valid() then
        return
      end
      local items = {}
      local commands = session and type(session.commands) == "table" and session.commands or {}
      for _, cmd in ipairs(commands) do
        if type(cmd) == "table" and type(cmd.name) == "string" and cmd.name ~= "" then
          local item = M.item(
            query,
            row,
            "/" .. cmd.name,
            "/" .. cmd.name,
            14,
            type(cmd.description) == "string" and cmd.description or nil
          )
          item.detail = type(cmd.input) == "table" and type(cmd.input.hint) == "string" and cmd.input.hint or nil
          items[#items + 1] = item
        end
      end
      deliver(items)
    end)
  else
    unsubscribe = files.list(cwd, binding.config.completion.files, function(paths, err, root)
      if not valid() then
        return
      end
      if err then
        deliver({}, err)
        return
      end
      local items, index = {}, 1
      local function build()
        if not valid() then
          return
        end
        for _ = 1, 256 do
          local path = paths[index]
          if not path then
            deliver(items)
            return
          end
          index = index + 1
          local relative = root == cwd and path or files.relative(root .. "/" .. path, cwd)
          local item = M.item(query, row, mentions.display(relative), mentions.encode(relative), 17)
          item.filterText = item.textEdit.newText
          item.detail = mentions.display(relative)
          if item.detail ~= relative then
            item.data = { acp_path = relative }
          end
          items[#items + 1] = item
        end
        vim.schedule(build)
      end
      build()
    end)
  end
  return cancel
end

function M.refresh()
  files.refresh()
end

-- Used only by the native fallback. Framework adapters deliberately leave
-- filtering/ranking to their own engines and never truncate the project index.
function M.native_items(items, query, limit)
  local matches, out = {}, {}
  local labels = {}
  for i, item in ipairs(items) do
    labels[i] = query.kind == "file" and (item.data and item.data.acp_path or item.detail) or item.label
  end
  if query.query == "" then
    for i = 1, math.min(#items, limit) do
      matches[#matches + 1] = i
    end
  else
    local result = vim.fn.matchfuzzypos(labels, query.query)
    local by_label = {}
    for i, label in ipairs(labels) do
      by_label[label] = i
    end
    for i = 1, math.min(#result[1], limit) do
      matches[#matches + 1] = by_label[result[1][i]]
    end
  end
  for _, index in ipairs(matches) do
    local item = items[index]
    out[#out + 1] = {
      word = query.kind == "command" and item.textEdit.newText:sub(2) or item.textEdit.newText,
      abbr = item.label,
      menu = query.kind == "command" and "[cmd]" or "[file]",
      dup = 0,
      icase = 1,
      info = item.documentation and item.documentation.value or "",
    }
  end
  return out
end

return M
