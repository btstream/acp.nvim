-- Client capability declaration and agent capability queries.
--
-- Declarations are derived from config and from what the client actually
-- implements. Every switch defaults off until the matching phase lands, so an
-- agent never sees a promise the plugin cannot keep.
local M = {}

---Agent capabilities that are always present after a successful initialize.
---@param config table
---@return table
function M.client(config)
  -- Encode capability objects as JSON objects (vim.empty_dict), not arrays.
  local caps = vim.empty_dict()
  if config.notices then
    caps.session = { notices = vim.empty_dict() }
  end
  local switches = config.capabilities or {}
  local elicitation = switches.elicitation or {}
  if elicitation.form or elicitation.url then
    caps.elicitation = vim.empty_dict()
    if elicitation.form then
      caps.elicitation.form = vim.empty_dict()
    end
    if elicitation.url then
      caps.elicitation.url = vim.empty_dict()
    end
  end
  if switches.auth_terminal then
    caps.auth = { terminal = true }
    caps._meta = { ["terminal-auth"] = true }
  end
  return caps
end

---Agent capabilities for a client, tolerating lightweight test doubles.
---@param client table|nil
---@return table
function M.agent(client)
  local caps = {}
  if client and type(client.agent_capabilities) == "function" then
    local value = client:agent_capabilities()
    if type(value) == "table" then
      caps = vim.tbl_extend("force", {}, value)
    end
  end
  -- A predicate is the compatibility hook used by lightweight doubles and by
  -- tests that revoke one capability; let it override the session subset.
  if client and type(client.has_session_capability) == "function" then
    local session_caps = {}
    for _, name in ipairs({ "list", "resume", "close", "delete", "fork" }) do
      if client:has_session_capability(name) then
        session_caps[name] = {}
      end
    end
    caps.sessionCapabilities = session_caps
    if client:has_session_capability("loadSession") then
      caps.loadSession = true
    end
  end
  return caps
end

---Whether the agent accepts a prompt content type, via the client method when
---available (doubles may implement only that).
---@param client table|nil
---@param name string
---@return boolean
function M.prompt(client, name)
  if client and type(client.supports_prompt) == "function" then
    return client:supports_prompt(name) and true or false
  end
  return M.supports(M.agent(client), "promptCapabilities." .. name)
end

---Read a dotted capability path, treating anything missing as unsupported.
---
---An advertised capability object (for example `{ form = {} }`) counts as
---supported when the path ends on it; only `false` and null are unsupported.
---@param caps table|nil
---@param path string e.g. "prompt.image" or "session.list"
---@return boolean
function M.supports(caps, path)
  local node = caps
  for part in path:gmatch("[^.]+") do
    if type(node) ~= "table" then
      return false
    end
    node = node[part]
    if node == nil or node == vim.NIL or node == false then
      return false
    end
  end
  return node ~= nil and node ~= vim.NIL and node ~= false
end

return M
