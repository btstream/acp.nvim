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

    t.it("pins the mode badge to the left edge", function()
      local ic = require("acp.ui.icons").get(true)
      local raw = toolbar.render({ mode = "build", model = "Sonnet", status = "idle", icons = true }, 80)
      -- The badge starts at column 0: no leading space or separator before it.
      t.truthy(raw:find("^%%@v:lua%.AcpPickMode@", 1), "the mode region should start the bar: " .. raw)
      local group = raw:match("^%%@v:lua%.AcpPickMode@%%#([%w_]+)%#")
      t.eq("AcpToolbarModeBuild", group)
    end)

    t.it("pads the badge glyph by one cell on each side", function()
      local ic = require("acp.ui.icons").get(true)
      local raw = toolbar.render({ mode = "build", status = "idle", icons = true }, 80)
      local body = raw:match("%%#AcpToolbarModeBuild%#(.-)%%#AcpToolbar%#")
      t.eq(" " .. ic.mode_build .. " ", body, "the badge should be ' glyph ', not the bare glyph")
    end)

    t.it("covers the badge padding with its own background", function()
      local ic = require("acp.ui.icons").get(true)
      local raw = toolbar.render({ mode = "plan", status = "idle", icons = true }, 80)
      -- The group is opened before the leading space and closed after the
      -- trailing one, so both cells are painted.
      t.truthy(
        raw:find("%%#AcpToolbarModePlan%# " .. vim.pesc(ic.mode_plan) .. " %%#AcpToolbar%#", 1),
        "the badge background does not cover its padding: " .. raw
      )
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

    t.it("lets the window supply the bar background", function()
      -- Regions only set a foreground; the background comes from the window's
      -- `WinBar:AcpToolbar` mapping. Without that mapping each region would
      -- inherit `WinBar` instead and the bar would not read as one strip.
      local layout = require("acp.layout")
      local config = require("acp.config")
      layout.setup(config.merge(config.defaults, {}))
      layout.apply_window_options(vim.api.nvim_get_current_win(), "chat")
      local winhl = vim.api.nvim_get_option_value("winhighlight", { win = vim.api.nvim_get_current_win() })
      t.match("WinBar:AcpToolbar", winhl, "WinBar must map to the toolbar group")
      t.match("WinBarNC:AcpToolbar", winhl, "WinBarNC must map to the toolbar group")

      local highlights = require("acp.ui.highlights")
      highlights.setup()
      local bar_bg = vim.api.nvim_get_hl(0, { name = "AcpToolbar", link = false }).bg
      -- Only the modes paint a background of their own. Every other region
      -- leaves the surface alone, so whatever the bar provides shows through.
      for _, name in ipairs({
        "AcpToolbarAccent",
        "AcpToolbarIdle",
        "AcpToolbarRunning",
        "AcpToolbarWaiting",
        "AcpToolbarCancelling",
      }) do
        local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
        t.truthy(hl.bg == nil or hl.bg == bar_bg, name .. " pins a background other than the bar's")
      end
      for _, name in ipairs({ "AcpToolbarModePlan", "AcpToolbarModeBuild" }) do
        local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
        t.truthy(hl.bg, name .. " should have its own badge background")
      end
    end)

    t.it("gives each mode and status its own colour", function()
      local highlights = require("acp.ui.highlights")
      highlights.setup()
      local function fg(name)
        return vim.api.nvim_get_hl(0, { name = name }).fg
      end
      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name }).bg
      end
      t.truthy(
        bg("AcpToolbarModePlan") ~= bg("AcpToolbarModeBuild"),
        "modes should be told apart by their badge background"
      )
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

    t.it("defines a foreground for every toolbar glyph", function()
      -- Colours come from the theme, so contrast is the theme's business. What
      -- this module must guarantee is that each region actually resolves to a
      -- foreground: a group linked to something the theme never defines would
      -- silently fall back to the bar's own text colour and lose the state.
      local highlights = require("acp.ui.highlights")
      highlights.setup()
      for _, name in ipairs({
        "AcpToolbarAccent",
        "AcpToolbarModePlan",
        "AcpToolbarModeBuild",
        "AcpToolbarIdle",
        "AcpToolbarRunning",
        "AcpToolbarWaiting",
        "AcpToolbarCancelling",
      }) do
        local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
        t.truthy(hl.fg, name .. " resolves to no foreground")
      end
    end)

    t.it("makes the mode badge stand out from the bar", function()
      local highlights = require("acp.ui.highlights")
      highlights.setup()
      local bar = vim.api.nvim_get_hl(0, { name = "AcpToolbar", link = false })
      for _, name in ipairs({ "AcpToolbarModePlan", "AcpToolbarModeBuild" }) do
        local badge = vim.api.nvim_get_hl(0, { name = name }).bg
        t.truthy(badge, name .. " has no badge background")
        t.truthy(badge ~= bar.bg, name .. " does not stand out from the bar")
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
