return function(t)
  local drafts = require("acp.storage.drafts")

  t.describe("drafts", function()
    local cwd = "/tmp/acp-draft-test"

    t.it("round-trips a draft", function()
      drafts.clear()
      drafts.put(cwd, "s1", "hello world", { { kind = "file", label = "a.lua" } })
      local got = drafts.get(cwd, "s1")
      t.truthy(got)
      t.eq("hello world", got.text)
      t.eq(1, #got.attachments)
    end)

    t.it("removes the entry when the text is empty", function()
      drafts.put(cwd, "s1", "", {})
      t.eq(nil, drafts.get(cwd, "s1"))
    end)

    t.it("separates projections and sessions", function()
      drafts.clear()
      drafts.put(cwd, "s1", "one")
      drafts.put("/tmp/other", "s1", "two")
      drafts.put(cwd, "s2", "three")
      t.eq("one", drafts.get(cwd, "s1").text)
      t.eq("two", drafts.get("/tmp/other", "s1").text)
      t.eq("three", drafts.get(cwd, "s2").text)
    end)

    t.it("survives a corrupt file", function()
      local fh = io.open(drafts.path(), "wb")
      fh:write("{not json")
      fh:close()
      t.eq(nil, drafts.get(cwd, "s1"))
      -- and can still write afterwards
      t.truthy(drafts.put(cwd, "s1", "recovered"))
      t.eq("recovered", drafts.get(cwd, "s1").text)
      drafts.clear()
    end)
  end)
end
