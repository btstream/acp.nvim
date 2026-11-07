-- Agent subprocess management.
local Log = require("acp.log")
local framing = require("acp.transport.framing")

local M = {}

---@class AcpProcess
---@field job integer
---@field decoder AcpDecoder
---@field alive boolean
---@field stderr_tail string
---@field on_line fun(line: string)
---@field on_exit fun(code: integer, stderr: string)
local Process = {}
Process.__index = Process

local function trim_tail(text, limit)
  if #text <= limit then
    return text
  end
  return text:sub(-limit)
end

---Spawn the agent process.
---@param opts {command: string, args: string[]|nil, cwd: string|nil, env: table<string,string>|nil, max_line_bytes: integer|nil, stderr_keep_bytes: integer|nil, shutdown_timeout: integer|nil, on_line: fun(line: string), on_exit: fun(code: integer, stderr: string)}
---@return AcpProcess|nil proc
---@return string|nil err
function M.spawn(opts)
  local self = setmetatable({
    decoder = framing.new_decoder(opts.max_line_bytes),
    alive = false,
    stderr_tail = "",
    stderr_limit = opts.stderr_keep_bytes or 64 * 1024,
    shutdown_timeout = opts.shutdown_timeout or 2000,
    on_line = opts.on_line,
    on_exit = opts.on_exit,
  }, Process)

  local cmd = { opts.command }
  vim.list_extend(cmd, opts.args or {})

  local function handle_stdout(_, data)
    if not data or #data == 0 then
      return
    end
    -- jobstart delivers newline-split chunks; only the last element can be partial.
    local chunk = data[1] or ""
    if #data > 1 then
      chunk = chunk .. "\n" .. table.concat(data, "\n", 2)
    end
    local ok = self.decoder:feed(chunk, function(line)
      self.on_line(line)
    end)
    if not ok then
      Log.error("protocol framing failed (message exceeds max_line_bytes)")
      self:stop(1)
    end
  end

  local function handle_stderr(_, data)
    if not data then
      return
    end
    local text = table.concat(data, "\n")
    if #text > 0 then
      self.stderr_tail = trim_tail(self.stderr_tail .. text .. "\n", self.stderr_limit)
      if Log.protocol_enabled() then
        Log.debug("[agent stderr] %s", text)
      end
    end
  end

  local function handle_exit(_, code)
    self.alive = false
    local stderr = self.stderr_tail
    Log.info("agent exited with code %d", code)
    pcall(self.on_exit, code, stderr)
  end

  local job
  local ok, err = pcall(function()
    job = vim.fn.jobstart(cmd, {
      cwd = opts.cwd,
      env = opts.env,
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = handle_stdout,
      on_stderr = handle_stderr,
      on_exit = handle_exit,
    })
  end)
  if not ok then
    return nil, tostring(err)
  end
  if not job or job <= 0 then
    return nil, string.format("failed to start command %q (jobstart returned %s)", cmd[1], tostring(job))
  end

  self.job = job
  self.alive = true
  Log.info("spawned agent: %s", table.concat(cmd, " "))
  return self
end

---Write a payload to the agent's stdin.
---@param payload string
---@return boolean
function Process:write(payload)
  if not self.alive or not self.job then
    return false
  end
  local ok, sent = pcall(vim.fn.chansend, self.job, payload)
  if not ok or sent == 0 then
    Log.warn("failed to write to agent stdin")
    return false
  end
  return true
end

---Close stdin, allowing the agent to exit gracefully.
function Process:close_stdin()
  if self.alive and self.job then
    pcall(vim.fn.chanclose, self.job, "stdin")
  end
end

---Terminate the process. `grace_ms` controls the delay before a hard kill.
---@param force boolean|nil
function Process:stop(force)
  if not self.job then
    return
  end
  if self.alive and not force then
    self:close_stdin()
    local job = self.job
    vim.defer_fn(function()
      if self.alive and self.job == job then
        pcall(vim.fn.jobstop, job)
      end
    end, self.shutdown_timeout)
    return
  end
  pcall(vim.fn.jobstop, self.job)
end

---@return boolean
function Process:is_alive()
  return self.alive
end

---@return string
function Process:stderr()
  return self.stderr_tail
end

return M
