-- edgy.nvim layout integration.
--
--   nvim -u examples/edgy/init.lua
--
-- Shows how edgy owns the panel position while acp.nvim owns the content.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
vim.opt.runtimepath:append(root)

-- Use the edgy.nvim installed by your plugin manager, or place it on the
-- runtimepath before starting Neovim.
local ok = pcall(require, "edgy")
if not ok then
  vim.notify("edgy.nvim is required for this example", vim.log.levels.ERROR)
  return
end

vim.opt.number = true
vim.opt.laststatus = 3
vim.opt.splitkeep = "screen"

require("edgy").setup({
  right = (function()
    local opts = { right = {} }
    require("acp.integrations.edgy").extend(opts)
    return opts.right
  end)(),
  options = {
    right = { size = 46 },
    left = { size = 30 },
  },
  animate = { enabled = true },
})

require("acp").setup({
  layout = { backend = "external" },
})

vim.keymap.set("n", "<leader>a", function()
  require("acp").toggle()
end, { desc = "ACP panel" })
