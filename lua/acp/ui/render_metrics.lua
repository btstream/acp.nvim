-- Optional, per-view counters. No logging or timers on the disabled path.
local M = {}
function M.record(view, name, start)
  if not start then
    return
  end
  local elapsed = (vim.uv.hrtime() - start) / 1e6
  view.metrics = view.metrics or {}
  local entry = view.metrics[name] or { count = 0, total_ms = 0, max_ms = 0 }
  entry.count = entry.count + 1
  entry.total_ms = entry.total_ms + elapsed
  entry.max_ms = math.max(entry.max_ms, elapsed)
  view.metrics[name] = entry
end
function M.start(view)
  return view.config.ui.render and view.config.ui.render.profile and vim.uv.hrtime() or nil
end
return M
