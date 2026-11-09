return function(t)
  local highlights = require("acp.ui.highlights")

  local function defined(name)
    local hl = vim.api.nvim_get_hl(0, { name = name })
    return hl ~= nil and next(hl) ~= nil
  end

  t.describe("highlights", function()
    t.it("defines every semantic group", function()
      highlights.setup()
      for name in pairs(highlights.groups) do
        t.truthy(defined(name), name .. " was not defined")
      end
    end)

    t.it("survives a colorscheme change", function()
      highlights.setup()
      t.truthy(defined("AcpUser"), "not defined after setup")

      -- Loading any colorscheme clears user groups; the ColorScheme autocmd
      -- must put them back.
      vim.cmd("silent! colorscheme default")
      vim.cmd("doautocmd ColorScheme")

      for _, name in ipairs({ "AcpUser", "AcpAssistant", "AcpToolbar", "AcpToolTitle" }) do
        t.truthy(defined(name), name .. " lost after a colorscheme change")
      end
    end)

    t.it("re-applies after several colorscheme switches", function()
      highlights.setup()
      for _, scheme in ipairs({ "default", "blue", "default" }) do
        vim.cmd("silent! colorscheme " .. scheme)
        vim.cmd("doautocmd ColorScheme")
        t.truthy(defined("AcpUser"), "lost after switching to " .. scheme)
      end
    end)

    t.it("derives visible surfaces from a dark background", function()
      local saved = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
      vim.api.nvim_set_hl(0, "Normal", { fg = "#c8ccd4", bg = "#14161b" })
      highlights.setup()

      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name }).bg
      end
      local normal = bg("Normal")
      local card = bg("AcpCardBg")
      local code = bg("AcpCodeBlockBg")

      t.truthy(card and card ~= normal, "card background is indistinguishable from Normal")
      t.truthy(code and code ~= normal, "code block background is indistinguishable from Normal")
      t.truthy(card ~= code, "the card and the code block should differ")
      -- Inline code is deliberately background-free.
      t.eq(nil, bg("AcpMdCode"), "inline code should not paint a background")

      vim.api.nvim_set_hl(0, "Normal", saved)
      highlights.setup()
    end)

    t.it("derives visible surfaces from a light background", function()
      local saved = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
      vim.api.nvim_set_hl(0, "Normal", { fg = "#24292f", bg = "#ffffff" })
      highlights.setup()

      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name }).bg
      end
      local normal = bg("Normal")
      for _, name in ipairs({ "AcpCardBg", "AcpCodeBlockBg" }) do
        t.truthy(bg(name) and bg(name) ~= normal, name .. " blends into a light background")
      end
      t.eq(nil, bg("AcpMdCode"), "inline code should not paint a background")

      vim.api.nvim_set_hl(0, "Normal", saved)
      highlights.setup()
    end)

    t.it("respects a user override made before setup", function()
      vim.cmd("hi clear")
      vim.api.nvim_set_hl(0, "AcpUser", { fg = "#ff0000" })
      vim.api.nvim_set_hl(0, "AcpBold", { fg = "#00ff00" })
      highlights.setup()

      t.eq(0xff0000, vim.api.nvim_get_hl(0, { name = "AcpUser" }).fg, "AcpUser was overwritten")
      t.eq(0x00ff00, vim.api.nvim_get_hl(0, { name = "AcpBold" }).fg, "AcpBold was overwritten")
    end)

    t.it("respects a user override made after setup", function()
      vim.cmd("hi clear")
      highlights.setup()
      vim.api.nvim_set_hl(0, "AcpThought", { fg = "#123456" })

      -- A colorscheme load re-applies every group; the user's value must survive.
      vim.cmd("doautocmd ColorScheme")
      t.eq(0x123456, vim.api.nvim_get_hl(0, { name = "AcpThought" }).fg, "AcpThought was overwritten")
    end)

    t.it("respects a user override of a derived group", function()
      vim.cmd("hi clear")
      vim.api.nvim_set_hl(0, "AcpCardBg", { bg = "#123456" })
      vim.api.nvim_set_hl(0, "AcpToolbarModePlan", { fg = "#abcdef", bg = "#111111" })
      vim.api.nvim_set_hl(0, "AcpToolbarIdle", { fg = "#999999" })
      highlights.setup()

      t.eq(0x123456, vim.api.nvim_get_hl(0, { name = "AcpCardBg" }).bg, "derived surface was overwritten")
      local badge = vim.api.nvim_get_hl(0, { name = "AcpToolbarModePlan" })
      t.eq(0xabcdef, badge.fg, "badge foreground was overwritten")
      t.eq(0x111111, badge.bg, "badge background was overwritten")
      t.eq(0x999999, vim.api.nvim_get_hl(0, { name = "AcpToolbarIdle" }).fg, "status glyph was overwritten")
    end)

    t.it("still defines groups the user left alone", function()
      vim.cmd("hi clear")
      vim.api.nvim_set_hl(0, "AcpUser", { fg = "#ff0000" })
      highlights.setup()
      -- A group next to the overridden one must still get its default.
      t.truthy(defined("AcpAssistant"), "a non-overridden group was not defined")
      t.truthy(defined("AcpToolbarModePlan"), "a derived group was not defined")
    end)

    t.it("does not give card body text a background of its own", function()
      highlights.setup()
      -- No `AcpToolBody` group exists on purpose; body text inherits the card.
      t.eq(nil, highlights.groups["AcpToolBody"], "card body must not define a group")
    end)

    t.it("does not stack autocmds on repeated setup", function()
      highlights.setup()
      highlights.setup()
      highlights.setup()
      local count = 0
      for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "ColorScheme" })) do
        if autocmd.group_name == "AcpHighlights" then
          count = count + 1
        end
      end
      t.eq(1, count, "ColorScheme handler registered more than once")
    end)
  end)
end
