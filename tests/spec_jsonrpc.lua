return function(t)
  local rpcmod = require("acp.transport.jsonrpc")

  t.describe("jsonrpc", function()
    t.it("matches responses to requests", function()
      local sent = {}
      local rpc = rpcmod.new({
        send = function(payload)
          sent[#sent + 1] = vim.json.decode(payload)
          return true
        end,
      })
      local got
      rpc:request("initialize", { a = 1 }, function(ok, value)
        got = { ok = ok, value = value }
      end)
      t.eq("initialize", sent[1].method)
      t.eq(1, sent[1].id)
      rpc:handle({ jsonrpc = "2.0", id = 1, result = { protocolVersion = 1 } })
      t.truthy(got.ok)
      t.eq(1, got.value.protocolVersion)
    end)

    t.it("surfaces error responses", function()
      local rpc = rpcmod.new({
        send = function()
          return true
        end,
      })
      local got
      rpc:request("session/new", {}, function(ok, value)
        got = { ok = ok, value = value }
      end)
      rpc:handle({ jsonrpc = "2.0", id = 1, error = { code = -32000, message = "boom" } })
      t.falsy(got.ok)
      t.eq("boom", got.value.message)
    end)

    t.it("dispatches notifications", function()
      local seen
      local rpc = rpcmod.new({
        send = function()
          return true
        end,
      })
      rpc:on_notification("session/update", function(params)
        seen = params
      end)
      rpc:handle({ jsonrpc = "2.0", method = "session/update", params = { sessionId = "s1" } })
      t.eq("s1", seen.sessionId)
    end)

    t.it("responds to unknown agent requests with method not found", function()
      local sent
      local rpc = rpcmod.new({
        send = function(payload)
          sent = vim.json.decode(payload)
          return true
        end,
      })
      rpc:handle({ jsonrpc = "2.0", id = 7, method = "fs/read_text_file", params = {} })
      t.eq(7, sent.id)
      t.eq(-32601, sent.error.code)
    end)

    t.it("lets handlers answer agent requests", function()
      local sent
      local rpc = rpcmod.new({
        send = function(payload)
          sent = vim.json.decode(payload)
          return true
        end,
      })
      rpc:on_request("session/request_permission", function(params, respond)
        respond({ outcome = { outcome = "selected", optionId = "allow" } })
      end)
      rpc:handle({ jsonrpc = "2.0", id = 3, method = "session/request_permission", params = {} })
      t.eq("allow", sent.result.outcome.optionId)
    end)

    t.it("ignores unknown notifications and malformed values", function()
      local rpc = rpcmod.new({
        send = function()
          return true
        end,
      })
      rpc:handle({ jsonrpc = "2.0", method = "unknown/thing", params = {} })
      rpc:handle("nonsense")
      t.truthy(true)
    end)

    t.it("fails pending requests on close", function()
      local rpc = rpcmod.new({
        send = function()
          return true
        end,
      })
      local got
      rpc:request("session/prompt", {}, function(ok, value)
        got = { ok = ok, value = value }
      end)
      rpc:close("agent process exited")
      t.falsy(got.ok)
      t.match("exited", got.value.message)
      t.eq(0, rpc:pending_count())
    end)

    t.it("ignores late responses for cancelled requests", function()
      local rpc = rpcmod.new({
        send = function()
          return true
        end,
      })
      local calls = 0
      local id = rpc:request("session/prompt", {}, function()
        calls = calls + 1
      end)
      rpc:cancel(id)
      rpc:handle({ jsonrpc = "2.0", id = id, result = { stopReason = "end_turn" } })
      t.eq(0, calls)
    end)
  end)
end
