-- Deferred syntax descriptions survive indentation without altering layout.
-- Sources are shared by all rows; only the viewport owns live syntax extmarks.
local CodeHL = require("acp.ui.code_hl")
local metrics = require("acp.ui.render_metrics")
local work = require("acp.ui.work_scheduler")
local M = {}
M.ns = vim.api.nvim_create_namespace("acp_lazy_syntax")

function M.shift(items, offset)
  if not items then
    return nil
  end
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = { source = item.source, row = item.row, offset = item.offset + offset }
  end
  return out
end

function M.cancel(view)
  view.decoration_epoch = (view.decoration_epoch or 0) + 1
  view.decoration_key = nil
  view.decoration_pending = false
  if view.decoration_ticket then
    view.decoration_ticket.cancelled = true
    view.decoration_ticket = nil
  end
end

function M.clear(view)
  M.cancel(view)
  if view.config.ui.render and view.config.ui.render.lazy_syntax and vim.api.nvim_buf_is_valid(view.buf) then
    vim.api.nvim_buf_clear_namespace(view.buf, M.ns, 0, -1)
  end
end

function M.schedule(view)
  local cfg = view.config.ui.render
  if
    not cfg
    or view.commit_job
    or view.full_rewrite
    or not cfg.lazy_syntax
    or not view:is_visible()
    or not view.meta
    or not view.session
    or view.render_version ~= view.session.version
    or vim.api.nvim_win_get_buf(view.win) ~= view.buf
  then
    M.cancel(view)
    return
  end
  local epoch
  local session, version = view.session, view.session.version
  local width, generation, buf = view.width, CodeHL.generation, view.buf
  local function current()
    return not view.destroyed
      and view:is_visible()
      and view.buf == buf
      and view.session == session
      and view.decoration_epoch == epoch
      and view.width == width
      and CodeHL.generation == generation
      and session
      and session.version == version
      and vim.api.nvim_win_get_buf(view.win) == buf
  end
  -- winrestview/window functions must not cause focus or mode changes.
  local bounds = vim.api.nvim_win_call(view.win, function()
    return { vim.fn.line("w0"), vim.fn.line("w$") }
  end)
  local margin = math.ceil(vim.api.nvim_win_get_height(view.win) * cfg.overscan)
  local first, last = math.max(1, bounds[1] - margin), math.min(#view.meta, bounds[2] + margin)
  local key = table.concat(
    { tostring(session), tostring(view.meta), version, width, generation, first, last, bounds[1], bounds[2] },
    ":"
  )
  if view.decoration_key == key then
    return
  end
  M.cancel(view)
  epoch, view.decoration_key = view.decoration_epoch, key
  local cursor = vim.api.nvim_win_get_cursor(view.win)[1]
  local order = {}
  for row = bounds[1], math.min(bounds[2], #view.meta) do
    order[#order + 1] = row
  end
  -- Prefetch in the direction of travel first.
  local forward = cursor >= (view.decoration_cursor or cursor)
  view.decoration_cursor = cursor
  local function before()
    for row = bounds[1] - 1, first, -1 do
      order[#order + 1] = row
    end
  end
  local function after()
    for row = bounds[2] + 1, last do
      order[#order + 1] = row
    end
  end
  if forward then
    after()
    before()
  else
    before()
    after()
  end
  local sources, painted = {}, 0
  local worker = coroutine.create(function()
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    for _, row in ipairs(order) do
      local meta, text = view.meta[row], view.lines_cache[row] or ""
      for _, item in ipairs(meta and meta.decorations or {}) do
        local by_row = sources[item.source]
        if not by_row then
          coroutine.yield() -- keep the parser call in its own slot
          local parse_start = metrics.start(view)
          local ranges = CodeHL.highlight(item.source.code, item.source.lang)
          if not current() then
            return
          end
          metrics.record(view, "syntax", parse_start)
          by_row = {}
          for _, range in ipairs(ranges or {}) do
            by_row[range.row] = by_row[range.row] or {}
            table.insert(by_row[range.row], range)
          end
          sources[item.source] = by_row
        end
        for _, range in ipairs(by_row[item.row] or {}) do
          local s, e =
            math.min(#text, item.offset + range.s), math.min(#text, range.e and item.offset + range.e or #text)
          if e > s then
            vim.api.nvim_buf_set_extmark(buf, M.ns, row - 1, s, { end_col = e, hl_group = range.group, priority = 110 })
            painted = painted + 1
            if painted % 64 == 0 then
              coroutine.yield()
            end
          end
        end
      end
      coroutine.yield()
    end
  end)
  view.decoration_pending = true
  local function step()
    if not current() then
      if view.decoration_epoch == epoch then
        view.decoration_pending, view.decoration_key = false, nil
        view.decoration_ticket = nil
      end
      return
    end
    local started = metrics.start(view)
    local ok, err = coroutine.resume(worker)
    if not current() then
      if view.decoration_epoch == epoch then
        view.decoration_pending, view.decoration_key = false, nil
        view.decoration_ticket = nil
      end
      return
    end
    if not ok then
      view.decoration_pending = false
      view.decoration_key = nil
      view.decoration_ticket = nil
      require("acp.log").error("transcript syntax decoration failed: %s", tostring(err))
      return
    end
    metrics.record(view, "decorate_slice", started)
    if coroutine.status(worker) ~= "dead" then
      return true
    end
    view.decoration_pending = false
    view.decoration_ticket = nil
    return false
  end
  view.decoration_ticket = work.shared:enqueue("decoration", step, { key = view.buf, label = "decoration" })
end
return M
