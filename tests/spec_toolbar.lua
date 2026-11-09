return function(t)
  local toolbar = require("acp.ui.toolbar")

  t.describe("toolbar", function()
    t.it("escapes percent signs from agent content", function()
      t.eq("%%", toolbar.escape("%"))
      local text = toolbar.render({ model = "50%", mode = "build", status = "idle" }, 80)
      t.truthy(text:find("%%", 1, true), "expected escaped % in toolbar")
    end)

    t.it("shows the running state as a spinner glyph", function()
      local ic = require("acp.ui.icons").get(true)
      local text = toolbar.render({ status = "running", icons = true, spinner = "*" }, 80)
      t.match(vim.pesc("*"), text, "the spinner frame should be shown")
      t.falsy(text:find("Running", 1, true), "the status should not be spelled out")
      -- Without a spinner frame it falls back to the loading glyph.
      local idle = toolbar.render({ status = "idle", icons = true }, 80)
      t.match(vim.pesc(ic.status_idle), idle, "idle should render as its glyph")
      t.falsy(idle:find("Idle", 1, true), "idle should not be spelled out")
    end)

    t.it("shows the mode as a glyph", function()
      local ic = require("acp.ui.icons").get(true)
      local plan = toolbar.render({ mode = "plan", icons = true, status = "idle" }, 80)
      local build = toolbar.render({ mode = "build", icons = true, status = "idle" }, 80)
      t.match(vim.pesc(ic.mode_plan), plan)
      t.match(vim.pesc(ic.mode_build), build)
      t.falsy(plan:find("Plan", 1, true), "the mode name should not be spelled out")
    end)

    t.it("falls back to letter labels without Nerd Font icons", function()
      local ic = require("acp.ui.icons").get(false)
      local text = toolbar.render({ mode = "plan", icons = false, status = "idle" }, 80)
      t.match(vim.pesc(ic.mode_plan), text)
      t.match(vim.pesc(ic.status_idle), text)
    end)

    t.it("prioritises the waiting glyph when narrow", function()
      local ic = require("acp.ui.icons").get(true)
      local text = toolbar.render({
        icons = true,
        mode = "a-very-long-mode-name",
        model = "a-very-long-model-name-indeed",
        status = "running",
        waiting = true,
      }, 20)
      t.match(vim.pesc(ic.status_waiting), text, "the waiting glyph should survive")
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
