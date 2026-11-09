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
  if limit <= 0 then
    return ""
  end
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

  local pending, head, tail, pending_bytes = {}, 1, 0, 0
  local scheduled, exited, exit_sent, stopped = false, nil, false, false
  local pending_limit = opts.max_pending_bytes or 16 * 1024 * 1024
  local budget = (opts.dispatch_budget_ms or 4) * 1e6
  local drain
  local function schedule_drain()
    if scheduled then
      return
    end
    scheduled = true
    vim.schedule(drain)
  end
  drain = function()
    scheduled = false
    local start = vim.uv.hrtime()
    while head <= tail do
      local line = pending[head]
      pending[head], head, pending_bytes = nil, head + 1, pending_bytes - #line - 64
      local ok, err = pcall(self.on_line, line)
      if not ok then
        framing.on_handler_error(err)
      end
      if vim.uv.hrtime() - start >= budget then
        break
      end
    end
    if head <= tail then
      schedule_drain()
    else
      pending, head, tail = {}, 1, 0
      if exited ~= nil and not exit_sent then
        exit_sent = true
        pcall(self.on_exit, exited, self.stderr_tail)
      end
    end
  end
  self.drop_pending = function()
    stopped = true
    pending, head, tail, pending_bytes = {}, 1, 0, 0
  end

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
      if stopped then
        return
      end
      if pending_bytes + #line + 64 > pending_limit then
        Log.error("agent dispatch queue exceeds max_pending_bytes")
        self:stop(true)
        return
      end
      tail = tail + 1
      pending[tail], pending_bytes = line, pending_bytes + #line + 64
      schedule_drain()
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
    exited = code
    Log.info("agent exited with code %d", code)
    -- Deliver the final RPC response before the exit event, even when it was
    -- received in the same burst. Otherwise shutdown races pending responses.
    schedule_drain()
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
---
---`chansend` may accept fewer bytes than requested when the pipe buffer is
---full. The remainder is retried in a bounded loop so a large prompt is not
---silently dropped on the floor.
---@param payload string
---@return boolean
function Process:write(payload)
  if not self.alive or self.stopping or not self.job then
    return false
  end
  local offset = 1
  local len = #payload
  local attempts = 0
  while offset <= len do
    local ok, sent = pcall(vim.fn.chansend, self.job, payload:sub(offset))
    if not ok then
      Log.warn("failed to write to agent stdin: %s", tostring(sent))
      self:stop(true)
      return false
    end
    if sent == 0 then
      attempts = attempts + 1
      if attempts > 100 or not self.alive then
        Log.warn("agent stdin stayed blocked; dropping %d bytes", len - offset + 1)
        self:stop(true) -- a partial JSON line must never be followed by another request
        return false
      end
      -- Give the agent a moment to drain its stdin without freezing the loop.
      vim.wait(1)
    else
      offset = offset + sent
      attempts = 0
    end
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
  self.stopping = true
  if self.drop_pending then
    self.drop_pending()
  end
  if not self.job then
    return
  end
  local job = self.job
  if self.alive and not force then
    self:close_stdin()
    local timer = vim.uv.new_timer()
    self.stop_timer = timer
    timer:start(self.shutdown_timeout, 0, function()
      vim.schedule(function()
        timer:stop()
        timer:close()
        if self.stop_timer == timer then
          self.stop_timer = nil
        end
        if self.alive and self.job == job then
          -- SIGTERM lets an agent flush and exit cleanly; escalate to SIGKILL
          -- only if it is still running after the grace period, otherwise an
          -- agent that ignores SIGTERM would linger forever.
          pcall(vim.fn.jobstop, job)
          local pid = nil
          pcall(function()
            pid = vim.fn.jobpid(job)
          end)
          if pid and pid > 0 then
            vim.defer_fn(function()
              if self.job == job and self.alive then
                pcall(vim.uv.kill, pid, 9)
              end
            end, 500)
          end
        end
      end)
    end)
    return
  end
  -- Hard stop: SIGTERM, then SIGKILL shortly after.
  pcall(vim.fn.jobstop, job)
  local pid = nil
  pcall(function()
    pid = vim.fn.jobpid(job)
  end)
  if pid and pid > 0 then
    vim.defer_fn(function()
      if self.job == job and self.alive then
        pcall(vim.uv.kill, pid, 9)
      end
    end, 500)
  end
end

---@return boolean
function Process:is_alive()
  return self.alive and not self.stopping
end

---@return string
function Process:stderr()
  return self.stderr_tail
end

return M
