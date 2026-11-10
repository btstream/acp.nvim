return function(t)
  t.describe("performance regressions", function()
    t.it("reuses syntax analysis across widths and evicts old cache entries", function()
      local hl = require("acp.ui.code_hl")
      local original, calls = vim.treesitter.get_string_parser, 0
      hl.clear_cache()
      vim.treesitter.get_string_parser = function(...)
        calls = calls + 1
        return original(...)
      end
      local ok, err = pcall(function()
        local blocks = require("acp.ui.blocks")
        local block = { id = "syntax-cache", kind = "agent", text = "```lua\nlocal width_cache = 1\n```\n" }
        local icons = blocks.icon_set(false)
        blocks.render_block(block, { width = 80, icons = icons })
        blocks.render_block(block, { width = 40, icons = icons })
        t.eq(1, calls)
        for i = 1, 65 do
          hl.highlight("local unique_" .. i .. " = 1", "lua")
        end
        hl.highlight("local width_cache = 1", "lua")
        t.eq(67, calls, "the oldest syntax entry should have been evicted")
      end)
      vim.treesitter.get_string_parser = original
      hl.clear_cache()
      if not ok then
        error(err)
      end
    end)

    t.it("falls back safely after the render change journal wraps", function()
      local s = require("acp.session.state").new("wrap", "/tmp")
      s:track_changes()
      s:add_local_user("question")
      s:append_text("agent", "start", "answer")
      local chat = require("acp.ui.chat").new({ config = require("acp.config").defaults })
      chat:set_session(s)
      for _ = 1, 300 do
        s:append_text("agent", " x", "answer")
      end
      chat:render()
      local result = chat:transcript()
      chat:render(true)
      t.eq(result, chat:transcript())
      chat:destroy()
    end)

    t.it("disconnects instead of growing an unbounded protocol dispatch queue", function()
      local start, stop = vim.fn.jobstart, vim.fn.jobstop
      local callbacks, stopped, received = nil, 0, 0
      vim.fn.jobstart = function(_, opts)
        callbacks = opts
        return 999999
      end
      vim.fn.jobstop = function()
        stopped = stopped + 1
      end
      local ok, err = pcall(function()
        local proc = require("acp.transport.process").spawn({
          command = "mock",
          max_pending_bytes = 1024,
          dispatch_budget_ms = 1,
          -- Slower than the budget so the interleaved drain cannot keep up and the
          -- hard limit still has to fire.
          on_line = function()
            received = received + 1
            local t = vim.uv.hrtime()
            while vim.uv.hrtime() - t < 2e6 do
            end
          end,
          on_exit = function() end,
        })
        local data = {}
        for i = 1, 20 do
          data[i] = string.rep("x", 100)
        end
        local warm = {}
        for i = 1, 10 do
          warm[i] = "warm" .. i
        end
        callbacks.on_stdout(999999, warm)
        callbacks.on_stdout(999999, { table.concat(data, "\n") .. "\n" })
        callbacks.on_exit(999999, 1)
        vim.wait(20)
        t.truthy(stopped > 0)
        t.truthy(received > 0 and received < 22, "some input is consumed before the limit fires")
        t.eq(false, proc:is_alive())
      end)
      vim.fn.jobstart, vim.fn.jobstop = start, stop
      if not ok then
        error(err)
      end
    end)

    t.it("yields during ordered protocol bursts and drains before exit", function()
      local original, callbacks = vim.fn.jobstart, nil
      vim.fn.jobstart = function(_, opts)
        callbacks = opts
        return 999999
      end
      local ok, err = pcall(function()
        local received, sentinel, exited = {}, nil, false
        require("acp.transport.process").spawn({
          command = "mock",
          dispatch_budget_ms = 1,
          on_line = function(line)
            received[#received + 1] = line
            local start = vim.uv.hrtime()
            while vim.uv.hrtime() - start < 2e6 do
            end
          end,
          on_exit = function()
            t.eq(5, #received)
            exited = true
          end,
        })
        callbacks.on_stdout(999999, { "one", "two", "three", "four", "five", "" })
        callbacks.on_exit(999999, 0)
        vim.schedule(function()
          sentinel = #received
        end)
        t.truthy(vim.wait(1000, function()
          return exited
        end, 5))
        t.truthy(sentinel < 5, "other editor callbacks must run before the burst finishes")
        t.eq({ "one", "two", "three", "four", "five" }, received)
      end)
      vim.fn.jobstart = original
      if not ok then
        error(err)
      end
    end)

    t.it("rejects a queue overflow without clearing the user's draft", function()
      local controller = require("acp.controller")
      controller.setup({ memory = { max_queued_messages = 1 } })
      local s = controller.state()
      s.connection, s.client = "ready", {}
      s.session = require("acp.session.state").new("queue", "/tmp")
      s.session.status = "running"
      s.input:restore("draft")
      t.eq(true, controller.send_now("first", {}))
      controller.submit("draft", {})
      t.eq("draft", s.input:text())
      t.eq(1, #s.session.queue)
      s.client, s.connection = nil, "stopped"
    end)

    t.it("bounds in-memory drafts while preserving the current composer", function()
      local cfg = require("acp.config").merge(require("acp.config").defaults, { memory = { max_drafts = 2 } })
      local input = require("acp.ui.input").new({ config = cfg })
      for i = 1, 5 do
        input:switch_session(tostring(i))
        input:restore("draft " .. i)
      end
      t.truthy(vim.tbl_count(input.drafts) <= 2)
      t.eq("draft 5", input:text())
      input:destroy()
    end)

    t.it("retains tool detail during a status-only update", function()
      local s = require("acp.session.state").new("tool", "/tmp")
      local reducer = require("acp.session.reducer")
      reducer.apply(s, {
        sessionUpdate = "tool_call",
        toolCallId = "x",
        content = { { type = "content", content = { type = "text", text = "result" } } },
      })
      local detail = s.tools.x.detail
      s.tools.x.content = nil -- the byte limiter may discard duplicate payloads
      reducer.apply(s, { sessionUpdate = "tool_call_update", toolCallId = "x", status = "completed" })
      t.eq(detail, s.tools.x.detail)
    end)

    t.it("reuses stable code background marks while following prose grows", function()
      local s = require("acp.session.state").new("background", "/tmp")
      s:track_changes()
      s:add_local_user("question")
      s:append_text("agent", "```lua\nlocal x = 1\n```\n", "answer")
      local chat = require("acp.ui.chat").new({ config = require("acp.config").defaults })
      chat:set_session(s)
      local ns = vim.api.nvim_get_namespaces().acp_chat_bg
      local before = vim.api.nvim_buf_get_extmarks(chat.buf, ns, 0, -1, {})
      t.truthy(#before > 0)
      s:append_text("agent", "prose\n", "answer")
      chat:render()
      local after = vim.api.nvim_buf_get_extmarks(chat.buf, ns, 0, -1, {})
      t.eq(before, after, "unchanged backgrounds should retain their extmark IDs")
      chat:destroy()
    end)

    t.it("coalesces draft writes and exposes an explicit durable flush", function()
      local drafts = require("acp.storage.drafts")
      local original = drafts.path
      local path = vim.fn.tempname() .. ".json"
      drafts.path = function()
        return path
      end
      local ok, err = pcall(function()
        drafts.clear()
        for i = 1, 30 do
          drafts.put("/tmp", "coalesce", "draft " .. i)
        end
        t.eq(0, vim.fn.filereadable(path), "saving should be deferred")
        t.eq("draft 30", drafts.get("/tmp", "coalesce").text)
        t.truthy(drafts.flush())
        local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
        t.eq("draft 30", data["/tmp\0coalesce"].text)
        drafts.put("/tmp", "coalesce", "async draft")
        t.truthy(vim.wait(2000, function()
          local fh = io.open(path, "rb")
          if not fh then
            return false
          end
          local text = fh:read("*a")
          fh:close()
          return text:find("async draft", 1, true) ~= nil
        end, 10))
        drafts.clear()
      end)
      drafts.path = original
      vim.fn.delete(path)
      if not ok then
        error(err)
      end
    end)

    t.it("bounds block and session payloads by bytes", function()
      local limits = vim.tbl_extend(
        "force",
        require("acp.config").defaults.memory,
        { max_block_bytes = 2048, max_session_bytes = 4096 }
      )
      local s = require("acp.session.state").new("budget", "/tmp", limits)
      for i = 1, 20 do
        s:append({ id = tostring(i), kind = "agent", text = string.rep("x", 3000) })
      end
      t.truthy(s.bytes <= 4096)
      t.truthy(#s.blocks < 20)
      for _, b in ipairs(s.blocks) do
        t.truthy(#b.text <= 2048)
        t.truthy(b.truncated)
      end
      local b = s:append_text("agent", "", "stream")
      for _ = 1, 100 do
        s:append_text("agent", string.rep("中", 100), "stream")
      end
      t.truthy(#b.text <= 2048)
      t.truthy(s.bytes <= 4096)
    end)

    t.it("evicts idle sessions in LRU order while protecting active work", function()
      local State = require("acp.session.state")
      local sessions = {}
      for i = 1, 6 do
        local s = State.new(tostring(i), "/tmp")
        s.last_used = i
        sessions[s.id] = s
      end
      sessions["2"].status = "running"
      sessions["3"].queue = { { text = "pending" } }
      require("acp.session.memory").prune(sessions, sessions["6"], { permission = { session_id = "4" } }, {
        max_cached_sessions = 4,
        max_total_bytes = 1024,
      })
      t.eq(nil, sessions["1"])
      t.eq(nil, sessions["5"])
      for _, id in ipairs({ "2", "3", "4", "6" }) do
        t.truthy(sessions[id])
      end
    end)

    t.it("updates tracked tails without replacing stable metadata", function()
      local State, Chat = require("acp.session.state"), require("acp.ui.chat")
      local s = State.new("tracked", "/tmp")
      s:track_changes()
      for i = 1, 100 do
        s:append({ id = tostring(i), kind = "agent", text = "stable\ntext" })
      end
      local tail = s:append_text("agent", "tail", "tail")
      local chat = Chat.new({ config = require("acp.config").defaults })
      chat:set_session(s)
      local first = chat.meta[1]
      s:append_text("agent", " grows", "tail")
      chat:render()
      t.truthy(first == chat.meta[1], "stable prefix metadata should be reused")
      t.truthy(chat:transcript():find("tail grows", 1, true))
      local original, calls = require("acp.ui.blocks").render_block, 0
      require("acp.ui.blocks").render_block = function(...)
        calls = calls + 1
        return original(...)
      end
      chat:render()
      require("acp.ui.blocks").render_block = original
      t.eq(0, calls)
      chat:destroy()
    end)

    t.it("matches full rendering through tracked streams, toggles and trimming", function()
      local State, Chat = require("acp.session.state"), require("acp.ui.chat")
      local s = State.new(
        "tracked",
        "/tmp",
        vim.tbl_extend("force", require("acp.config").defaults.memory, {
          max_block_bytes = 1024,
          max_session_bytes = 4096,
        })
      )
      s:track_changes()
      local cfg = require("acp.config").defaults
      local incremental, full = Chat.new({ config = cfg }), Chat.new({ config = cfg })
      incremental:set_session(s)
      full:set_session(s)
      local function compare()
        incremental:render()
        full:render(true)
        t.eq(full:transcript(), incremental:transcript())
        t.eq(full.meta, incremental.meta)
        local function marks(chat, namespace)
          local out = {}
          for _, mark in
            ipairs(
              vim.api.nvim_buf_get_extmarks(
                chat.buf,
                vim.api.nvim_get_namespaces()[namespace],
                0,
                -1,
                { details = true }
              )
            )
          do
            local d = mark[4]
            out[#out + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group, d.conceal }
          end
          table.sort(out, function(a, b)
            return vim.inspect(a) < vim.inspect(b)
          end)
          return out
        end
        t.eq(marks(full, "acp_chat"), marks(incremental, "acp_chat"))
        t.eq(marks(full, "acp_chat_bg"), marks(incremental, "acp_chat_bg"))
      end
      for i = 1, 25 do
        s:add_local_user("turn " .. i)
        s:append_text("agent", "**reply**\n```lua\nlocal x = 1\n```\n", tostring(i))
        compare()
        s:append_text("agent", "more\n", tostring(i))
        compare()
        local tool = s:append({
          id = "tool" .. i,
          kind = "tool",
          title = "Read",
          status = "completed",
          detail = string.rep("output\n", 20),
        })
        compare()
        tool.expanded = true
        s:touch(tool, false)
        compare()
        s:finish_turn("end_turn")
        compare()
      end
      t.truthy(s.trimmed, "the equivalence test must cross the byte budget")
      incremental:destroy()
      full:destroy()
    end)

    t.it("rejects oversized complete protocol lines before dispatch", function()
      for _, text in ipairs({ string.rep("x", 1025) .. "\n", string.rep("x", 1025) .. "\r\n" }) do
        local decoder = require("acp.transport.framing").new_decoder(1024)
        local calls = 0
        t.eq(
          false,
          decoder:feed(text, function()
            calls = calls + 1
          end)
        )
        t.eq(0, calls)
        t.eq(0, decoder.buffered)
      end
    end)

    t.it("reuses closed fence syntax while prose streams after it", function()
      local hl = require("acp.ui.code_hl")
      local original, calls = hl.highlight, 0
      hl.highlight = function()
        calls = calls + 1
        return {}, true
      end
      local ok, err = pcall(function()
        local cache, text = {}, "```lua\nlocal x = 1\n```\n"
        for _ = 1, 20 do
          text = text .. "More prose.\n"
          require("acp.ui.blocks").render_text(text, "AcpAssistant", 80, cache)
        end
        t.eq(1, calls)
        hl.clear_cache()
        require("acp.ui.blocks").render_text(text, "AcpAssistant", 80, cache)
        t.eq(2, calls, "theme changes invalidate cached capture groups")
      end)
      hl.highlight = original
      if not ok then
        error(err)
      end
    end)
  end)
end
