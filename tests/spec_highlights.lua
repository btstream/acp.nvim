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

    -- Surfaces are links to theme groups, not colours blended at runtime, so
    -- the check is that the link resolves to a background distinct from
    -- `Normal` under whatever theme is active.
    t.it("puts cards and code blocks on distinct theme surfaces", function()
      vim.cmd("hi clear")
      vim.cmd("syntax reset")
      highlights.setup()

      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
      end
      local normal = bg("Normal")
      local card = bg("AcpCardBg")
      local code = bg("AcpCodeBlockBg")

      t.truthy(card, "the card surface has no background")
      t.truthy(code, "the code block surface has no background")
      t.truthy(card ~= normal, "the card blends into Normal")
      t.truthy(code ~= normal, "the code block blends into Normal")
      t.truthy(card ~= code, "the card and the code block look the same")
      -- Inline code deliberately has no surface: a background per word is noisy
      -- in prose and would break up a card.
      t.eq(nil, bg("AcpMdCode"), "inline code should not paint a background")
    end)

    t.it("links content groups to the same captures a markdown buffer uses", function()
      -- A bold word or a heading must look the same in the transcript as in a
      -- Markdown file: reuse the treesitter captures instead of inventing
      -- parallel colours.
      local expected = {
        AcpBold = "@markup.strong",
        AcpItalic = "@markup.italic",
        AcpStrike = "@markup.strikethrough",
        AcpMdCode = "String",
        AcpMdLink = "@markup.link",
        AcpH1 = "@markup.heading.1",
        AcpH2 = "@markup.heading.2",
        AcpH3 = "@markup.heading.3",
        AcpH4 = "@markup.heading.4",
        AcpQuote = "@markup.quote",
      }
      for name, target in pairs(expected) do
        t.eq(target, highlights.groups[name].link, name .. " should link to " .. target)
      end
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

    t.it("gives each block header glyph and title their own group", function()
      -- The four groups exist so an icon and its label can be coloured apart.
      -- What each one points at is a styling choice, so only their existence is
      -- asserted here; how the blocks use them is covered in spec_markdown.
      for _, name in ipairs({ "AcpUserIcon", "AcpUserTitle", "AcpAssistantIcon", "AcpAssistantTitle" }) do
        t.truthy(highlights.groups[name], name .. " is not in the group table")
        t.truthy(defined(name), name .. " was not defined")
      end
    end)

    t.it("does not give card body text a background of its own", function()
      highlights.setup()
      -- No `AcpToolBody` group exists on purpose; body text inherits the card.
      t.eq(nil, highlights.groups["AcpToolBody"], "card body must not define a group")
    end)

    t.it("links the diff groups to the theme's diff highlights", function()
      -- A diff inside a card has to read like a diff in a review window, so the
      -- line colours come from the theme rather than a blended colour.
      local expected = {
        AcpDiffAdd = "DiffAdd",
        AcpDiffDelete = "DiffDelete",
        AcpDiffAddSign = "DiffAdd",
        AcpDiffRemoveSign = "DiffDelete",
        AcpDiffHunk = "NonText",
        AcpDiffMeta = "Comment",
        AcpDiffFile = "Title",
      }
      for name, target in pairs(expected) do
        t.eq(target, highlights.groups[name].link, name .. " should link to " .. target)
      end
    end)

    t.it("applies groups passed through the config", function()
      vim.cmd("hi clear")
      highlights.setup({ AcpUser = { fg = "#abcdef" }, AcpToolbarModePlan = { fg = "#111111", bg = "#222222" } })

      t.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "AcpUser" }).fg, "configured group was not applied")
      local badge = vim.api.nvim_get_hl(0, { name = "AcpToolbarModePlan" })
      t.eq(0x222222, badge.bg, "configured badge background was not applied")
      -- Groups not mentioned in the config keep their defaults.
      t.truthy(defined("AcpAssistant"), "an unconfigured group lost its default")
    end)

    t.it("re-applies configured groups after a colorscheme change", function()
      vim.cmd("hi clear")
      highlights.setup({ AcpUser = { fg = "#abcdef" } })
      vim.cmd("silent! colorscheme default")
      vim.cmd("doautocmd ColorScheme")

      t.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "AcpUser" }).fg, "configured colour lost on colorscheme change")
    end)

    t.it("lets a configured group replace a built-in one", function()
      vim.cmd("hi clear")
      highlights.setup({ AcpCardBg = { bg = "#101010" } })
      -- The definition wins over the link the default table would install.
      t.eq(0x101010, vim.api.nvim_get_hl(0, { name = "AcpCardBg", link = false }).bg)
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
