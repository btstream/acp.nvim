-- Decide what command actually starts an agent.
--
-- Two facts drive this module:
--
-- 1. `config.merge` fills defaults into every agent table, so after merging you
--    cannot tell whether the user wrote `command = "claude-agent-acp"` or the
--    preset did. Comparing values against the defaults does not work either: a
--    user may deliberately write the same string. The caller therefore records
--    provenance from the *raw* `setup` input, and this module consumes it.
--
-- 2. Which binary runs must be the same everywhere: the conversation, the
--    terminal login and the health check. They all go through `resolve`.
--
-- The module is pure: no filesystem writes, no subprocesses, no network.
local registry = require("acp.manager.registry")

local M = {}

---Record which launch fields the user wrote explicitly.
---
---Only the raw setup input is inspected, never the merged table, because merging
---has already erased the distinction.
---@param raw table|nil the table passed to `setup`
---@return table<string, {command: boolean, args: boolean}>
function M.provenance(raw)
  local out = {}
  local agents = type(raw) == "table" and raw.agents or nil
  if type(agents) ~= "table" then
    return out
  end
  for name, value in pairs(agents) do
    if type(name) == "string" and type(value) == "table" then
      out[name] = {
        command = value.command ~= nil,
        args = value.args ~= nil,
        env = value.env ~= nil,
      }
    end
  end
  return out
end

---Whether the user supplied a launch command of their own.
---
---Overriding only `env` or `profile` is not a launch override: those tune the
---preset rather than replace it.
---@param entry table|nil provenance for one agent
---@return boolean
local function has_override(entry)
  return type(entry) == "table" and (entry.command == true or entry.args == true)
end

---The manager root, applying the documented default.
---@param config table
---@return string
function M.manager_root(config)
  local configured = type(config.manager) == "table" and config.manager.root or nil
  local root = configured
  if type(configured) ~= "string" or configured == "" then
    root = (vim.fn.stdpath("data") or vim.fn.expand("~/.local/share/nvim")) .. "/acp/agents"
  end
  -- Locks, leases and the npm cwd are used as raw filesystem paths, not only
  -- through the store (which normalises on its own). Expand `~` and make a
  -- relative root absolute here so every user of the root agrees.
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(root), ":p"))
end

---@param config table
---@return table store
function M.new_store(config)
  local root = M.manager_root(config)
  return require("acp.manager.store").new({
    root = function()
      return root
    end,
  })
end

---Resolve the command for one agent.
---
---Returns a spec, or nil plus a reason. Callers must not fall back silently when
---this fails: a managed agent that is missing or broken has to say so, because
---running a different version would be worse than refusing.
---@param config table
---@param id string
---@param provenance table|nil result of `M.provenance`
---@param store table|nil injectable for tests
---@return table|nil spec
---@return string|nil err
function M.resolve(config, id, provenance, store)
  local agent = type(config.agents) == "table" and config.agents[id] or nil
  if type(agent) ~= "table" then
    return nil, "agent " .. tostring(id) .. " is not configured"
  end
  local source = agent.source or "auto"
  local entry = type(provenance) == "table" and provenance[id] or nil
  local overridden = has_override(entry)
  local profile = agent.profile or (registry.get(id) and registry.get(id).profile) or id

  local function external()
    if type(agent.command) ~= "string" or agent.command == "" then
      return nil, "agent " .. id .. " has no command"
    end
    return {
      command = agent.command,
      args = vim.deepcopy(agent.args or {}),
      env = agent.env and vim.deepcopy(agent.env) or nil,
      profile = profile,
      source = "external",
      agent_id = id,
    }
  end

  if source == "external" then
    return external()
  end
  if source == "managed" and overridden then
    return nil,
      string.format(
        'agents.%s sets both source = "managed" and its own command/args; '
          .. "keep the command for external installs, or remove it to let acp.nvim manage the package",
        id
      )
  end
  if source == "auto" and overridden then
    -- An explicit command always wins: the user is telling us which binary to run.
    return external()
  end
  if source == "managed" or source == "auto" then
    local package = registry.package_of(id)
    if not package then
      if source == "managed" then
        return nil, id .. ' has no manager-owned package; use source = "external"'
      end
      -- auto with nothing installable: the preset command is the only option.
      return external()
    end
    local use_store = store or M.new_store(config)
    local state = use_store:state(id)
    if state.status == "installed" then
      local entry_path = state.entry
      local node = (type(config.manager) == "table" and config.manager.node) or "node"
      -- A managed launch replaces the whole command line: the preset args belong
      -- to the external form (`npx -y <pkg>`), and appending them here would
      -- pass npx flags to the adapter itself.
      return {
        command = node,
        args = { entry_path },
        env = agent.env and vim.deepcopy(agent.env) or nil,
        profile = profile,
        source = "managed",
        agent_id = id,
        install_id = state.install_id,
        version = state.install and state.install.version or nil,
        package = package,
      }
    end
    if state.status == "broken" then
      return nil,
        string.format(
          "%s is installed but unusable (%s); reinstall it with :Acp install %s",
          id,
          tostring(state.error),
          id
        )
    end
    if source == "managed" then
      return nil, id .. " is not installed; run :Acp install " .. id
    end
  end

  return external()
end

---Describe where an agent's command comes from, for the UI and health check.
---
---Never fails: an unresolvable agent is reported as `unavailable` with the
---reason, so a status list can show every agent.
---@param config table
---@param id string
---@param provenance table|nil
---@param store table|nil
---@return table description
function M.describe(config, id, provenance, store)
  local spec, err = M.resolve(config, id, provenance, store)
  if spec then
    return {
      id = id,
      source = spec.source,
      command = spec.command,
      args = spec.args,
      version = spec.version,
      install_id = spec.install_id,
      available = true,
    }
  end
  return { id = id, available = false, error = err }
end

return M
