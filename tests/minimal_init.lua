vim.opt.runtimepath:append(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))

-- Optional test dependency: use a locally installed snacks.nvim when present so
-- the snacks-backed session browser is exercised instead of only the fallback.
local candidates = {
  vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/deps/start/snacks.nvim"),
}
local env_dir = os.getenv("ACP_TEST_SNACKS")
if env_dir and env_dir ~= "" then
  table.insert(candidates, 1, env_dir)
end

for _, dir in ipairs(candidates) do
  if dir and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/snacks") == 1 then
    vim.opt.runtimepath:append(dir)
    break
  end
end

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.laststatus = 3
vim.opt.splitkeep = "screen"
