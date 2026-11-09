-- Minimal file logger with redaction and size capping.
local M = {}

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }

local state = {
  level = LEVELS.warn,
  path = nil,
  max_bytes = 1024 * 1024,
  protocol = false,
  warned = false,
}

local function default_path()
  local dir = vim.fn.stdpath("log")
  if type(dir) ~= "string" or dir == "" then
    dir = vim.fn.stdpath("cache")
  end
  return dir .. "/acp.nvim.log"
end

function M.setup(opts)
  opts = opts or {}
  state.level = LEVELS[opts.level or "warn"] or LEVELS.warn
  state.max_bytes = opts.max_bytes or state.max_bytes
  state.protocol = opts.protocol == true
  state.path = opts.path or default_path()
  state.warned = false
  lines_since_check = 0
  -- Make sure the directory exists; otherwise every write silently fails.
  local dir = vim.fn.fnamemodify(state.path, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
end

function M.path()
  return state.path or default_path()
end

function M.protocol_enabled()
  return state.protocol
end

---Redact obvious secrets and truncate very long payloads.
---@param s string
---@param limit integer|nil
---@return string
function M.redact(s, limit)
  local out = tostring(s)
  -- Both quoted JSON style ("apiKey": "x") and bare assignment style
  -- (API_KEY=xxx, --token xxx).
  out = out:gsub('("?[Aa]pi[_-]?[Kk]ey"?%s*[:=]%s*")[^"]*"', "%1***" .. '"')
  out = out:gsub('("?[Aa]uthorization"?%s*[:=]%s*")[^"]*"', "%1***" .. '"')
  out = out:gsub('("?[Tt]oken"?%s*[:=]%s*")[^"]*"', "%1***" .. '"')
  out = out:gsub("([%w_%-]*[Aa]pi[_-]?[Kk]ey%s*[:=]%s*)[^%s\"',}]+", "%1***")
  out = out:gsub("([%w_%-]*[Tt]oken%s*[:=]%s*)[^%s\"',}]+", "%1***")
  out = out:gsub("([%w_%-]*[Ss]ecret%s*[:=]%s*)[^%s\"',}]+", "%1***")
  -- CLI style: `--token VALUE` / `--api-key VALUE`.
  out = out:gsub("(%-%-[Tt]oken%s+)[^%s\"',}]+", "%1***")
  out = out:gsub("(%-%-[Aa]pi%-?[Kk]ey%s+)[^%s\"',}]+", "%1***")
  out = out:gsub("(%-%-[Ss]ecret%s+)[^%s\"',}]+", "%1***")
  -- Short CLI style: `-token VALUE`.
  out = out:gsub("(%-[Tt]oken%s+)[^%s\"',}]+", "%1***")
  out = out:gsub("(%-[Ss]ecret%s+)[^%s\"',}]+", "%1***")
  out = out:gsub("(Bearer%s+)[%w%-%._~%+/=]+", "%1***")
  out = out:gsub("(sk%-)[%w%-_]+", "%1***")
  limit = limit or 4096
  if #out > limit then
    out = out:sub(1, limit) .. "...<truncated " .. (#out - limit) .. " bytes>"
  end
  return out
end

-- How many lines may be written before checking the file size again. The
-- previous implementation `fs_stat`ed (and sometimes read the whole file) on
-- every single log line.
local ROTATE_CHECK_INTERVAL = 200
local lines_since_check = 0

local function truncate_file(path, max_bytes)
  local ok, stat = pcall(vim.uv.fs_stat, path)
  if not ok or not stat or stat.size <= max_bytes then
    return
  end
  local src = io.open(path, "rb")
  if not src then
    return
  end
  local data = src:read("*a") or ""
  src:close()
  local keep = data:sub(-math.floor(max_bytes / 2))
  -- Rotate via a temp file so a concurrent reader never sees a half-written log.
  local tmp = path .. ".tmp"
  local dst = io.open(tmp, "wb")
  if dst then
    dst:write("...<log rotated>...\n")
    dst:write(keep)
    dst:close()
    if not vim.uv.fs_rename(tmp, path) then
      pcall(vim.uv.fs_unlink, tmp)
    end
  end
end

---@param level string
---@param fmt string
---@param ... any
function M.log(level, fmt, ...)
  local numeric = LEVELS[level] or LEVELS.info
  if numeric < state.level then
    return
  end
  local ok, message = pcall(string.format, fmt, ...)
  if not ok then
    -- Keep the arguments: a bad format string is a bug, and the raw values are
    -- what make it debuggable.
    local args = {}
    local n = select("#", ...)
    for i = 1, n do
      args[i] = tostring((select(i, ...)))
    end
    message = tostring(fmt) .. " " .. table.concat(args, " ")
  end
  -- `%f` keeps sub-second ordering for bursts of events in the same second.
  local line = string.format("[%s] [%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level:upper(), M.redact(message))
  local path = M.path()
  local fh = io.open(path, "ab")
  if not fh then
    if not state.warned then
      state.warned = true
      pcall(vim.notify, "acp.nvim: unable to write log file " .. path, vim.log.levels.WARN)
    end
    return
  end
  fh:write(line)
  fh:close()
  lines_since_check = lines_since_check + 1
  if lines_since_check >= ROTATE_CHECK_INTERVAL then
    lines_since_check = 0
    truncate_file(path, state.max_bytes)
  end
end

function M.trace(fmt, ...)
  M.log("trace", fmt, ...)
end

function M.debug(fmt, ...)
  M.log("debug", fmt, ...)
end

function M.info(fmt, ...)
  M.log("info", fmt, ...)
end

function M.warn(fmt, ...)
  M.log("warn", fmt, ...)
end

function M.error(fmt, ...)
  M.log("error", fmt, ...)
end

return M
