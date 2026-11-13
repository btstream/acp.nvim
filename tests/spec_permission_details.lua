return function(t)
  local details = require("acp.ui.permission_details")

  t.describe("permission details", function()
    t.it("shows the command an execute call ran", function()
      local lines = details.render({
        toolCall = { kind = "execute", title = "Run tests", rawInput = { command = "npm test" } },
      })
      t.eq({ "npm test" }, lines)
    end)

    t.it("shows the working directory for an execute call", function()
      local lines = details.render({ toolCall = { kind = "execute", rawInput = { cmd = "ls" } } }, { cwd = "/proj" })
      t.eq({ "ls", "", "cwd: /proj" }, lines)
    end)

    t.it("renders an edit as a diff", function()
      local lines = details.render({
        toolCall = {
          kind = "edit",
          content = {
            { type = "diff", path = "/proj/a.lua", oldText = "local a = 1\n", newText = "local a = 2\n" },
          },
        },
      }, { cwd = "/proj" })
      local joined = table.concat(lines, "\n")
      t.match("a%.lua", joined)
      t.match("%- local a = 1", joined)
      t.match("%+ local a = 2", joined)
    end)

    t.it("falls back to text content, then to structured input", function()
      local text = details.render({
        toolCall = {
          kind = "fetch",
          content = { { type = "content", content = { type = "text", text = "the docs" } } },
        },
      })
      t.eq({ "the docs" }, text)
      local fallback = details.render({ toolCall = { kind = "fetch", rawInput = { url = "https://x" } } })
      t.match("https://x", fallback[1])
    end)

    t.it("has nothing to show for an empty request", function()
      t.eq({}, details.render({ toolCall = {} }))
    end)

    t.it("caps the rows it returns", function()
      local text = {}
      for i = 1, 100 do
        text[i] = "line " .. i
      end
      local lines = details.render({
        toolCall = {
          kind = "read",
          content = { { type = "content", content = { type = "text", text = table.concat(text, "\n") } } },
        },
      }, { max_rows = 10 })
      t.truthy(#lines <= 11, "detail rows were not capped: " .. #lines)
    end)
  end)
end
