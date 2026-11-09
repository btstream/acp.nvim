-- :checkhealth acp
local M = {}

local health = vim.health or require("vim.health")

function M.check()
  health.start("acp.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim >= 0.10 is required")
  end

  local ok, config = pcall(require, "acp.config")
  if ok then
    health.ok("configuration module loaded")
  else
    health.error("configuration module failed to load: " .. tostring(config))
  end

  local controller_ok, controller = pcall(require, "acp.controller")
  if controller_ok then
    health.ok("controller loaded")
  else
    health.error("controller failed to load: " .. tostring(controller))
  end

  if controller_ok then
    local st = controller.state()
    local cfg = st.config
    if cfg then
      local agent = cfg.agents[cfg.agent]
      health.info(string.format("agent: %s (%s %s)", cfg.agent, agent.command, table.concat(agent.args or {}, " ")))
      if vim.fn.executable(agent.command) == 1 then
        health.ok("agent executable found: " .. vim.fn.exepath(agent.command))
      else
        health.error("agent executable not found: " .. agent.command)
        health.info("Install OpenCode: https://opencode.ai/docs/ then run `opencode auth login`")
      end
      health.info("layout backend: " .. cfg.layout.backend)
    end
    health.info("connection: " .. tostring(st.connection))
    if st.session then
      health.info("active session: " .. tostring(st.session.id))
    end
  end

  local edgy_ok = pcall(require, "edgy")
  if edgy_ok then
    health.ok("edgy.nvim detected; consider layout.backend = 'external'")
    health.info([[

Add to your edgy config:
  require("acp.integrations.edgy").extend(opts)]])
  else
    health.info("edgy.nvim not installed (optional)")
  end

  local log = require("acp.log")
  health.info("log file: " .. log.path())

  local has_json = vim.json ~= nil
  if has_json then
    health.ok("vim.json available")
  else
    health.error("vim.json is required")
  end
end

return M
