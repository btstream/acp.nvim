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
  out = out:gsub('("?[Aa]pi[_-]?[Kk]ey"?%s*[:=]%s*")[^"]*"', '%1***"')
  out = out:gsub('("?[Aa]uthorization"?%s*[:=]%s*")[^"]*"', '%1***"')
  out = out:gsub('("?[Tt]oken"?%s*[:=]%s*")[^"]*"', '%1***"')
  out = out:gsub("(Bearer%s+)[%w%-%._~%+/=]+", "%1***")
  limit = limit or 4096
  if #out > limit then
    out = out:sub(1, limit) .. "...<truncated " .. (#out - limit) .. " bytes>"
  end
  return out
end

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
  local dst = io.open(path, "wb")
  if dst then
    dst:write("...<log rotated>...\n")
    dst:write(keep)
    dst:close()
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
    message = tostring(fmt)
  end
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
  truncate_file(path, state.max_bytes)
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
