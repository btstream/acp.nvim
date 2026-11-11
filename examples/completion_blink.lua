-- lazy.nvim example: merge this into your existing blink.cmp spec.
-- Only acp_input uses this source; other filetypes keep their usual sources.
return {
  "saghen/blink.cmp",
  opts = {
    sources = {
      per_filetype = { acp_input = { "acp" } },
      providers = {
        acp = { name = "ACP", module = "acp.completion.blink" },
      },
    },
  },
}
