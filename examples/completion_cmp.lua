-- lazy.nvim example: merge into your nvim-cmp spec. Choose this OR blink.cmp.
return {
  "hrsh7th/nvim-cmp",
  opts = function(_, opts)
    local cmp = require("cmp")
    require("acp.completion.cmp").setup()
    cmp.setup.filetype("acp_input", {
      enabled = true, -- allow nofile buffers even if your global config excludes them
      sources = { { name = "acp", keyword_length = 0 } },
      matching = { disallow_symbol_nonprefix_matching = false },
      mapping = {
        ["<CR>"] = cmp.mapping(function(fallback)
          if cmp.visible() and cmp.get_selected_entry() then
            cmp.confirm({ select = false })
          else
            fallback()
          end
        end, { "i" }),
      },
    })
    return opts
  end,
}
