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
    -- The controller is only consulted for *runtime* facts (the live client);
    -- configuration comes from the config module so this check still describes
    -- the right settings when the panel was never opened.
    local st = controller.state()
    local cfg = require("acp.config").effective()
    if cfg then
      local agent = cfg.agents[cfg.agent]
      local profile = require("acp.agents").get(agent, cfg.agent)
      health.info(string.format("agent: %s (%s %s)", cfg.agent, agent.command, table.concat(agent.args or {}, " ")))
      if vim.fn.executable(agent.command) == 1 then
        health.ok("agent executable found: " .. vim.fn.exepath(agent.command))
      else
        health.error("agent executable not found: " .. agent.command)
        -- The profile knows how this agent is installed; a generic client can
        -- only point at the documentation.
        if profile.install_hint then
          health.info(profile.install_hint)
        end
      end
      local client = st.client
      local methods = client and client.auth_methods or {}
      if type(methods) == "table" and #methods > 0 then
        local names = {}
        for _, method in ipairs(methods) do
          names[#names + 1] = method.name or method.id
        end
        health.info("login methods: " .. table.concat(names, ", ") .. " (use :Acp login)")
      elseif client then
        health.info("the agent reported no login method; see its documentation")
      end
      -- Every configured agent is checked, not only the active one: a user
      -- switching agents needs to know which are installed.
      local others = {}
      for name in pairs(cfg.agents) do
        if name ~= cfg.agent then
          others[#others + 1] = name
        end
      end
      table.sort(others)
      for _, name in ipairs(others) do
        local other = cfg.agents[name]
        local label = string.format("configured agent %s (%s)", name, other.command)
        if vim.fn.executable(other.command) == 1 then
          health.ok(label)
        else
          health.warn(label .. ": not found")
          local hint = require("acp.agents").get(other, name).install_hint
          if hint then
            health.info(hint)
          end
        end
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

  -- Read the effective config from the config module itself: the health check
  -- must not depend on the controller (and must still work before setup ran).
  local ok_inline, inline = pcall(function()
    return require("acp.config").effective()
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
