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
---@field stats table receive/dispatch diagnostics
local Process = {}
Process.__index = Process

-- Compact, bounded diagnostics. Values are counters so the default path costs a
-- few increments per callback and one clock read per dispatch batch.
local function new_stats()
  return {
    phase = nil, -- "replay" while agent-side history replay is active
    callbacks = 0,
    received_messages = 0,
    received_bytes = 0,
    max_callback_bytes = 0,
    max_callback_messages = 0,
    max_line_bytes_seen = 0,
    pending_high_water = 0,
    dispatches = 0,
    dispatched_messages = 0,
    dispatched_bytes = 0,
    max_dispatch_ms = 0,
    slowest_line_ms = 0,
    overflow_at = nil,
    overflow_callback_message = nil,
    overflow_pending = nil,
    memory_high_water = 0,
    unbounded = false,
    warn_level = 0,
    spill_active = false,
    spill_records = 0,
    spill_bytes = 0,
    spill_reads = 0,
    spill_failures = 0,
    spill_path = nil,
  }
end

local MIB = 1024 * 1024
-- Escalating, one-shot memory warnings. They exist so an unbounded connection
-- leaves a trail before the OS runs out of memory.
local WARN_LEVELS = { 16 * MIB, 64 * MIB, 256 * MIB, 1024 * MIB }
local SPILL_TTL = 24 * 3600

---Remove stale spill files left behind by a crashed editor.
---@param dir string|nil
function M.sweep_spill(dir)
  dir = dir or (vim.fn.stdpath("run") .. "/acp.nvim")
  local scan = vim.uv.fs_scandir(dir)
  while scan do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if kind == "file" and name:match("^acp%-spill%-") then
      local path = dir .. "/" .. name
      local stat = vim.uv.fs_stat(path)
      local mtime = stat and (type(stat.mtime) == "table" and stat.mtime.sec or stat.mtime)
      if mtime and os.time() - mtime > SPILL_TTL then
        pcall(vim.uv.fs_unlink, path)
      end
    end
  end
end

local function trim_tail(text, limit)
  if limit <= 0 then
    return ""
  end
  if #text <= limit then
    return text
  end
  return text:sub(-limit)
end

---Compact one-line diagnostic for a receive limit failure.
---@param stats table
---@param line_bytes integer
---@param limit integer
---@return string
function M.summary(stats, line_bytes, limit)
  return string.format(
    "phase=%s unbounded=%s spill=%s/%d/%d pending=%d retained=%d limit=%d line=%d callback_msg=%d callbacks=%d msgs=%d bytes=%d max_callback=%d max_msg=%d mem_high=%d warn=%d batches=%d/%d max_batch=%.1fms slowest=%.1fms",
    tostring(stats.phase),
    tostring(stats.unbounded),
    tostring(stats.spill_active),
    stats.spill_records,
    stats.spill_failures,
    stats.overflow_pending or 0,
    stats.overflow_at or 0,
    limit,
    line_bytes,
    stats.overflow_callback_message or 0,
    stats.callbacks,
    stats.received_messages,
    stats.received_bytes,
    stats.max_callback_bytes,
    stats.max_line_bytes_seen,
    stats.memory_high_water,
    stats.warn_level,
    stats.dispatches,
    stats.dispatched_messages,
    stats.max_dispatch_ms,
    stats.slowest_line_ms
  )
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
    stats = new_stats(),
  }, Process)

  local cmd = { opts.command }
  vim.list_extend(cmd, opts.args or {})
  local pending, head, tail, pending_bytes = {}, 1, 0, 0
  local continuation, continuation_bytes = nil, 0
  local inputs, input_head, input_tail, input_bytes = {}, 1, 0, 0
  local input_scheduled = false
  local scheduled, exited, exit_sent, stopped = false, nil, false, false
  local pending_limit = opts.max_pending_bytes or 64 * 1024 * 1024
  local budget = (opts.dispatch_budget_ms or 4) * 1e6
  local process_scheduler = opts.scheduler
  local stats = self.stats
  stats.unbounded = pending_limit == 0
  local warn_levels = opts.warn_levels or WARN_LEVELS
  local spill_refill, spill_close, make_space
  -- Consume during receive once the backlog reaches this many bytes. With no
  -- total cap there is no half-limit, so use a fixed working set.
  local spill_limit = opts.spill_bytes or 0
  if spill_limit > 0 and pending_limit > 0 then
    spill_limit = math.min(spill_limit, math.floor(pending_limit * 0.75))
  end
  local spool
  if spill_limit >= 1024 then
    spool = {
      high = spill_limit,
      low = math.max(1024, math.floor(spill_limit / 4)),
      dir = opts.spill_dir,
      active = false,
      failed = false,
      fd = nil,
      path = nil,
      written = 0, -- records appended to the file
      consumed = 0, -- records handed back to the queue
      write_offset = 0,
      read_offset = 0,
      read_buf = "",
      busy = false,
      inflight_bytes = 0,
      records = 0,
      bytes = 0,
    }
    M.sweep_spill(spool.dir)
  end
  local pump_at = spool and spool.high or (pending_limit > 0 and pending_limit / 2 or 8 * MIB)
  local drain
  local function has_more()
    return input_head <= input_tail
      or continuation ~= nil
      or head <= tail
      or (spool ~= nil and (spool.busy or spool.ready ~= nil or spool.consumed < spool.written))
  end
  local function finish_exit()
    pending, head, tail = {}, 1, 0
    if exited ~= nil and not exit_sent then
      exit_sent = true
      spill_close()
      pcall(self.on_exit, exited, self.stderr_tail)
    end
  end

  ---Dispatch head-first until `deadline`. The same budget is shared by the
  ---receive callback, so a large burst drains between newline-delimited input
  ---elements instead of first materialising every line.
  local function pump(deadline)
    local started = vim.uv.hrtime()
    local messages, bytes, slowest = 0, 0, 0
    while not stopped and vim.uv.hrtime() < deadline do
      local line_start = vim.uv.hrtime()
      local line_bytes = 0
      if continuation then
        local ok, more = pcall(continuation)
        if not ok then
          framing.on_handler_error(more)
        end
        if not ok or not more or stopped then
          continuation, continuation_bytes = nil, 0
        end
      else
        -- Disk holds the oldest prefix. A lazy text dispatcher, if any, always
        -- finishes before either disk records or newer in-memory messages.
        if spool and spool.busy then
          break
        end
        local refilled = spill_refill()
        if spool and (spool.busy or spool.ready ~= nil or (spool.consumed < spool.written and not refilled)) then
          break
        end
        if stopped or head > tail then
          break
        end
        local line = pending[head]
        line_bytes = #line
        pending[head], head, pending_bytes = nil, head + 1, pending_bytes - #line - 64
        local ok, dispatch = pcall(self.on_line, line)
        if not ok then
          framing.on_handler_error(dispatch)
        elseif type(dispatch) == "function" and not stopped then
          continuation, continuation_bytes = dispatch, #line + 64
        end
      end
      local line_ms = (vim.uv.hrtime() - line_start) / 1e6
      if line_ms > slowest then
        slowest = line_ms
      end
      messages, bytes = messages + 1, bytes + line_bytes
      if vim.uv.hrtime() >= deadline then
        break
      end
    end
    if messages > 0 then
      stats.dispatches = stats.dispatches + 1
      stats.dispatched_messages = stats.dispatched_messages + messages
      stats.dispatched_bytes = stats.dispatched_bytes + bytes
      if slowest > stats.slowest_line_ms then
        stats.slowest_line_ms = slowest
      end
      local batch_ms = (vim.uv.hrtime() - started) / 1e6
      if batch_ms > stats.max_dispatch_ms then
        stats.max_dispatch_ms = batch_ms
      end
    end
    return messages
  end

  local function schedule_drain()
    if scheduled then
      return
    end
    scheduled = true
    vim.schedule(drain)
  end
  drain = function()
    scheduled = false
    if stopped then
      -- drop_pending cleared the queue; the exit event still has to be
      -- delivered once nothing is left.
      if not has_more() then
        finish_exit()
      end
      return
    end
    make_space()
    pump(vim.uv.hrtime() + budget)
    if has_more() then
      if not (spool and spool.busy) then
        schedule_drain()
      end
    else
      finish_exit()
    end
  end
  self.drop_pending = function()
    stopped = true
    continuation, continuation_bytes = nil, 0
    self.decoder.parts, self.decoder.buffered = {}, 0
    pending, head, tail, pending_bytes = {}, 1, 0, 0
    inputs, input_head, input_tail, input_bytes = {}, 1, 0, 0
    if spool then
      spill_close()
    end
  end

  ---Whether one more byte of input fits the shared receive budget.
  ---@param extra integer
  ---@return boolean
  local function spill_retained()
    if not spool then
      return 0
    end
    return spool.inflight_bytes + #spool.read_buf + (spool.ready and #spool.ready + 64 or 0)
  end

  local function fits(extra)
    if pending_limit == 0 then
      return true
    end
    return self.decoder.buffered + pending_bytes + continuation_bytes + spill_retained() + input_bytes + extra + 64
      <= pending_limit
  end

  local function retained()
    return self.decoder.buffered + pending_bytes + continuation_bytes + spill_retained() + input_bytes
  end

  ---Record the memory high-water mark and emit one warning per level.
  local function check_memory()
    local total = retained()
    if total > stats.memory_high_water then
      stats.memory_high_water = total
    end
    local level = warn_levels[stats.warn_level + 1]
    if level and total >= level then
      stats.warn_level = stats.warn_level + 1
      Log.warn(
        "receive backlog reached %d MiB (%s); %s",
        math.floor(level / MIB),
        stats.phase or "live",
        spool and not spool.failed and "spilling will continue at " .. math.floor(spool.high / MIB) .. " MiB"
          or "no spill file: memory will grow"
      )
      check_memory()
    end
  end

  local function overflow(extra)
    stats.overflow_at = retained() + extra
    stats.overflow_pending = retained()
    stats.phase = stats.phase or "live"
    Log.error("agent dispatch queue exceeds max_pending_bytes (%s)", M.summary(stats, extra, pending_limit))
    self:stop(true)
  end

  ---------------------------------------------------------------------------
  -- spool: move the oldest queued lines to a temp file while memory is high
  ---------------------------------------------------------------------------
  local SPILL_CHUNK = 64 * 1024

  local function spill_dir()
    return spool.dir or (vim.fn.stdpath("run") .. "/acp.nvim")
  end

  local function spill_open()
    if spool.fd then
      return true
    end
    if spool.failed then
      return false
    end
    local dir = spill_dir()
    pcall(vim.fn.mkdir, dir, "p")
    local ok, fd, path = pcall(vim.uv.fs_mkstemp, dir .. "/acp-spill-XXXXXX")
    if not ok or not fd then
      spool.failed = true
      stats.spill_failures = stats.spill_failures + 1
      Log.warn("unable to create the receive spill file: %s", tostring(path))
      return false
    end
    spool.fd, spool.path = fd, path
    stats.spill_path = path
    pcall(vim.uv.fs_chmod, path, 384) -- 0600
    return true
  end

  local function spill_write(data, done)
    local offset = 0
    local fd, token = spool.fd, spool.io
    local function cancelled()
      if stopped or spool.io ~= token then
        if spool.fd == fd and spool.closing then
          spool.busy = false
          spill_close()
          schedule_drain()
        end
        return true
      end
      return false
    end
    local function step()
      if cancelled() then
        return
      end
      if offset >= #data then
        done(true)
        return
      end
      local function complete(err, sent)
        if cancelled() then
          return
        end
        if err or type(sent) ~= "number" or sent <= 0 then
          done(false, tostring(err or sent))
          return
        end
        offset, spool.write_offset = offset + sent, spool.write_offset + sent
        step()
      end
      local ok, req, err = pcall(
        vim.uv.fs_write,
        fd,
        data:sub(offset + 1, offset + SPILL_CHUNK),
        spool.write_offset,
        vim.schedule_wrap(complete)
      )
      if not ok or not req then
        complete(tostring(err or req))
      end
    end
    step()
  end

  ---Move the oldest lines to disk until memory falls to the low watermark.
  local function spill_head()
    if not spool.active or spool.busy or spool.ready then
      return
    end
    local moved, out, size = {}, {}, 0
    while head <= tail and pending_bytes > spool.low and size < SPILL_CHUNK do
      local line = pending[head]
      pending[head], head = nil, head + 1
      pending_bytes = math.max(0, pending_bytes - #line - 64)
      moved[#moved + 1] = line
      out[#out + 1] = #line .. "\n" .. line
      size = size + #line + 8
    end
    if #moved == 0 then
      return
    end
    local start_offset = spool.write_offset
    spool.busy, spool.io = true, {}
    for _, line in ipairs(moved) do
      spool.inflight_bytes = spool.inflight_bytes + #line + 64
    end
    spill_write(table.concat(out), function(ok, err)
      spool.busy, spool.inflight_bytes = false, 0
      if not ok then
        -- Only committed records count in `written`. Ignore a partial tail and
        -- disable future writes; older committed records remain readable first.
        spool.write_offset = start_offset
        for i = #moved, 1, -1 do
          head = head - 1
          pending[head] = moved[i]
          pending_bytes = pending_bytes + #moved[i] + 64
        end
        spool.active, spool.failed = false, true
        stats.spill_active, stats.spill_failures = false, stats.spill_failures + 1
        Log.warn("receive spill write failed (%s); continuing in memory", tostring(err))
      else
        spool.written = spool.written + #moved
        spool.records = spool.records + #moved
        spool.bytes = spool.bytes + size
        stats.spill_records, stats.spill_bytes = spool.records, spool.bytes
      end
      schedule_drain()
    end)
  end

  ---Read one record back. Returns nil at end of spool or on failure.
  local function spill_read(done)
    local fd, token = spool.fd, spool.io
    local function cancelled()
      if stopped or spool.io ~= token then
        if spool.fd == fd and spool.closing then
          spool.busy = false
          spill_close()
          schedule_drain()
        end
        return true
      end
      return false
    end
    local function step()
      if cancelled() then
        return
      end
      local nl = spool.read_buf:find("\n", 1, true)
      local len = nl and tonumber(spool.read_buf:sub(1, nl - 1))
      if
        (nl and (not len or len < 0 or len > self.decoder.max or len % 1 ~= 0)) or (not nl and #spool.read_buf > 16)
      then
        done(nil)
        return
      end
      if nl and #spool.read_buf >= nl + len then
        local line = spool.read_buf:sub(nl + 1, nl + len)
        spool.read_buf = spool.read_buf:sub(nl + len + 1)
        spool.consumed = spool.consumed + 1
        stats.spill_reads = stats.spill_reads + 1
        done(line)
        return
      end
      local function complete(err, data)
        if cancelled() then
          return
        end
        if err or type(data) ~= "string" or data == "" then
          done(nil)
          return
        end
        spool.read_offset = spool.read_offset + #data
        spool.read_buf = spool.read_buf .. data
        step()
      end
      local need = nl and (nl + len - #spool.read_buf) or SPILL_CHUNK
      local ok, req, err = pcall(vim.uv.fs_read, fd, need, spool.read_offset, vim.schedule_wrap(complete))
      if not ok or not req then
        complete(tostring(err or req))
      end
    end
    step()
  end

  ---Insert one spilled line back at the queue head, preserving age order.
  spill_refill = function()
    if not spool then
      return false
    end
    if spool.ready then
      local line = spool.ready
      spool.ready = nil
      head = head - 1
      pending[head] = line
      pending_bytes = pending_bytes + #line + 64
      return true
    end
    if spool.consumed >= spool.written then
      if spool.fd and not spool.busy then
        spill_close()
      end
      return false
    end
    if spool.busy then
      return false
    end
    spool.busy, spool.io = true, {}
    spill_read(function(line)
      spool.busy = false
      if not line then
        spool.failed, spool.active = true, false
        stats.spill_active = false
        stats.spill_failures = stats.spill_failures + 1
        Log.error("receive spill read failed; closing connection because message integrity cannot be guaranteed")
        self:stop(true)
      else
        spool.ready = line
      end
      schedule_drain()
    end)
    return false
  end

  ---Start spilling or move more of the backlog once memory is high.
  make_space = function()
    if not spool or spool.failed or spool.busy or spool.ready then
      return
    end
    if not spool.active then
      if self.decoder.buffered + pending_bytes < spool.high then
        return
      end
      if not spill_open() then
        return
      end
      spool.active, stats.spill_active = true, true
    end
    spill_head()
  end

  spill_close = function()
    if not spool then
      return
    end
    spool.active, stats.spill_active = false, false
    -- An in-flight libuv request still owns this fd. Close only after its
    -- callback, otherwise fd reuse could send that request to an unrelated file.
    if spool.busy then
      spool.closing = true
      return
    end
    spool.closing = false
    spool.busy, spool.io, spool.ready, spool.inflight_bytes = false, nil, nil, 0
    if spool.fd then
      pcall(vim.uv.fs_close, spool.fd)
      spool.fd = nil
    end
    if spool.path then
      pcall(vim.uv.fs_unlink, spool.path)
      spool.path = nil
    end
    spool.read_buf, spool.consumed, spool.written = "", 0, 0
    spool.read_offset, spool.write_offset = 0, 0
    stats.spill_path = nil
  end

  local function consume_stdout(entry)
    local data = entry.data
    local started = vim.uv.hrtime()
    local deadline = started + budget
    local pending_before = pending_bytes
    local callback_bytes, produced = entry.bytes or 0, entry.produced or 0
    local first_index = entry.index or 1
    -- Retain only unprocessed elements across slices; consumed slots are freed.
    local function consume()
      local index = first_index
      while index <= entry.count do
        if stopped then
          break
        end
        local element = data[index] or ""
        local raw = index < entry.count and (element .. "\n") or element
        if entry.retained then
          input_bytes = input_bytes - #raw - 64
        end
        data[index] = nil
        callback_bytes = callback_bytes + #raw
        stats.received_bytes = stats.received_bytes + #raw
        -- Free room before rejecting the new element: under pressure the queued
        -- head can be consumed here rather than overflowing on a small line.
        if head <= tail and self.decoder.buffered + pending_bytes > pump_at then
          pump(deadline)
        end
        local before = self.decoder.buffered + pending_bytes
        if not fits(#raw) then
          -- Spilling can free the head before rejecting the new element.
          make_space()
          before = self.decoder.buffered + pending_bytes
        end
        -- One callback element may itself contain many lines and exceed the whole
        -- budget. It is already in memory, so feed it: the per-line push path can
        -- spill what it produces. Only a single *message* is bounded by
        -- max_line_bytes, checked by the decoder.
        if not fits(#raw) and #raw + 64 <= pending_limit then
          stats.overflow_callback_message = produced
          overflow(#raw)
          break
        end
        local ok = self.decoder:feed(raw, function(line)
          produced = produced + 1
          if stopped then
            return
          end
          stats.received_messages = stats.received_messages + 1
          if #line > stats.max_line_bytes_seen then
            stats.max_line_bytes_seen = #line
          end
          if pending_bytes > stats.pending_high_water then
            stats.pending_high_water = pending_bytes
          end
          if pending_limit > 0 and retained() + #line + 64 > pending_limit then
            make_space()
          end
          if pending_limit > 0 and retained() + #line + 64 > pending_limit then
            stats.overflow_callback_message = produced
            overflow(0)
            return
          end
          tail = tail + 1
          pending[tail], pending_bytes = line, pending_bytes + #line + 64
          make_space()
        end)
        if not ok then
          Log.error(
            "protocol framing failed (message exceeds max_line_bytes: %d > %d)",
            self.decoder.failed_size or 0,
            self.decoder.max
          )
          self:stop(1)
          break
        end
        if stopped then
          -- feed() may have appended an incomplete tail after its handler stopped
          -- the connection. Do not retain that tail on a dead process.
          self.decoder.parts, self.decoder.buffered = {}, 0
          break
        end
        check_memory()
        if pending_limit > 0 and retained() > pending_limit then
          overflow(0)
          break
        end
        -- Once the shared deadline expires, leave dispatch to a scheduled drain;
        -- never run one expensive handler per remaining element of a large burst.
        if head <= tail and before + #raw > pump_at then
          pump(deadline)
        end
        if vim.uv.hrtime() >= deadline then
          index = index + 1
          break
        end
        index = index + 1
      end
      return index
    end
    first_index = consume()
    entry.index, entry.bytes, entry.produced = first_index, callback_bytes, produced

    if callback_bytes > stats.max_callback_bytes then
      stats.max_callback_bytes = callback_bytes
    end
    if produced > stats.max_callback_messages then
      stats.max_callback_messages = produced
    end
    stats.input_batches = (stats.input_batches or 0) + 1
    if Log.protocol_enabled() then
      Log.debug(
        "receive callback: %d bytes, %d complete messages, pending %d->%d, %.1fms",
        callback_bytes,
        produced,
        pending_before,
        pending_bytes,
        (vim.uv.hrtime() - started) / 1e6
      )
    end
    return first_index > entry.count
  end

  -- Only one ordered raw-input queue owns callback tails. Later callbacks and
  -- the exit event cannot overtake it; every continuation gets a fresh deadline.
  local function retain_input(entry)
    entry.retained = true
    for i = entry.index or 1, entry.count do
      input_bytes = input_bytes + #(entry.data[i] or "") + (i < entry.count and 1 or 0) + 64
    end
    check_memory()
    if pending_limit > 0 and retained() > pending_limit then
      overflow(0)
      return
    end
    input_tail = input_tail + 1
    inputs[input_tail] = entry
  end
  local function input_step()
    if stopped then
      return false
    end
    local entry = inputs[input_head]
    if entry and consume_stdout(entry) and not stopped then
      inputs[input_head], input_head = nil, input_head + 1
    end
    if has_more() then
      schedule_drain()
    elseif exited ~= nil then
      finish_exit()
    end
    if input_head <= input_tail and not stopped then
      stats.input_resumes = (stats.input_resumes or 0) + 1
      return true
    end
    return false
  end
  local function schedule_input()
    if input_scheduled or stopped or input_head > input_tail then
      return
    end
    input_scheduled = true
    local function step()
      local more = input_step()
      if not more then
        input_scheduled = false
      end
      return more
    end
    if process_scheduler then
      process_scheduler:enqueue("protocol", step, { label = "receive" })
    else
      local function resume()
        if step() then
          vim.schedule(resume)
        end
      end
      vim.schedule(resume)
    end
  end
  local function handle_stdout(_, data)
    if stopped or not data or #data == 0 then
      return
    end
    stats.callbacks = stats.callbacks + 1
    local entry = { data = vim.list_slice(data), count = #data }
    if input_head <= input_tail then
      retain_input(entry)
    elseif not consume_stdout(entry) and not stopped then
      stats.input_resumes = (stats.input_resumes or 0) + 1
      retain_input(entry)
    end
    schedule_input()
    if has_more() then
      schedule_drain()
    elseif exited ~= nil then
      finish_exit()
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

---Mark the current protocol phase for diagnostics.
---@param phase string|nil "replay" while replaying agent history
function Process:mark_phase(phase)
  self.stats.phase = phase
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
