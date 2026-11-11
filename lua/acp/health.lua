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

  -- Image attachments are optional: report the reader that would be used, and
  -- stay quiet when the user turned the feature off.
  local ok_images, images = pcall(function()
    return require("acp.config").defaults.context.images
  end)
  if ok_images and images and images.enabled then
    local tool = require("acp.context.clipboard").tool()
    if images.clipboard == false then
      health.info("clipboard images disabled (context.images.clipboard = false)")
    elseif images.clipboard ~= "auto" then
      health.ok("clipboard images use a custom command: " .. table.concat(images.clipboard, " "))
    elseif tool then
      health.ok("clipboard image reader: " .. tool)
    else
      health.warn("no clipboard image tool found; :Acp image will ask for a file path")
      health.info("Install wl-clipboard (Wayland), xclip (X11), pngpaste (macOS) or use PowerShell (Windows)")
    end
    health.info("image cache: " .. require("acp.context.image").dir())
  end

  local ok_inline, inline = pcall(function()
    return require("acp.controller").state().config
      or require("acp.config").validate(require("acp.config").merge(require("acp.config").defaults, {}))
  end)
  if ok_inline and inline then
    local mode = inline.inline.review.mode
    health.ok("inline editing, default review: " .. mode)
    local overrides = inline.inline.review.by_filetype
    local names = vim.tbl_keys(overrides or {})
    if #names > 0 then
      table.sort(names)
      local parts = {}
      for _, name in ipairs(names) do
        local value = overrides[name]
        parts[#parts + 1] = name .. "=" .. (type(value) == "table" and value.mode or value)
      end
      health.info("inline review overrides: " .. table.concat(parts, ", "))
    end
  end

  local has_json = vim.json ~= nil
  if has_json then
    health.ok("vim.json available")
  else
    health.error("vim.json is required")
  end
end

return M
