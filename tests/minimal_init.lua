-- Isolate every XDG directory a test can write: data holds agent installs,
-- state holds drafts and the log, cache holds image previews. Without the
-- state/cache overrides the suite clears the user's real drafts.json and
-- rewrites their log.
local isolated = string.format("/tmp/opencode/acp-test-%d", vim.uv.os_getpid())
vim.env.XDG_DATA_HOME = isolated .. "/data"
vim.env.XDG_STATE_HOME = isolated .. "/state"
vim.env.XDG_CACHE_HOME = isolated .. "/cache"
for _, dir in ipairs({ vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME }) do
  vim.fn.mkdir(dir, "p")
end

vim.opt.runtimepath:append(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))

-- Optional test dependency: use a locally installed snacks.nvim when present so
-- the snacks-backed session browser is exercised instead of only the fallback.
-- Optional test dependency: edgy.nvim, for the layout integration tests.
local edgy_candidates = {
  vim.fn.expand("~/.local/share/nvim/lazy/edgy.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/deps/start/edgy.nvim"),
}
for _, dir in ipairs(edgy_candidates) do
  if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/edgy") == 1 then
    vim.opt.runtimepath:append(dir)
    break
  end
end

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
