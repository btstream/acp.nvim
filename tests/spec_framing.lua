return function(t)
  local framing = require("acp.transport.framing")

  t.describe("framing", function()
    t.it("splits multiple messages in one chunk", function()
      local got = {}
      local d = framing.new_decoder()
      d:feed('{"a":1}\n{"b":2}\n', function(line)
        got[#got + 1] = line
      end)
      t.eq(2, #got)
      t.eq('{"a":1}', got[1])
      t.eq('{"b":2}', got[2])
    end)

    t.it("reassembles a message split across chunks", function()
      local got = {}
      local d = framing.new_decoder()
      d:feed('{"hel', function(line)
        got[#got + 1] = line
      end)
      d:feed('lo":true}\n', function(line)
        got[#got + 1] = line
      end)
      t.eq(1, #got)
      t.eq('{"hello":true}', got[1])
    end)

    t.it("handles a UTF-8 character split across chunks", function()
      local got = {}
      local d = framing.new_decoder()
      local payload = vim.json.encode({ text = "中文" }) .. "\n"
      local cut = 10
      d:feed(payload:sub(1, cut), function(line)
        got[#got + 1] = line
      end)
      d:feed(payload:sub(cut + 1), function(line)
        got[#got + 1] = line
      end)
      t.eq(1, #got)
      t.eq("中文", vim.json.decode(got[1]).text)
    end)

    t.it("strips carriage returns", function()
      local got = {}
      local d = framing.new_decoder()
      d:feed('{"a":1}\r\n', function(line)
        got[#got + 1] = line
      end)
      t.eq('{"a":1}', got[1])
    end)

    t.it("ignores empty lines", function()
      local count = 0
      local d = framing.new_decoder()
      d:feed("\n\n\n", function()
        count = count + 1
      end)
      t.eq(0, count)
    end)

    t.it("fails when a partial message exceeds the limit", function()
      local d = framing.new_decoder(8)
      local ok = d:feed(string.rep("x", 20), function() end)
      t.falsy(ok)
      t.truthy(d.failed)
    end)

    t.it("encodes one newline-delimited line", function()
      local encoded = framing.encode({ jsonrpc = "2.0", method = "x" })
      t.match("^.+%}\n$", encoded)
      t.truthy(vim.json.decode(encoded))
    end)
  end)
end
