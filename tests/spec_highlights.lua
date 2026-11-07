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
