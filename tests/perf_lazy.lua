-- Comparative baseline, A, and B. Timing is reported, not a brittle CI limit.
-- nvim --headless -u tests/minimal_init.lua -l tests/perf_lazy.lua
local config = require("acp.config")
local Chat = require("acp.ui.chat")
local State = require("acp.session.state")
local CodeHL = require("acp.ui.code_hl")
local renderer = require("acp.ui.buffer_renderer")
local decoration = require("acp.ui.decoration")

local function history()
  local s = State.new("benchmark", "/tmp")
  s:track_changes()
  for i = 1, 600 do
    local lines = {}
    if i % 3 == 0 then
      lines[1] = "```lua"
      for row = 1, 20 do
        lines[#lines + 1] = "local value_" .. i .. "_" .. row .. " = " .. row
      end
      lines[#lines + 1] = "```"
    elseif i % 3 == 1 then
      lines = { "| Row | Value |", "| --- | --- |" }
      for row = 1, 6 do
        lines[#lines + 1] = "| " .. row .. " | " .. i .. " example **content** |"
      end
    else
      lines = { "## Response " .. i, "", string.rep("Some ordinary text with `inline code`. ", 10) }
    end
    s:append({ id = "b" .. i, kind = "agent", text = table.concat(lines, "\n") .. "\n" })
  end
  return s
end

local baseline_hash, baseline_rows, baseline_marks
for _, mode in ipairs({ "full", "A", "B" }) do
  CodeHL.clear_cache()
  local cfg = config.merge(config.defaults, {
    ui = {
      render = {
        profile = true,
        lazy_syntax = mode ~= "full",
        pagination = { enabled = mode == "B" },
      },
    },
  })
  local s, chat = history(), Chat.new({ config = cfg })
  chat.win = vim.api.nvim_open_win(chat.buf, true, { relative = "editor", row = 0, col = 0, width = 90, height = 20 })
  local original, calls, syntax_ms = CodeHL.highlight, 0, 0
  CodeHL.highlight = function(...)
    local start = vim.uv.hrtime()
    local ranges, ok = original(...)
    syntax_ms, calls = syntax_ms + (vim.uv.hrtime() - start) / 1e6, calls + 1
    return ranges, ok
  end
  collectgarbage("collect")
  local before = collectgarbage("count")
  chat:set_session(s)
  assert(vim.wait(10000, function()
    return chat.render_version == s.version and not chat.layout_job
  end, 1))
  vim.cmd("redraw")
  decoration.schedule(chat)
  assert(vim.wait(10000, function()
    return not chat.decoration_pending
  end, 1))
  local stats = chat:render_stats()
  local marks = #vim.api.nvim_buf_get_extmarks(chat.buf, renderer.ns, 0, -1, {}) + stats.syntax_marks
  collectgarbage("collect")
  local memory = collectgarbage("count") - before
  print(
    string.format(
      "%s first_commit=%.2fms syntax_calls=%d syntax=%.2fms rows=%d marks=%d cached=%d lua_delta=%.0fKiB max_layout_slice=%.2fms",
      mode,
      stats.timings.first_paint.max_ms,
      calls,
      syntax_ms,
      stats.rows,
      marks,
      stats.cached_blocks,
      memory,
      stats.timings.layout_slice and stats.timings.layout_slice.max_ms or stats.timings.layout.max_ms
    )
  )
  CodeHL.highlight = original
  local hash = vim.fn.sha256(chat:transcript())
  if mode == "full" then
    baseline_hash, baseline_rows, baseline_marks = hash, stats.rows, marks
  elseif mode == "A" then
    assert(hash == baseline_hash and stats.rows == baseline_rows, "A changed transcript text")
    assert(marks < baseline_marks, "A did not bound syntax extmarks")
  else
    assert(hash == baseline_hash, "B full export lost history")
    assert(stats.cached_blocks <= cfg.ui.render.pagination.page_blocks, "B laid out off-page blocks")
  end
  vim.api.nvim_win_close(chat.win, true)
  chat:destroy()
end
print("lazy rendering comparisons passed")
vim.cmd("qa!")
