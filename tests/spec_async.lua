-- Regression tests for coroutine plumbing.
return function(t)
  local async = require("acp.async")

  local function run_until(fn, timeout)
    local done = false
    async.run(function()
      fn()
      done = true
    end)
    vim.wait(timeout or 1000, function()
      return done
    end)
    return done
  end

  t.describe("coroutine suspension", function()
    t.it("resolves an await that settles synchronously", function()
      local seen
      local done = run_until(function()
        local ok, value = async.await(function(cb)
          cb(true, "sync")
        end)
        seen = { ok = ok, value = value }
      end)
      t.truthy(done, "the coroutine never finished after a synchronous settle")
      t.eq({ ok = true, value = "sync" }, seen)
    end)

    t.it("resolves an await that settles later", function()
      local seen
      local done = run_until(function()
        local ok, value = async.await(function(cb)
          vim.defer_fn(function()
            cb(true, "async")
          end, 5)
        end)
        seen = { ok = ok, value = value }
      end)
      t.truthy(done, "the coroutine never finished after an asynchronous settle")
      t.eq({ ok = true, value = "async" }, seen)
    end)

    t.it("runs finalizers once when the coroutine finishes", function()
      local calls = 0
      local done = run_until(function()
        async.finally(function()
          calls = calls + 1
        end)
      end)
      vim.wait(50)
      t.truthy(done)
      t.eq(1, calls)
    end)

    t.it("runs finalizers when the coroutine raises", function()
      local calls = 0
      local failures = {}
      local previous = nil
      async.set_error_handler(function(err)
        failures[#failures + 1] = err
      end)
      async.run(function()
        async.finally(function()
          calls = calls + 1
        end)
        error("boom")
      end)
      vim.wait(100, function()
        return #failures > 0
      end)
      t.eq(1, calls, "the finalizer did not run after a failure")
      async.set_error_handler(previous)
    end)
  end)
end
