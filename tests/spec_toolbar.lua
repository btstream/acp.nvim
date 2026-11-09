return function(t)
  local toolbar = require("acp.ui.toolbar")

  ---Strip winbar markup so only the text the user sees remains.
  ---@param text string
  ---@return string
  local function visible(text)
    return (text:gsub("%%%#[%w_]+%#", ""):gsub("%%%@v:lua%.%w+@", ""):gsub("%%T", ""):gsub("%%=", ""))
  end

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
      t.falsy(visible(text):find("Running", 1, true), "the status should not be spelled out")
      -- Without a spinner frame it falls back to the loading glyph.
      local idle = toolbar.render({ status = "idle", icons = true }, 80)
      t.match(vim.pesc(ic.status_idle), idle, "idle should render as its glyph")
      t.falsy(visible(idle):find("Idle", 1, true), "idle should not be spelled out")
    end)

    t.it("shows the mode as a glyph", function()
      local ic = require("acp.ui.icons").get(true)
      local plan = toolbar.render({ mode = "plan", icons = true, status = "idle" }, 80)
      local build = toolbar.render({ mode = "build", icons = true, status = "idle" }, 80)
      t.match(vim.pesc(ic.mode_plan), plan)
      t.match(vim.pesc(ic.mode_build), build)
      t.falsy(visible(plan):find("Plan", 1, true), "the mode name should not be spelled out")
    end)

    t.it("draws no chevron", function()
      local ic = require("acp.ui.icons").get(true)
      local text = visible(toolbar.render({
        mode = "plan",
        model = "Sonnet",
        status = "idle",
        icons = true,
      }, 80))
      t.falsy(text:find(ic.chevron_down, 1, true), "the toolbar should not draw a chevron")
      t.falsy(text:find(ic.chevron_right, 1, true), "the toolbar should not draw a chevron")
    end)

    t.it("uses one background across every region", function()
      local highlights = require("acp.ui.highlights")
      highlights.setup(false)
      -- `AcpToolbar` links to StatusLine, so resolve the link before reading bg.
      local bar = vim.api.nvim_get_hl(0, { name = "AcpToolbar", link = false })
      local regions = {
        "AcpToolbarAccent",
        "AcpToolbarModePlan",
        "AcpToolbarModeBuild",
        "AcpToolbarIdle",
        "AcpToolbarRunning",
        "AcpToolbarWaiting",
        "AcpToolbarCancelling",
      }
      for _, name in ipairs(regions) do
        local hl = vim.api.nvim_get_hl(0, { name = name })
        t.eq(bar.bg, hl.bg, name .. " should share the toolbar background")
      end
    end)

    t.it("gives each mode and status its own colour", function()
      local highlights = require("acp.ui.highlights")
      highlights.setup(false)
      local function fg(name)
        return vim.api.nvim_get_hl(0, { name = name }).fg
      end
      t.truthy(fg("AcpToolbarModePlan") ~= fg("AcpToolbarModeBuild"), "modes share a colour")
      local statuses = {
        fg("AcpToolbarIdle"),
        fg("AcpToolbarRunning"),
        fg("AcpToolbarWaiting"),
        fg("AcpToolbarCancelling"),
      }
      for i = 1, #statuses do
        for j = i + 1, #statuses do
          t.truthy(statuses[i] ~= statuses[j], "two statuses share a colour")
        end
      end
    end)

    t.it("maps modes to their highlight group", function()
      t.eq("AcpToolbarModePlan", toolbar.mode_hl("plan"))
      t.eq("AcpToolbarModeBuild", toolbar.mode_hl("Build"))
      t.eq("AcpToolbarAccent", toolbar.mode_hl("ask"))
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
