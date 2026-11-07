-- Tiny coroutine helpers so protocol flows can be written sequentially.
local Log = require("acp.log")

local M = {}

local on_error = nil

---@param fn fun(err: any)
function M.set_error_handler(fn)
  on_error = fn
end

---Resume a coroutine from the main loop.
---@param co thread
---@param ... any
function M.resume(co, ...)
  local n = select("#", ...)
  local args = { ... }
  vim.schedule(function()
    local ok, err = coroutine.resume(co, unpack(args, 1, n))
    if not ok then
      M.fail(err)
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

---Run an asynchronous function in a new coroutine.
---@param fn fun()
function M.run(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then
    M.fail(err)
  end
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
  register(function(ok, value)
    if settled then
      return
    end
    settled = true
    M.resume(co, ok, value)
  end)
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
