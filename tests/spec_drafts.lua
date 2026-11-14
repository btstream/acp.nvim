return function(t)
  local drafts = require("acp.storage.drafts")
  local context = require("acp.context")

  local function to_blocks(text, attachments)
    return context.to_prompt(text, attachments, { context = { images = {} } }, {
      supports = function()
        return true
      end,
    })
  end

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

    t.it("keeps diagnostics text so a restored draft can rebuild the block", function()
      drafts.clear()
      drafts.put(cwd, "s1", "hello", {
        {
          kind = "diagnostics",
          label = "diagnostics (1)",
          path = "/tmp/a.lua",
          text = "a:1:1 ERROR boom",
          block = { type = "text", text = "Diagnostics:\na:1:1 ERROR boom" },
        },
      })
      local got = drafts.get(cwd, "s1")
      local blocks, err = to_blocks("hello", got.attachments)
      t.eq(nil, err)
      local joined = ""
      for _, block in ipairs(blocks) do
        joined = joined .. (block.text or "")
      end
      t.match("ERROR boom", joined)
      drafts.clear()
    end)

    t.it("caps restored diagnostics text at a larger but bounded size", function()
      drafts.clear()
      local huge = string.rep("e", 64 * 1024 + 100)
      drafts.put(cwd, "s1", "hello", {
        {
          kind = "diagnostics",
          label = "diagnostics (1)",
          path = "/tmp/a.lua",
          text = huge,
          block = { type = "text", text = huge },
        },
      })
      local got = drafts.get(cwd, "s1")
      t.truthy(got.attachments[1].text_truncated)
      t.eq(64 * 1024, #got.attachments[1].text)
      local _, err = to_blocks("hello", got.attachments)
      t.truthy(err, "oversized restored diagnostics must not be sent silently")
      t.match("truncat", err)
      drafts.clear()
    end)

    t.it("flags a restored selection whose text no longer fits the draft", function()
      drafts.clear()
      local big = string.rep("x", 5000)
      drafts.put(cwd, "s1", "hello", {
        { kind = "selection", label = "a.lua:1-100", path = "/tmp/a.lua", uri = "file:///tmp/a.lua", text = big },
      })
      local got = drafts.get(cwd, "s1")
      t.truthy(got.attachments[1].text_truncated)
      local _, err = to_blocks("hello", got.attachments)
      t.truthy(err, "a truncated restored selection must not be sent silently")
      t.match("truncat", err)
      drafts.clear()
    end)

    t.it("prefers the full in-memory draft over a truncated restored copy", function()
      local Config = require("acp.config")
      local Input = require("acp.ui.input")
      drafts.clear()
      local config = Config.validate(Config.merge(Config.defaults, {}))
      local input = Input.new({ config = config })
      input.on_draft = function(_, text, attachments, owner)
        if owner then
          drafts.put(owner.cwd, owner.id, text, attachments)
        end
      end
      local owner = { cwd = cwd, id = "s1" }
      input:switch_session("s1", nil, owner)
      vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "keep me" })
      local big = string.rep("x", 5000)
      input:add_attachment({
        kind = "selection",
        label = "a.lua:1-100",
        path = "/tmp/a.lua",
        uri = "file:///tmp/a.lua",
        text = big,
      })
      input:save_draft()
      local restored = drafts.get(cwd, "s1")
      t.truthy(restored.attachments[1].text_truncated)
      input:switch_session("other", nil, { cwd = cwd, id = "other" })
      input:switch_session("s1", restored, owner)
      t.eq(#big, #input.attachments[1].text, "switching back lost the full in-memory attachment")
      input:destroy()
      drafts.clear()
    end)

    t.it("survives a corrupt file", function()
      t.truthy(drafts.flush())
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
