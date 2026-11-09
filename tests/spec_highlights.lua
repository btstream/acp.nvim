return function(t)
  local highlights = require("acp.ui.highlights")

  local function defined(name)
    local hl = vim.api.nvim_get_hl(0, { name = name })
    return hl ~= nil and next(hl) ~= nil
  end

  t.describe("highlights", function()
    t.it("defines every semantic group", function()
      highlights.setup(true)
      for name in pairs(highlights.groups) do
        t.truthy(defined(name), name .. " was not defined")
      end
    end)

    t.it("survives a colorscheme change", function()
      highlights.setup(true)
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
      highlights.setup(true)
      for _, scheme in ipairs({ "default", "blue", "default" }) do
        vim.cmd("silent! colorscheme " .. scheme)
        vim.cmd("doautocmd ColorScheme")
        t.truthy(defined("AcpUser"), "lost after switching to " .. scheme)
      end
    end)

    t.it("derives visible surfaces from a dark background", function()
      local saved = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
      vim.api.nvim_set_hl(0, "Normal", { fg = "#c8ccd4", bg = "#14161b" })
      highlights.setup(false)

      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name }).bg
      end
      local normal = bg("Normal")
      local card = bg("AcpCardBg")
      local code = bg("AcpCodeBlockBg")
      local inline = bg("AcpMdCode")

      t.truthy(card and card ~= normal, "card background is indistinguishable from Normal")
      t.truthy(code and code ~= normal, "code block background is indistinguishable from Normal")
      t.truthy(inline and inline ~= normal, "inline code background is indistinguishable from Normal")
      -- The card must stand out more than the code block, which stands out
      -- more than inline code.
      t.truthy(card ~= code and code ~= inline, "surfaces should differ from each other")

      vim.api.nvim_set_hl(0, "Normal", saved)
      highlights.setup(true)
    end)

    t.it("derives visible surfaces from a light background", function()
      local saved = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
      vim.api.nvim_set_hl(0, "Normal", { fg = "#24292f", bg = "#ffffff" })
      highlights.setup(false)

      local function bg(name)
        return vim.api.nvim_get_hl(0, { name = name }).bg
      end
      local normal = bg("Normal")
      for _, name in ipairs({ "AcpCardBg", "AcpCodeBlockBg", "AcpMdCode" }) do
        t.truthy(bg(name) and bg(name) ~= normal, name .. " blends into a light background")
      end

      vim.api.nvim_set_hl(0, "Normal", saved)
      highlights.setup(true)
    end)

    t.it("honours the zed palette", function()
      highlights.setup(true)
      local hl = vim.api.nvim_get_hl(0, { name = "AcpUser" })
      t.eq("Function", hl.link, "zed style should link AcpUser to Function")

      highlights.setup(false)
      local plain = vim.api.nvim_get_hl(0, { name = "AcpUser" })
      t.eq("Identifier", plain.link, "plain style should link AcpUser to Identifier")
    end)

    t.it("does not stack autocmds on repeated setup", function()
      highlights.setup(true)
      highlights.setup(true)
      highlights.setup(true)
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
