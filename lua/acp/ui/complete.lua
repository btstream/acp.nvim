-- Optional native frontend to the same asynchronous core as blink/cmp.
local core = require("acp.completion")
local M = {}
local requests = {}
local contexts = {}

-- Kept for standalone users of the old completefunc helper. File discovery is
-- asynchronous now; the attached completefunc below supplies those results.
function M.complete(findstart, base, session)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local query = core.context(line, col)
  if findstart == 1 then
    return query and (query.kind == "command" and 1 or query.first) or -3
  end
  if not query or query.kind ~= "command" then
    return {}
  end
  local items = {}
  local commands = session and type(session.commands) == "table" and session.commands or {}
  for _, cmd in ipairs(commands) do
    if type(cmd) == "table" and type(cmd.name) == "string" and cmd.name ~= "" and vim.startswith(cmd.name, base) then
      items[#items + 1] = {
        word = cmd.name,
        abbr = "/" .. cmd.name,
        menu = "[cmd]",
        info = type(cmd.description) == "string" and cmd.description or "",
        icase = 1,
        dup = 0,
      }
    end
  end
  return items
end

function M.completefunc(findstart, base)
  local buf = vim.api.nvim_get_current_buf()
  local binding = core.binding(buf)
  local session = binding and binding.getter()
  if findstart == 1 then
    local first = M.complete(1, base, session)
    contexts[buf] = first >= 0
        and {
          cursor = vim.api.nvim_win_get_cursor(0),
          line = vim.api.nvim_get_current_line(),
          session = session,
          cwd = binding and core.cwd(binding, session),
        }
      or nil
    return first
  end
  local saved = contexts[buf]
  if not saved then
    return {}
  end
  local cursor, line = saved.cursor, saved.line
  local query = core.context(line, cursor[2])
  if not binding or not query then
    contexts[buf] = nil
    return {}
  end
  if query.kind == "command" then
    contexts[buf] = nil
    return M.complete(0, base, session)
  end
  if requests[buf] and requests[buf].cancel then
    requests[buf].cancel()
  end
  local request = {}
  requests[buf] = request
  -- During the second completefunc call Neovim temporarily places the cursor
  -- at findstart (and may temporarily remove the base). Wait for its return
  -- before creating the ordinary asynchronous request.
  vim.schedule(function()
    if
      requests[buf] ~= request
      or not vim.api.nvim_buf_is_valid(buf)
      or vim.api.nvim_get_current_buf() ~= buf
      or core.binding(buf) ~= binding
      or binding.getter() ~= saved.session
      or core.cwd(binding, saved.session) ~= saved.cwd
      or vim.api.nvim_get_current_line() ~= line
    then
      if requests[buf] == request then
        requests[buf], contexts[buf] = nil, nil
      end
      return
    end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    request.cancel = core.request(buf, cursor[1] - 1, cursor[2], function(items, err)
      vim.schedule(function()
        if requests[buf] ~= request then
          return
        end
        requests[buf], contexts[buf] = nil, nil
        if
          not vim.api.nvim_buf_is_valid(buf)
          or not core.available(buf)
          or core.binding(buf) ~= binding
          or binding.getter() ~= saved.session
          or core.cwd(binding, saved.session) ~= saved.cwd
          or vim.api.nvim_get_current_buf() ~= buf
          or vim.api.nvim_buf_get_changedtick(buf) ~= tick
          or vim.fn.mode():sub(1, 1) ~= "i"
        then
          return
        end
        if err then
          require("acp.log").warn("completion: %s", err)
          return
        end
        local current = vim.api.nvim_win_get_cursor(0)
        if current[1] ~= cursor[1] or current[2] ~= cursor[2] then
          return
        end
        local candidates = core.native_items(items, query, binding.config.completion.max_items)
        local suffix = line:sub(cursor[2] + 1, query.last)
        for _, item in ipairs(candidates) do
          item.user_data = { acp_suffix = suffix, acp_first = query.first }
        end
        if #candidates > 0 then
          vim.fn.complete(query.first + 1, candidates)
        end
      end)
    end)
  end)
  return {}
end

function M.attach(buf, getter, config)
  core.attach(buf, getter, config)
  requests[buf] = nil
  contexts[buf] = nil
  vim.b[buf].acp_get_session = getter -- compatibility with existing completefunc users
  local group = vim.api.nvim_create_augroup("AcpCompletion" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      core.cancel(buf, "completion")
      requests[buf], contexts[buf] = nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    buffer = buf,
    callback = function()
      core.cancel(buf)
      requests[buf], contexts[buf] = nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      core.detach(buf)
      requests[buf] = nil
      contexts[buf] = nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  vim.api.nvim_create_autocmd("CompleteDone", {
    group = group,
    buffer = buf,
    callback = function()
      local item = vim.v.completed_item
      local data = item and item.user_data
      if type(data) ~= "table" or not data.acp_suffix or data.acp_suffix == "" then
        return
      end
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local first, word, suffix = data.acp_first, item.word, data.acp_suffix
      local binding = core.binding(buf)
      local session = binding and binding.getter()
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      vim.schedule(function()
        if
          not core.available(buf)
          or vim.api.nvim_get_current_buf() ~= buf
          or core.binding(buf) ~= binding
          or binding.getter() ~= session
          or vim.api.nvim_buf_get_changedtick(buf) ~= tick
        then
          return
        end
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
        local after = first + #word
        if line:sub(first + 1, after) == word and line:sub(after + 1, after + #suffix) == suffix then
          vim.api.nvim_buf_set_text(buf, row, after, row, after + #suffix, {})
        end
      end)
    end,
  })
  if core.binding(buf).config.completion.native then
    _G.Acp_completefunc = M.completefunc
    vim.bo[buf].completefunc = "v:lua.Acp_completefunc"
    vim.bo[buf].completeopt = "menuone,noinsert,noselect"
  elseif vim.bo[buf].completefunc == "v:lua.Acp_completefunc" then
    vim.bo[buf].completefunc = ""
  end
end

return M
