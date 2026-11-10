-- Deterministic receive-limit and diagnostics tests. `jobstart` is stubbed so a
-- single callback can be made as large (or as slow) as the scenario needs.
return function(t)
  local process = require("acp.transport.process")

  local function capture_log()
    local Log = require("acp.log")
    local lines, original = {}, Log.error
    Log.error = function(fmt, ...)
      lines[#lines + 1] = string.format(fmt, ...)
      return original(fmt, ...)
    end
    return lines, function()
      Log.error = original
    end
  end

  ---Run a spawn with a controllable stdout callback.
  ---@param opts table spawn overrides
  ---@param fn fun(callbacks: table, proc: table)
  local function with_process(opts, fn)
    local original_start, original_stop = vim.fn.jobstart, vim.fn.jobstop
    local callbacks, stops = nil, 0
    vim.fn.jobstart = function(_, value)
      callbacks = value
      return 999999
    end
    vim.fn.jobstop = function()
      stops = stops + 1
    end
    local ok, err = pcall(function()
      local values = {
        command = "mock",
        on_line = function() end,
        on_exit = function() end,
      }
      for k, v in pairs(opts or {}) do
        values[k] = v
      end
      local proc = assert(process.spawn(values))
      fn(callbacks, proc, function()
        return stops
      end)
    end)
    vim.fn.jobstart, vim.fn.jobstop = original_start, original_stop
    if not ok then
      error(err, 0)
    end
  end

  local function burst(count, size)
    local data = {}
    for i = 1, count do
      data[i] = string.rep("x", size)
    end
    data[#data + 1] = ""
    return data
  end

  -- One element containing many lines, like a buffered pipe read. jobstart
  -- normally splits on newlines, but the callback may still be handed a
  -- multi-line item, and the decoder must handle it.
  local function record(index, size)
    return string.format("%06d", index) .. string.rep("x", size - 6)
  end

  local function bulk(count, size)
    local data = {}
    for i = 1, count do
      data[i] = record(i, size)
    end
    return { table.concat(data, "\n") .. "\n" }
  end

  local function sleep_ms(ms)
    local start = vim.uv.hrtime()
    while vim.uv.hrtime() - start < ms * 1e6 do
    end
  end

  t.describe("transport receive limits", function()
    t.it("drains between input elements instead of buffering the whole callback", function()
      with_process({ max_pending_bytes = 4096 }, function(callbacks, proc)
        callbacks.on_stdout(999999, burst(20, 100))
        vim.wait(20)
        -- 3.2 KiB total against a 4 KiB budget: without interleaved draining this
        -- would have to hold the entire burst and could not finish inside it.
        t.eq(nil, proc.stats.overflow_at)
        t.truthy(vim.wait(200, function()
          return proc.stats.dispatched_messages == 20
        end, 5))
        t.truthy(proc.stats.pending_high_water < 4096)
        t.truthy(proc.stats.dispatches > 1)
      end)
    end)

    t.it("reports an overflow with actionable diagnostics when dispatch is slower than input", function()
      local logged, restore = capture_log()
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 1024,
          dispatch_budget_ms = 1,
          on_line = function()
            sleep_ms(2)
          end,
        }, function(callbacks, proc, stops)
          proc:mark_phase("replay")
          -- Establish pressure first so the interleaved drain runs; the second
          -- bulk then exceeds the remaining budget.
          callbacks.on_stdout(999999, bulk(6, 100))
          t.truthy(vim.wait(1000, function()
            return proc.stats.dispatched_messages > 0
          end, 5))
          callbacks.on_stdout(999999, bulk(30, 100))
          t.truthy(stops() > 0, "the transport must stop")
          t.eq(false, proc:is_alive())
          t.truthy(proc.stats.overflow_at)
          t.eq("replay", proc.stats.phase)
          t.truthy(proc.stats.dispatched_messages > 0, "some input should have been consumed first")
          local text = table.concat(logged, "\n")
          t.match("exceeds max_pending_bytes", text)
          t.match("phase=replay", text)
          t.match("limit=1024", text)
          t.match("callback_msg=", text)
          t.match("max_callback=", text)
          t.falsy(text:find("xxxxxxxxxx", 1, true), "summary must not embed payloads")
        end)
      end)
      restore()
      if not ok then
        error(err)
      end
    end)

    t.it("marks a live overflow when no replay phase is active", function()
      local logged, restore = capture_log()
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 1024,
          dispatch_budget_ms = 1,
          on_line = function()
            sleep_ms(2)
          end,
        }, function(callbacks)
          callbacks.on_stdout(999999, bulk(30, 100))
          t.match("phase=live", table.concat(logged, "\n"))
        end)
      end)
      restore()
      if not ok then
        error(err)
      end
    end)

    t.it("counts sustained backlog across batches and records dispatch cost", function()
      with_process({
        dispatch_budget_ms = 1,
        on_line = function()
          sleep_ms(2)
        end,
      }, function(callbacks, proc)
        callbacks.on_stdout(999999, { "one", "two", "three", "four", "five", "" })
        t.truthy(vim.wait(1000, function()
          return proc.stats.dispatched_messages == 5
        end, 5))
        t.truthy(proc.stats.dispatches > 1, "the burst must be split across batches")
        t.truthy(proc.stats.max_dispatch_ms > 0)
        t.truthy(proc.stats.slowest_line_ms > 0)
        t.eq(5, proc.stats.max_callback_messages)
      end)
    end)

    t.it("stops consuming after overflow instead of reviving the queue", function()
      with_process({
        max_pending_bytes = 1024,
        dispatch_budget_ms = 1,
        on_line = function()
          sleep_ms(2)
        end,
      }, function(callbacks, proc)
        callbacks.on_stdout(999999, bulk(6, 100))
        callbacks.on_stdout(999999, bulk(40, 100))
        local accepted = proc.stats.received_messages
        t.truthy(accepted > 0 and accepted < 46)
        callbacks.on_stdout(999999, burst(5, 100))
        t.eq(accepted, proc.stats.received_messages, "post-overflow input must not be accepted")
      end)
    end)

    t.it("keeps per-callback counters correct across many callbacks", function()
      with_process({}, function(callbacks, proc)
        for _ = 1, 5 do
          callbacks.on_stdout(999999, { "a", "b", "" })
        end
        t.eq(5, proc.stats.callbacks)
        t.eq(10, proc.stats.received_messages)
        t.eq(2, proc.stats.max_callback_messages)
        t.truthy(vim.wait(500, function()
          return proc.stats.dispatched_messages == 10
        end, 5))
      end)
    end)

    t.it("records the largest message and callback without keeping them", function()
      with_process({}, function(callbacks, proc)
        callbacks.on_stdout(999999, { string.rep("a", 300), "" })
        callbacks.on_stdout(999999, { string.rep("b", 500), string.rep("c", 40), "" })
        t.eq(500, proc.stats.max_line_bytes_seen)
        t.eq(542, proc.stats.max_callback_bytes)
        t.eq(2, proc.stats.callbacks)
      end)
    end)

    t.it("never disconnects when the total limit is zero", function()
      with_process({
        max_pending_bytes = 0,
        dispatch_budget_ms = 1,
        on_line = function()
          sleep_ms(1)
        end,
      }, function(callbacks, proc, stops)
        callbacks.on_stdout(999999, bulk(60, 200))
        t.eq(0, stops())
        t.eq(true, proc.stats.unbounded)
        t.eq(nil, proc.stats.overflow_at)
        t.truthy(vim.wait(2000, function()
          return proc.stats.dispatched_messages == 60
        end, 5))
        t.truthy(proc.stats.memory_high_water > 0)
      end)
    end)

    t.it("warns once at each escalating memory level", function()
      local Log = require("acp.log")
      local warnings, original = {}, Log.warn
      Log.warn = function(fmt, ...)
        warnings[#warnings + 1] = string.format(fmt, ...)
      end
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          dispatch_budget_ms = 1,
          warn_levels = { 1000, 2000, 4000 },
          on_line = function()
            sleep_ms(1)
          end,
        }, function(callbacks, proc)
          callbacks.on_stdout(999999, bulk(60, 200))
          vim.wait(2000, function()
            return proc.stats.dispatched_messages == 60
          end, 5)
          t.truthy(proc.stats.warn_level >= 1)
          t.eq(proc.stats.warn_level, #warnings, "each level must warn exactly once")
          for _, text in ipairs(warnings) do
            t.match("MiB", text)
          end
        end)
      end)
      Log.warn = original
      if not ok then
        error(err)
      end
    end)

    t.it("spills to disk above the threshold and preserves order", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local seen = {}
      with_process({
        max_pending_bytes = 0,
        spill_bytes = 2048,
        spill_dir = dir,
        dispatch_budget_ms = 1,
        on_line = function(line)
          seen[#seen + 1] = line
          sleep_ms(2)
        end,
      }, function(callbacks, proc)
        callbacks.on_stdout(999999, bulk(80, 100))
        t.truthy(vim.wait(5000, function()
          return proc.stats.dispatched_messages == 80
        end, 5))
        t.truthy(proc.stats.spill_records > 0, "no record was spilled")
        t.truthy(proc.stats.spill_reads > 0, "spilled records were not read back")
        t.eq(80, #seen)
        local expected = {}
        for i = 1, 80 do
          expected[i] = record(i, 100)
        end
        t.eq(expected, seen, "spill must preserve order exactly")
        proc:stop(true)
        t.eq({}, vim.fn.readdir(dir), "spill file must be removed on stop")
      end)
      vim.fn.delete(dir, "rf")
    end)

    t.it("treats max_pending_bytes as an emergency ceiling when spilling is on", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      with_process({
        max_pending_bytes = 8192,
        spill_bytes = 4096,
        spill_dir = dir,
        dispatch_budget_ms = 1,
        on_line = function()
          sleep_ms(1)
        end,
      }, function(callbacks, proc)
        -- A finite ceiling includes writes still in flight. Give asynchronous
        -- I/O a chance to complete between bounded receive bursts.
        for batch = 1, 10 do
          callbacks.on_stdout(999999, bulk(20, 200))
          t.truthy(vim.wait(5000, function()
            return proc.stats.dispatched_messages == batch * 20
          end, 5))
        end
        t.eq(nil, proc.stats.overflow_at, "spilling must keep the queue under the ceiling")
        t.truthy(proc.stats.spill_records > 0)
        proc:stop(true)
      end)
      vim.fn.delete(dir, "rf")
    end)

    t.it("keeps serving the queue when opening the spill file fails", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local original = vim.uv.fs_mkstemp
      vim.uv.fs_mkstemp = function()
        return nil, "nope", "EIO"
      end
      local seen = 0
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          spill_bytes = 1024,
          spill_dir = dir,
          dispatch_budget_ms = 1,
          on_line = function()
            seen = seen + 1
            sleep_ms(1)
          end,
        }, function(callbacks, proc)
          callbacks.on_stdout(999999, bulk(40, 100))
          t.truthy(vim.wait(2000, function()
            return seen == 40
          end, 5))
          t.truthy(proc.stats.spill_failures > 0)
          t.eq(nil, proc.stats.overflow_at)
        end)
      end)
      vim.uv.fs_mkstemp = original
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err)
      end
    end)

    t.it("falls back to memory when a spill write fails mid-stream", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local original = vim.uv.fs_write
      local calls, seen = 0, {}
      vim.uv.fs_write = function(fd, data, offset)
        calls = calls + 1
        if calls > 0 then
          return nil, "ENOSPC"
        end
        return original(fd, data, offset)
      end
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          spill_bytes = 1024,
          spill_dir = dir,
          dispatch_budget_ms = 1,
          on_line = function(line)
            seen[#seen + 1] = line
            sleep_ms(1)
          end,
        }, function(callbacks, proc)
          callbacks.on_stdout(999999, bulk(60, 100))
          t.truthy(vim.wait(3000, function()
            return #seen == 60
          end, 5))
          t.truthy(proc.stats.spill_failures > 0)
          for i = 1, #seen do
            t.eq(record(i, 100), seen[i], "fallback lost or reordered a line")
          end
        end)
      end)
      vim.uv.fs_write = original
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err)
      end
    end)

    t.it("keeps committed records before memory after a partial write fails", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local original = vim.uv.fs_write
      local calls, seen = 0, {}
      vim.uv.fs_write = function(fd, data, offset, callback)
        calls = calls + 1
        if calls == 2 then
          -- First record is half written, then the next call fails.
          local part = data:sub(1, math.max(1, math.floor(#data / 2)))
          original(fd, part, offset)
          return nil, "ENOSPC"
        end
        return original(fd, data, offset, callback)
      end
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          spill_bytes = 1024,
          spill_dir = dir,
          dispatch_budget_ms = 1,
          on_line = function(line)
            seen[#seen + 1] = line
            sleep_ms(1)
          end,
        }, function(callbacks, proc)
          callbacks.on_stdout(999999, bulk(60, 100))
          t.truthy(vim.wait(3000, function()
            return #seen == 60
          end, 5))
          t.truthy(proc.stats.spill_failures > 0)
          for i = 1, #seen do
            t.eq(record(i, 100), seen[i], "partial write corrupted the stream")
          end
        end)
      end)
      vim.uv.fs_write = original
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err)
      end
    end)

    t.it("closes the connection instead of continuing after a spill read fails", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local original = vim.uv.fs_read
      local calls = 0
      vim.uv.fs_read = function(fd, size, offset)
        calls = calls + 1
        if calls > 0 then
          return nil, "EIO"
        end
        return original(fd, size, offset)
      end
      local Log = require("acp.log")
      local warnings, original_warn = {}, Log.error
      Log.error = function(fmt, ...)
        warnings[#warnings + 1] = string.format(fmt, ...)
      end
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          spill_bytes = 1024,
          spill_dir = dir,
          dispatch_budget_ms = 1,
          on_line = function()
            sleep_ms(1)
          end,
        }, function(callbacks, proc, stops)
          callbacks.on_stdout(999999, bulk(60, 100))
          t.truthy(vim.wait(3000, function()
            return proc.stats.spill_failures > 0
          end, 5))
          t.falsy(proc:is_alive())
          t.truthy(stops() > 0)
          t.truthy(table.concat(warnings, "\n"):find("spill read failed", 1, true))
          t.eq({}, vim.fn.readdir(dir))
        end)
      end)
      vim.uv.fs_read = original
      Log.error = original_warn
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err)
      end
    end)

    t.it("removes spill files older than the TTL only", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local stale, fresh = dir .. "/acp-spill-old", dir .. "/acp-spill-new"
      local other = dir .. "/other"
      for _, path in ipairs({ stale, fresh, other }) do
        vim.fn.writefile({ "x" }, path)
      end
      vim.uv.fs_utime(stale, os.time() - 2 * 24 * 3600, os.time() - 2 * 24 * 3600)
      process.sweep_spill(dir)
      t.eq({ "acp-spill-new", "other" }, vim.fn.readdir(dir))
      vim.fn.delete(dir, "rf")
    end)

    t.it("does not create a spill file when spill_bytes is zero", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      with_process({
        max_pending_bytes = 0,
        spill_bytes = 0,
        spill_dir = dir,
        dispatch_budget_ms = 1,
        on_line = function() end,
      }, function(callbacks, proc)
        callbacks.on_stdout(999999, bulk(60, 100))
        vim.wait(100)
        t.eq(nil, proc.stats.spill_path)
        t.eq({}, vim.fn.readdir(dir))
      end)
      vim.fn.delete(dir, "rf")
    end)

    t.it("still enforces max_line_bytes on a partial message", function()
      local logged, restore = capture_log()
      local ok, err = pcall(function()
        with_process({ max_line_bytes = 64 }, function(callbacks)
          callbacks.on_stdout(999999, { string.rep("x", 200) })
          local text = table.concat(logged, "\n")
          t.match("max_line_bytes", text)
          t.match("200 > 64", text)
        end)
      end)
      restore()
      if not ok then
        error(err)
      end
    end)

    t.it("does not dispatch one slow handler per element after the callback deadline", function()
      local handled = 0
      with_process({
        max_pending_bytes = 0,
        dispatch_budget_ms = 1,
        on_line = function()
          handled = handled + 1
          sleep_ms(2)
        end,
      }, function(callbacks, proc)
        -- A small cap is not needed to trigger pressure: use lines above pump_at.
        local data = burst(30, 300 * 1024)
        callbacks.on_stdout(999999, data)
        t.truthy(handled <= 1, "expired callback continued running slow handlers")
        t.truthy(vim.wait(2000, function()
          return proc.stats.dispatched_messages == 30
        end, 5))
      end)
    end)

    t.it("keeps an in-flight asynchronous spill charged to the emergency ceiling", function()
      with_process({ max_pending_bytes = 4096, spill_bytes = 1024 }, function(callbacks, proc, stops)
        callbacks.on_stdout(999999, bulk(80, 100))
        t.truthy(stops() > 0)
        t.truthy(proc.stats.overflow_at)
        t.falsy(proc:is_alive())
        t.truthy(vim.wait(1000, function()
          return proc.stats.spill_path == nil
        end, 5))
      end)
    end)

    t.it("starts stale-file cleanup and releases the spool before normal exit", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local stale = dir .. "/acp-spill-stale"
      vim.fn.writefile({ "old" }, stale)
      vim.uv.fs_utime(stale, os.time() - 2 * 24 * 3600, os.time() - 2 * 24 * 3600)
      local seen, exits = {}, 0
      with_process({
        max_pending_bytes = 0,
        spill_bytes = 2048,
        spill_dir = dir,
        on_line = function(line)
          seen[#seen + 1] = line
        end,
        on_exit = function()
          exits = exits + 1
          t.eq({}, vim.fn.readdir(dir), "normal exit leaked a spill file")
        end,
      }, function(callbacks, proc)
        t.eq({}, vim.fn.readdir(dir), "startup did not sweep stale files")
        callbacks.on_stdout(999999, bulk(100, 100))
        callbacks.on_exit(999999, 0)
        t.truthy(vim.wait(2000, function()
          return exits == 1
        end, 5))
        t.eq(100, #seen)
        t.eq({}, vim.fn.readdir(dir))
        for i, line in ipairs(seen) do
          t.eq(record(i, 100), line)
        end
        t.eq(nil, proc.stats.spill_path)
        callbacks.on_exit(999999, 0)
        vim.wait(10)
        t.eq(1, exits)
      end)
      vim.fn.delete(dir, "rf")
    end)

    t.it("cleans up safely when stopped during an asynchronous write", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local seen = 0
      with_process({
        max_pending_bytes = 0,
        spill_bytes = 1024,
        spill_dir = dir,
        on_line = function()
          seen = seen + 1
        end,
      }, function(callbacks, proc)
        callbacks.on_stdout(999999, bulk(30, 100))
        proc:stop(true)
        callbacks.on_exit(999999, 0)
        t.truthy(vim.wait(2000, function()
          return proc.stats.spill_path == nil
        end, 5))
        t.eq({}, vim.fn.readdir(dir))
        t.eq(0, seen)
      end)
      vim.fn.delete(dir, "rf")
    end)

    t.it("receives a fragmented message above 16 MiB with the default limits", function()
      local defaults = require("acp.config").defaults.transport
      local seen, bytes = 0, 0
      with_process({
        max_line_bytes = defaults.max_line_bytes,
        max_pending_bytes = defaults.max_pending_bytes,
        spill_bytes = defaults.spill_bytes,
        on_line = function(line)
          seen = seen + 1
          bytes = #line
        end,
      }, function(callbacks, proc)
        local piece = string.rep("x", 1024 * 1024)
        for _ = 1, 17 do
          callbacks.on_stdout(999999, { piece })
        end
        callbacks.on_stdout(999999, { "", "" })
        t.truthy(vim.wait(2000, function()
          return seen == 1
        end, 5))
        t.eq(17 * 1024 * 1024, bytes)
        t.eq(nil, proc.stats.overflow_at)
      end)
    end)

    t.it("handles short asynchronous reads even when the record header is split", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local original = vim.uv.fs_read
      vim.uv.fs_read = function(fd, size, offset, callback)
        return original(fd, math.min(size, 2), offset, callback)
      end
      local seen = {}
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          spill_bytes = 1024,
          spill_dir = dir,
          on_line = function(line)
            seen[#seen + 1] = line
          end,
        }, function(callbacks, proc)
          callbacks.on_stdout(999999, bulk(20, 100))
          t.truthy(vim.wait(5000, function()
            return #seen == 20
          end, 5))
          for i, line in ipairs(seen) do
            t.eq(record(i, 100), line)
          end
          t.eq(0, proc.stats.spill_failures)
        end)
      end)
      vim.uv.fs_read = original
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err, 0)
      end
    end)

    t.it("rejects an incomplete message above the pending cap and releases its buffer", function()
      with_process({ max_pending_bytes = 1024, max_line_bytes = 4096 }, function(callbacks, proc, stops)
        callbacks.on_stdout(999999, { string.rep("x", 2048) })
        t.truthy(stops() > 0)
        t.truthy(proc.stats.overflow_at)
        t.eq(0, proc.decoder.buffered)
        t.eq({}, proc.decoder.parts)
      end)
    end)

    t.it("waits for an asynchronous read callback before releasing its fd on stop", function()
      local dir = vim.fn.tempname() .. "-spill"
      vim.fn.mkdir(dir, "p")
      local original, release = vim.uv.fs_read, nil
      vim.uv.fs_read = function(fd, size, offset, callback)
        return original(fd, size, offset, function(err, data)
          release = function()
            callback(err, data)
          end
        end)
      end
      local seen, exits = 0, 0
      local ok, err = pcall(function()
        with_process({
          max_pending_bytes = 0,
          spill_bytes = 1024,
          spill_dir = dir,
          on_line = function()
            seen = seen + 1
          end,
          on_exit = function()
            exits = exits + 1
          end,
        }, function(callbacks, proc)
          callbacks.on_stdout(999999, bulk(30, 100))
          t.truthy(vim.wait(2000, function()
            return release ~= nil
          end, 5))
          proc:stop(true)
          callbacks.on_exit(999999, 0)
          t.truthy(proc.stats.spill_path, "fd was released before its I/O callback")
          release()
          t.truthy(vim.wait(2000, function()
            return proc.stats.spill_path == nil and exits == 1
          end, 5))
          t.eq(0, seen)
          t.eq({}, vim.fn.readdir(dir))
        end)
      end)
      vim.uv.fs_read = original
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err, 0)
      end
    end)
  end)
end
