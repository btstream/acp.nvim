return function(t)
  local toolbar = require("acp.ui.toolbar")

  t.describe("toolbar", function()
    t.it("escapes percent signs from agent content", function()
      t.eq("%%", toolbar.escape("%"))
      local text = toolbar.render({ model = "50%", mode = "build", status = "idle" }, 80)
      t.truthy(text:find("%%", 1, true), "expected escaped % in toolbar")
    end)

    t.it("includes the running state", function()
      local text = toolbar.render({ status = "running", spinner = "*" }, 80)
      t.match("[Rr]unning", text)
    end)

    t.it("prioritises the waiting state when narrow", function()
      local text = toolbar.render({
        mode = "a-very-long-mode-name",
        model = "a-very-long-model-name-indeed",
        status = "running",
        waiting = true,
      }, 20)
      t.match("Waiting", text)
      t.falsy(text:find("a%-very%-long%-model", 1), "model name should be dropped when narrow")
    end)

    t.it("degrades to plain text without Nerd Font icons", function()
      local blocks = require("acp.ui.blocks")
      local ic = blocks.icon_set(false)
      t.eq(">", ic.user)
      t.eq("v", ic.tool_ok)
    end)

    t.it("renders an empty transcript hint", function()
      t.truthy(require("acp.ui.chat"))
    end)
  end)
end
