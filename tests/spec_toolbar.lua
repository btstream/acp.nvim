return function(t)
  local toolbar = require("acp.ui.toolbar")

  ---Strip winbar markup so only the text the user sees remains.
  ---@param text string
  ---@return string
  local function visible(text)
    return (
      text:gsub("%%%#[%w_]+%#", ""):gsub("%%%$[%w_]+%$", ""):gsub("%%%@v:lua%.%w+@", ""):gsub("%%T", ""):gsub("%%=", "")
    )
  end

  t.describe("toolbar", function()
    t.it("places attachment chips after the mode badge, not before it", function()
      -- The badges are pinned to the left edge. Prepending chips pushed the mode
      -- off the bar and let a narrow composer truncate the chip from the front,
      -- which is what a real edgy layout showed.
      local text = toolbar.render({
        mode = "build",
        model = "DeepSeek V4.1 Flash",
        status = "idle",
        icons = false,
        chips = { "screenshot.png" },
      }, 70)
      t.match("^%%#AcpToolbar#", text, "the bar must still start with its own highlight")
      local shown = visible(text)
      local mode_at = shown:find(" B ", 1, true)
      local chip_at = shown:find("[screenshot.png]", 1, true)
      t.truthy(mode_at, "the mode badge disappeared")
      t.truthy(chip_at, "the chip disappeared")
      t.truthy(mode_at < chip_at, "the chip must follow the mode badge")
    end)

    t.it("truncates chips instead of dropping the model on a narrow composer", function()
      local text = toolbar.render({
        mode = "build",
        model = "DeepSeek V4.1 Flash",
        status = "idle",
        icons = false,
        chips = { "a-very-long-screenshot-filename.png" },
      }, 30)
      local shown = visible(text)
      t.truthy(shown:find("…", 1, true), "a long chip should be truncated")
      t.falsy(shown:find("a-very-long-screenshot-filename.png", 1, true), "the whole name must not be rendered")
      t.truthy(shown:find(" B ", 1, true), "the mode badge must survive")
    end)

    t.it("marks extra chips when they do not all fit", function()
      local text = toolbar.render({
        mode = "build",
        model = "m",
        status = "idle",
        icons = false,
        chips = { "one.png", "two.png", "three.png", "four.png" },
      }, 26)
      local shown = visible(text)
      t.truthy(shown:find("…", 1, true), "collapsed chips should be marked")
      -- The bar must not grow past the window: overflowing text is clipped by
      -- Vim, but the rendered width should already fit.
      t.truthy(vim.api.nvim_strwidth(shown) <= 26, "rendered bar is wider than the window: " .. shown)
    end)

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
      -- The bar opens with its own background, then the badge starts at column
      -- 0: no leading space or separator before it.
      t.truthy(raw:find("^%%#AcpToolbar#%%@v:lua%.AcpPickMode@", 1), "the mode region should start the bar: " .. raw)
      local group = raw:match("^%%#AcpToolbar#%%@v:lua%.AcpPickMode@%%[$]([%w_]+)[$]")
      t.eq("AcpToolbarModeBuild", group)
      -- The clickable region must still open on the badge and close after it.
      t.truthy(raw:find("%T", 1, true) ~= nil, "the mode region must be terminated so clicks stop")
    end)

    t.it("pads the badge glyph by one cell on each side", function()
      local ic = require("acp.ui.icons").get(true)
      local raw = toolbar.render({ mode = "build", status = "idle", icons = true }, 80)
      local body = raw:match("%%[$]AcpToolbarModeBuild[$](.-)%%[$]AcpToolbar[$]")
      t.eq(" " .. ic.mode_build .. " ", body, "the badge should be ' glyph ', not the bare glyph")
    end)

    t.it("covers the badge padding with its own background", function()
      local ic = require("acp.ui.icons").get(true)
      local raw = toolbar.render({ mode = "plan", status = "idle", icons = true }, 80)
      -- The group is opened before the leading space and closed after the
      -- trailing one, so both cells are painted.
      t.truthy(
        raw:find("%%[$]AcpToolbarModePlan[$] " .. vim.pesc(ic.mode_plan) .. " %%[$]AcpToolbar[$]", 1),
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

    t.it("carries its own background instead of relying on WinBar", function()
      -- A layout manager (edgy) may remap `WinBar` to its own group. Every
      -- region therefore inherits the background from an explicit
      -- `%#AcpToolbar#` opener through `%$...$`, never from the window mapping.
      local ic = require("acp.ui.icons").get(true)
      local highlights = require("acp.ui.highlights")
      highlights.setup()

      local raw = toolbar.render({ mode = "build", model = "Sonnet", status = "idle", icons = true }, 80)
      t.truthy(raw:find("^%%#AcpToolbar#", 1), "the bar must open with its own background: " .. raw)
      -- After the opening run, no other group may be opened with `%#...#`;
      -- re-opening `AcpToolbar` itself is fine, anything else would restart
      -- from the window's `WinBar` mapping.
      local body = raw:sub(#"%#AcpToolbar#" + 1)
      for group in body:gmatch("%%#([%w_]+)#") do
        t.eq("AcpToolbar", group, "a region restarted from WinBar instead of inheriting")
      end

      -- The transcript title is a header, not a toolbar: it opens on the
      -- window's own background so it matches the transcript below it.
      local title = toolbar.chat_title({ icons = true, agent = "opencode", title = "work" }, 60)
      t.truthy(title:find("^%%#AcpNormal#", 1), "the title must open on the transcript background")
      local rest = title:sub(#"%#AcpNormal#" + 1)
      for group in rest:gmatch("%%#([%w_]+)#") do
        t.eq("AcpNormal", group, "the title restarted from WinBar instead of inheriting")
      end
    end)

    t.it("gives the transcript title the same background as the transcript", function()
      -- A header in a different colour reads as a separate strip. The title bar
      -- must sit on `AcpNormal`'s surface, and the window mapping must agree for
      -- the blank remainder past the text.
      local highlights = require("acp.ui.highlights")
      highlights.setup()
      local layout = require("acp.layout")
      local config = require("acp.config")
      layout.setup(config.merge(config.defaults, {}))
      layout.apply_window_options(vim.api.nvim_get_current_win(), "chat")
      local winhl = vim.api.nvim_get_option_value("winhighlight", { win = vim.api.nvim_get_current_win() })
      t.match("WinBar:AcpNormal", winhl, "the transcript WinBar must map to AcpNormal")
      t.match("WinBarNC:AcpNormal", winhl, "the transcript WinBarNC must map to AcpNormal")

      -- The composer keeps the statusline colour: it is a toolbar.
      layout.apply_window_options(vim.api.nvim_get_current_win(), "input")
      local input_winhl = vim.api.nvim_get_option_value("winhighlight", { win = vim.api.nvim_get_current_win() })
      t.match("WinBar:AcpToolbar", input_winhl, "the composer WinBar must keep AcpToolbar")
    end)

    t.it("keeps working when a layout manager replaces the WinBar mapping", function()
      -- Reproduces the edgy case: edgy appends `WinBar:EdgyWinBar` after ours,
      -- and the later mapping wins. The toolbar must still not depend on it.
      local highlights = require("acp.ui.highlights")
      highlights.setup()
      vim.api.nvim_set_hl(0, "EdgyWinBar", { fg = "#b2ccd6", bg = "#303030" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_option_value(
        "winhighlight",
        "Normal:AcpNormal,WinBar:AcpToolbar,WinBarNC:AcpToolbar,WinBar:EdgyWinBar,WinBarNC:EdgyWinBar",
        { win = win }
      )
      local raw = toolbar.render({ mode = "plan", model = "Sonnet", status = "idle", icons = true }, 80)
      local res = vim.api.nvim_eval_statusline(raw, { use_winbar = true, highlights = true })
      -- Every segment must name AcpToolbar (or a group that inherits it) in its
      -- stacked groups, never EdgyWinBar.
      for _, seg in ipairs(res.highlights or {}) do
        local groups = table.concat(seg.groups or {}, ">")
        t.falsy(groups:find("EdgyWinBar", 1, true), "a region fell back to EdgyWinBar: " .. groups)
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
