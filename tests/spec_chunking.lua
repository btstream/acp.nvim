return function(t)
  local clients = require("acp.protocol.client")
  local reducer = require("acp.session.reducer")
  local state = require("acp.session.state")
  local rpcmod = require("acp.transport.jsonrpc")

  local function client(size)
    local c = clients.new({
      agent = { command = "mock" },
      cwd = "/tmp",
      client_capabilities = {},
      limits = { text_chunk_bytes = size or 64 },
    })
    c.rpc = rpcmod.new({
      send = function()
        return true
      end,
    })
    return c
  end

  local function update(kind, text)
    return {
      jsonrpc = "2.0",
      method = "session/update",
      params = {
        sessionId = "s",
        update = {
          sessionUpdate = kind,
          messageId = "m",
          _meta = { source = "test" },
          content = { type = "text", text = text },
        },
      },
    }
  end

  local function dispatch(c, msg)
    local parts = {}
    c.rpc:on_notification("session/update", function(params)
      parts[#parts + 1] = params.update
    end)
    local next_part = assert(c:chunk_update(msg))
    local count = 0
    repeat
      count = count + 1
      assert(count < 10000, "chunk dispatcher did not terminate")
    until not next_part()
    return parts
  end

  t.describe("oversized update chunking", function()
    t.it("dispatches UTF-8 text lazily, exactly once, including oversize boundaries", function()
      local c = client(1024)
      local text = string.rep("中", 4000)
      local parts = dispatch(c, update("agent_message_chunk", text))
      local rebuilt = {}
      for _, part in ipairs(parts) do
        rebuilt[#rebuilt + 1] = part.content.text
        t.eq(part.content.text, vim.json.decode(vim.json.encode({ x = part.content.text })).x)
        t.eq("m", part.messageId)
        t.eq({ source = "test" }, part._meta)
      end
      t.eq(text, table.concat(rebuilt))
      t.eq(#parts, c.stats.chunk_parts)
      t.eq(1, c.stats.chunked_messages)
    end)

    t.it("keeps all text slices ahead of a response through the real Client callback", function()
      local original_start, original_stop = vim.fn.jobstart, vim.fn.jobstop
      local callbacks, c
      vim.fn.jobstart = function(_, opts)
        callbacks = opts
        return 999999
      end
      vim.fn.jobstop = function() end
      local ok, err = pcall(function()
        c = client(1024)
        c.limits.spill_bytes = 2048
        c.limits.max_pending_bytes = 0
        c.request = function()
          return true, { protocolVersion = 1 }
        end
        t.truthy(c:do_start(1))
        local seen, response = {}, false
        c.rpc:on_notification("session/update", function(params)
          t.falsy(response, "response overtook a text slice")
          seen[#seen + 1] = params.update.content.text
        end)
        c.rpc.pending[42] = {
          method = "session/load",
          cb = function()
            response = true
          end,
        }
        local text = string.rep("中", 4000)
        callbacks.on_stdout(
          999999,
          { vim.json.encode(update("agent_thought_chunk", text)), '{"jsonrpc":"2.0","id":42,"result":{}}', "" }
        )
        callbacks.on_exit(999999, 0)
        t.truthy(vim.wait(2000, function()
          return response
        end, 5))
        t.eq(text, table.concat(seen))
        t.truthy(#seen > 1)
        t.truthy(c.proc.stats.spill_records > 0, "real Client chain did not exercise spool")
      end)
      if c and c.proc then
        c.proc:stop(true)
      end
      vim.fn.jobstart, vim.fn.jobstop = original_start, original_stop
      if not ok then
        error(err, 0)
      end
    end)

    t.it("keeps replacement tool content atomic instead of producing cumulative prefixes", function()
      local c = client(64)
      local msg = update("tool_call", "")
      msg.params.update.toolCallId = "t"
      msg.params.update.content = { { type = "content", content = { type = "text", text = string.rep("x", 4096) } } }
      t.eq(nil, c:chunk_update(msg))
      local seen = 0
      c.rpc:on_notification("session/update", function(params)
        seen = seen + 1
        t.eq(msg.params.update, params.update)
      end)
      c:on_line(vim.json.encode(msg))
      t.eq(1, seen)
    end)

    t.it("does not chunk small, disabled or unrelated updates", function()
      t.eq(nil, client():chunk_update(update("agent_message_chunk", "tiny")))
      t.eq(nil, client(0):chunk_update(update("agent_message_chunk", string.rep("x", 500))))
      t.eq(nil, client():chunk_update(update("plan", string.rep("x", 500))))
      t.eq(nil, client():chunk_update({ id = 1, result = { text = string.rep("x", 500) } }))
    end)

    t.it("reduces all text slices into one block", function()
      local c, s = client(32), state.new("s", "/tmp")
      s:begin_turn()
      c.rpc:on_notification("session/update", function(params)
        reducer.apply(s, params.update)
      end)
      local next_part = assert(c:chunk_update(update("agent_message_chunk", string.rep("字", 300))))
      while next_part() do
      end
      t.eq(1, #s.blocks)
      t.eq(string.rep("字", 300), s.blocks[1].text)
    end)

    t.it("abandons stale dispatchers after connection replacement", function()
      local c = client(32)
      local next_part = assert(c:chunk_update(update("agent_message_chunk", string.rep("x", 500))))
      c.rpc = rpcmod.new({
        send = function()
          return true
        end,
      })
      t.eq(false, next_part())
      t.eq(nil, c.stats.chunk_parts)
    end)
  end)
end
