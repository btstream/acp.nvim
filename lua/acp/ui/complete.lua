-- Completion for the composer: slash commands and @file mentions.
--
-- No completion framework is required: the composer uses `completefunc`, which
-- works with the built-in <C-x><C-u> mapping and is also picked up by
-- frameworks that respect `completefunc`.
local M = {}

local MAX_FILES = 200

---@param prefix string
---@return string[]
local function file_candidates(prefix)
  local pattern = prefix == "" and "*" or (vim.pesc(prefix) .. "*")
  local found = vim.fn.glob(pattern, false, true)
  local items = {}
  for _, path in ipairs(found) do
    if #items >= MAX_FILES then
      break
    end
    if vim.fn.isdirectory(path) == 0 then
      items[#items + 1] = path
    end
  end
  return items
end

---@param session AcpSessionState|nil
---@return table[]
local function commands(session)
  if not session then
    return {}
  end
  return session.commands or {}
end

---Build `completefunc` items for the composer buffer.
---@param findstart integer
---@param base string
---@param session AcpSessionState|nil
---@return integer|table
function M.complete(findstart, base, session)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local head = line:sub(1, col)

    -- Slash command at the very beginning of the line. Start after the `/`
    -- so the command name is inserted without duplicating the prefix.
    if head:match("^/[%w%-_]*$") then
      return 1
    end

    -- @mention anywhere in the line.
    local at = head:match(".*()@[^%s]*$")
    if at then
      -- `completefunc` expects a zero-based byte column, while the pattern
      -- capture is one-based.
      return at - 1
    end
    return -3
  end

  local items = {}
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local head = line:sub(1, col)

  if head:match("^/") and not head:match("%s") then
    for _, cmd in ipairs(commands(session)) do
      local name = cmd.name or ""
      if name ~= "" and vim.startswith(name, base) then
        items[#items + 1] = {
          word = name,
          abbr = "/" .. name,
          menu = "[cmd]",
          info = cmd.description or "",
          icase = 1,
          dup = 0,
        }
      end
    end
    return items
  end

  local prefix = base:gsub("^@", "")
  for _, path in ipairs(file_candidates(prefix)) do
    items[#items + 1] = {
      word = "@" .. path,
      abbr = path,
      menu = "[file]",
      icase = 1,
      dup = 0,
    }
  end
  return items
end

---Fill in the completion trigger for the composer buffer.
---@param bufnr integer
---@param get_session fun(): AcpSessionState|nil
function M.attach(bufnr, get_session)
  -- A plain global keeps `completefunc` portable across Neovim versions.
  _G.Acp_completefunc = function(findstart, base)
    return M.completefunc(findstart, base)
  end
  vim.bo[bufnr].completefunc = "v:lua.Acp_completefunc"
  vim.bo[bufnr].completeopt = "menuone,noinsert,noselect"

  vim.b[bufnr].acp_get_session = get_session
end

---Vimscript entrypoint for `completefunc`.
---@param findstart integer
---@param base string
---@return integer|table
function M.completefunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local getter = vim.b[bufnr].acp_get_session
  local session = nil
  if type(getter) == "function" then
    session = getter()
  end
  return M.complete(findstart, base, session)
end

return M
