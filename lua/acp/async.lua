-- Tiny coroutine helpers so protocol flows can be written sequentially.
local Log = require("acp.log")

local M = {}

local on_error = nil

-- Per-coroutine cleanup handlers. They run when a coroutine dies, no matter at
-- which yield point it failed, which is what a `finally` would do. Using pcall
-- for this is not an option: Lua cannot yield across a pcall boundary.
local finalizers = setmetatable({}, { __mode = "k" })

local run_finalizers

---@param fn fun(err: any)
function M.set_error_handler(fn)
  on_error = fn
end

---Resume a coroutine from the main loop.
---@param co thread
---@param ... any
function M.resume(co, ...)
  local status = coroutine.status(co)
  if status == "dead" then
    Log.warn("ignoring resume of a dead coroutine")
    return
  end
  -- A `running` coroutine is the caller itself, which is about to yield: the
  -- common case is a callback that fired synchronously inside `await` or
  -- `Client:request`. Dropping the resume left such a coroutine suspended
  -- forever, so it is scheduled instead and lands after the yield.
  local n = select("#", ...)
  local args = { ... }
  vim.schedule(function()
    if coroutine.status(co) ~= "suspended" then
      return
    end
    local ok, err = coroutine.resume(co, unpack(args, 1, n))
    if not ok then
      run_finalizers(co)
      M.fail(err)
      return
    end
    -- A resumed coroutine that has finished is done; run its cleanup.
    if coroutine.status(co) == "dead" then
      run_finalizers(co)
    end
  end)
end

---@param err any
function M.fail(err)
  local message = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
  Log.error("async failure: %s", message)
  if on_error then
    pcall(on_error, err)
  end
end

---Register a cleanup function for the running coroutine.
---
---Equivalent to a `finally` block: it runs exactly once, either when the
---coroutine returns or when it raises. `pcall` cannot be used for this because
---it is not yieldable, so cleanup lives here instead.
---@param fn fun()
function M.finally(fn)
  local co = coroutine.running()
  if not co then
    -- Called outside a coroutine: there is no scope to tie cleanup to.
    return
  end
  local list = finalizers[co]
  if not list then
    list = {}
    finalizers[co] = list
  end
  list[#list + 1] = fn
end

---Run and clear the cleanup handlers registered for `co`.
---@param co thread
function run_finalizers(co)
  local list = finalizers[co]
  if not list then
    return
  end
  finalizers[co] = nil
  for i = #list, 1, -1 do
    local ok, err = pcall(list[i])
    if not ok then
      Log.error("async finalizer failed: %s", tostring(err))
    end
  end
end

---Run an asynchronous function in a new coroutine.
---@param fn fun()
---@param on_error fun(err: any)|nil invoked when the first resume raises
---@return thread
function M.run(fn, on_error)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then
    run_finalizers(co)
    M.fail(err)
    if on_error then
      pcall(on_error, err)
    end
  elseif coroutine.status(co) == "dead" then
    run_finalizers(co)
  end
  return co
end

---Yield the current coroutine until `register` invokes its callback.
---@param register fun(done: fun(ok: boolean, value: any))
---@return any ok, any value
function M.await(register)
  local co = coroutine.running()
  if not co then
    error("acp.async.await called outside a coroutine")
  end
  local settled = false
  local yielded = false
  local result
  register(function(ok, value)
    if settled then
      return
    end
    settled = true
    if not yielded then
      -- The callback ran before `coroutine.yield()` below: the coroutine is
      -- still running, so resuming it would be lost. Hand the value back
      -- directly instead (see the yield branch).
      result = { ok = ok, value = value }
      return
    end
    M.resume(co, ok, value)
  end)
  if result then
    return result.ok, result.value
  end
  yielded = true
  return coroutine.yield()
end

---Wrap a callback style function into a coroutine friendly one.
---@param fn fun(cb: fun(ok: boolean, value: any))
---@return boolean ok, any value
function M.call(fn)
  return M.await(function(done)
    fn(done)
  end)
end

---Sleep for `ms` milliseconds without blocking the event loop.
---@param ms integer
function M.sleep(ms)
  M.await(function(done)
    vim.defer_fn(function()
      done(true, nil)
    end, ms)
  end)
end

return M
