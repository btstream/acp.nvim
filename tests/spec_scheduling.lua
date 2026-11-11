return function(t)
  local work = require("acp.ui.work_scheduler")
  local metrics = require("acp.ui.render_metrics")
  local renderer = require("acp.ui.buffer_renderer")
  local process = require("acp.transport.process")

  local function manual(clock)
    local pending = {}
    local scheduler = work.new({
      budget_ms = 4,
      clock = clock or function()
        return 0
      end,
      defer = function(fn)
        pending[#pending + 1] = fn
      end,
    })
    local function run()
      local batch = pending
      pending = {}
      for _, fn in ipairs(batch) do
        fn()
      end
    end
    return scheduler, function()
      return #pending
    end, run
  end

  t.describe("work scheduler", function()
    t.it("runs higher priority first and one slice per job per round", function()
      local order = {}
      local scheduler, _, run = manual()
      scheduler:enqueue("background", function()
        order[#order + 1] = "background"
        return true
      end)
      scheduler:enqueue("layout", function()
        order[#order + 1] = "layout"
        return true
      end)
      scheduler:enqueue("protocol", function()
        order[#order + 1] = "protocol"
        return true
      end)
      scheduler:enqueue("ui", function()
        order[#order + 1] = "ui"
        return true
      end)
      run()
      t.eq({ "ui", "protocol", "layout", "background" }, order)
    end)

    t.it("preserves FIFO order inside a priority", function()
      local order = {}
      local scheduler, _, run = manual()
      for i = 1, 4 do
        scheduler:enqueue("protocol", function()
          order[#order + 1] = i
          return false
        end)
      end
      run()
      t.eq({ 1 }, order, "only one protocol job may run per round")
      run()
      run()
      run()
      t.eq({ 1, 2, 3, 4 }, order)
    end)

    t.it("finishes a protocol continuation before starting the next job", function()
      local scheduler, _, run = manual()
      local order, n = {}, 0
      scheduler:enqueue("protocol", function()
        n = n + 1
        order[#order + 1] = "a" .. n
        return n < 3
      end)
      scheduler:enqueue("protocol", function()
        order[#order + 1] = "b"
      end)
      for _ = 1, 4 do
        run()
      end
      t.eq({ "a1", "a2", "a3", "b" }, order)
    end)

    t.it("gives lower priorities a turn under a saturated UI queue", function()
      local now, seen = 0, false
      local scheduler, _, run = manual(function()
        return now
      end)
      scheduler:enqueue("ui", function()
        now = now + 4e6
        return true
      end)
      scheduler:enqueue("background", function()
        seen = true
      end)
      run()
      t.falsy(seen)
      run()
      t.truthy(seen)
      t.truthy(scheduler.stats.starved > 0)
    end)

    t.it("pauses between slices once the shared budget is spent", function()
      local now, calls = 0, {}
      local scheduler, _, run = manual(function()
        return now
      end)
      scheduler:enqueue("ui", function()
        calls[#calls + 1] = "ui"
        now = now + 4e6
        return true
      end)
      scheduler:enqueue("protocol", function()
        calls[#calls + 1] = "protocol"
        return true
      end)
      run()
      t.eq({ "ui" }, calls, "a spent budget must not start another slice")
      t.truthy(scheduler:depth() > 0)
    end)

    t.it("contains a failing job and keeps the queue moving", function()
      local ran = {}
      local log = require("acp.log")
      local original, errors = log.error, {}
      log.error = function(fmt, ...)
        errors[#errors + 1] = string.format(fmt, ...)
      end
      local ok, err = pcall(function()
        local scheduler, _, run = manual()
        scheduler:enqueue("ui", function()
          error("broken job")
        end)
        scheduler:enqueue("ui", function()
          ran[#ran + 1] = true
        end)
        run()
        run()
        t.eq({ true }, ran)
        t.eq(1, #errors)
        t.match("broken job", errors[1])
      end)
      log.error = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("cancels queued and in-flight work by key", function()
      local ran = {}
      local scheduler, _, run = manual()
      scheduler:enqueue("decoration", function()
        ran[#ran + 1] = "a"
        return true
      end, { key = 1 })
      local b = scheduler:enqueue("decoration", function()
        ran[#ran + 1] = "b"
        return true
      end, { key = 2 })
      t.eq(
        1,
        scheduler:cancel(function(job)
          return job.key == 2
        end)
      )
      t.truthy(b.cancelled)
      run()
      t.eq({ "a" }, ran)
      t.eq(
        1,
        scheduler:cancel(function()
          return true
        end)
      )
    end)

    t.it("flushes to idle and reports its counters", function()
      local n = 0
      local scheduler = work.new({ budget_ms = 4 })
      scheduler:enqueue("layout", function()
        n = n + 1
        return n < 2
      end)
      t.truthy(scheduler:flush(500))
      t.eq(2, n)
      t.eq(0, scheduler:depth())
      t.truthy(scheduler.stats.max_slice_ms >= 0)
      t.truthy(scheduler.stats.runs > 0)
    end)
  end)

  t.describe("render metrics", function()
    t.it("records latency buckets, overflow and bounded slow-task details", function()
      local view = { config = { ui = { render = { profile = true } } } }
      local now = 0
      local original = vim.uv.hrtime
      vim.uv.hrtime = function()
        return now
      end
      local ok, err = pcall(function()
        local labels = { 0.5, 3, 11, 40, 900, 1500 }
        for i, value in ipairs(labels) do
          now = value * 1e6
          metrics.record(view, "layout", 1, { id = "b" .. i })
        end
        local entry = view.metrics.layout
        t.eq(6, entry.count)
        t.eq(1, entry.buckets[1])
        t.eq(1, entry.buckets[3])
        t.eq(1, entry.buckets[5])
        t.eq(1, entry.buckets[7])
        t.eq(1, entry.buckets[10 + 1])
        t.eq(1, entry.overflow)
        t.truthy(#view.slow_tasks <= metrics.SLOW_KEEP)
        t.eq("b6", view.slow_tasks[#view.slow_tasks].context.id)
        for i = 1, 40 do
          now = 20e6
          metrics.record(view, "write", 1, { id = i })
        end
        t.eq(metrics.SLOW_KEEP, #view.slow_tasks)
        t.eq(40, view.slow_tasks[#view.slow_tasks].context.id)
      end)
      vim.uv.hrtime = original
      if not ok then
        error(err, 0)
      end
    end)

    t.it("has no overhead or records when profiling is off", function()
      local view = { config = { ui = { render = { profile = false } } } }
      t.eq(nil, metrics.start(view))
      metrics.record(view, "layout", nil)
      t.eq(nil, view.metrics)
      t.eq(nil, view.slow_tasks)
      local described = metrics.describe({ id = "x", kind = "tool", text = "abc", content = { {} } })
      t.eq("x", described.id)
      t.eq(3, described.text_bytes)
      t.eq(1, described.items)
    end)
  end)

  t.describe("bounded commits", function()
    t.it("yields while writing and keeps the final buffer identical", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local lines, meta = {}, {}
      for i = 1, 12 do
        lines[i] = "row " .. i
        meta[i] = { segments = { { s = 0, e = 3, group = "Identifier" }, { s = 4, e = -1, group = "Identifier" } } }
      end
      local co = renderer.write_chunked(buf, lines, meta, {}, true, 3)
      local yields = 0
      while coroutine.status(co) ~= "dead" do
        local ok, err = coroutine.resume(co)
        t.truthy(ok, err)
        t.falsy(vim.bo[buf].modifiable, "a yielded write exposed an editable transcript")
        yields = yields + 1
      end
      t.truthy(yields >= 4, "write did not yield between row batches")
      t.eq(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      t.truthy(#vim.api.nvim_buf_get_extmarks(buf, renderer.ns, 0, -1, {}) > 0)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    t.it("slices an incremental write too and reports no change when equal", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
      local co = renderer.write_chunked(buf, { "a", "b" }, {}, { "a", "b" }, false, 1)
      local ok, changed = coroutine.resume(co)
      t.truthy(ok)
      t.falsy(changed)
      co = renderer.write_chunked(buf, { "a", "c" }, { {}, {} }, { "a", "b" }, false, 1)
      while coroutine.status(co) ~= "dead" do
        local resumed, err = coroutine.resume(co)
        t.truthy(resumed, err)
      end
      t.eq({ "a", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  t.describe("bounded receive input", function()
    local function with_process(opts, fn)
      local original_start, original_stop = vim.fn.jobstart, vim.fn.jobstop
      local callbacks
      vim.fn.jobstart = function(_, value)
        callbacks = value
        return 999999
      end
      vim.fn.jobstop = function() end
      local ok, err = pcall(function()
        local values = { command = "mock", on_line = function() end, on_exit = function() end }
        for k, v in pairs(opts or {}) do
          values[k] = v
        end
        fn(assert(process.spawn(values)), callbacks)
      end)
      vim.fn.jobstart, vim.fn.jobstop = original_start, original_stop
      if not ok then
        error(err, 0)
      end
    end

    t.it("defers the unprocessed tail and resumes it in order", function()
      local seen, scheduler = {}, work.new({ budget_ms = 4 })
      with_process({
        max_pending_bytes = 0,
        scheduler = scheduler,
        on_line = function(line)
          seen[#seen + 1] = line
        end,
      }, function(proc, callbacks)
        local data = {}
        for i = 1, 20000 do
          data[i] = "m" .. i
        end
        data[#data + 1] = ""
        callbacks.on_stdout(999999, data)
        t.truthy((proc.stats.input_resumes or 0) > 0, "a large burst was decoded in one callback")
        t.truthy(scheduler:depth() > 0)
        t.truthy(scheduler:flush(3000))
        t.eq(20000, #seen)
        for i = 1, 20000 do
          t.eq("m" .. i, seen[i])
        end
      end)
    end)

    for _, shared in ipairs({ false, true }) do
      t.it("orders callback tails and exit with scheduler=" .. tostring(shared), function()
        local seen, scheduler = {}, shared and work.new({ budget_ms = 4 }) or nil
        local clock, now = vim.uv.hrtime, 0
        vim.uv.hrtime = function()
          now = now + 1000
          return now
        end
        local ok, err = pcall(function()
          with_process({
            scheduler = scheduler,
            max_pending_bytes = 0,
            dispatch_budget_ms = 0.004,
            on_line = function(line)
              seen[#seen + 1] = line
            end,
            on_exit = function()
              seen[#seen + 1] = "EXIT"
            end,
          }, function(_, callbacks)
            callbacks.on_stdout(999999, { "a", "par" })
            callbacks.on_stdout(999999, { "tial", "last", "" })
            callbacks.on_exit(999999, 0)
            t.truthy(vim.wait(3000, function()
              return seen[#seen] == "EXIT"
            end, 1))
            t.eq({ "a", "partial", "last", "EXIT" }, seen)
          end)
        end)
        vim.uv.hrtime = clock
        if not ok then
          error(err, 0)
        end
      end)
    end

    t.it("includes deferred raw input in the receive limit", function()
      with_process({ max_pending_bytes = 256, dispatch_budget_ms = 0.000001 }, function(proc, callbacks)
        callbacks.on_stdout(999999, { "first", string.rep("x", 512), "" })
        t.truthy(proc.stats.overflow_at)
        t.falsy(proc:is_alive())
      end)
    end)

    t.it("drops the deferred tail when the process stops", function()
      local seen, scheduler = {}, work.new({ budget_ms = 4 })
      with_process({
        max_pending_bytes = 0,
        scheduler = scheduler,
        on_line = function(line)
          seen[#seen + 1] = line
        end,
      }, function(proc, callbacks)
        local data = {}
        for i = 1, 200 do
          data[i] = "m" .. i
        end
        callbacks.on_stdout(999999, data)
        local accepted = #seen
        proc:stop(true)
        scheduler:flush(1000)
        t.eq(accepted, #seen)
      end)
    end)
  end)
end
