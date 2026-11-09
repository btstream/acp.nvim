-- Minimal configuration: native layout, no other plugins required.
--
--   nvim -u examples/minimal/init.lua
--
-- Requires a logged in OpenCode (`opencode auth login`).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
vim.opt.runtimepath:append(root)

vim.opt.number = true
vim.opt.laststatus = 3
vim.opt.splitkeep = "screen"

require("acp").setup({
  layout = { backend = "native", width = 0.4 },
})

vim.keymap.set("n", "<leader>a", function()
  require("acp").toggle()
end, { desc = "ACP panel" })
