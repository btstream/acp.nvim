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
  if switches.terminal_output_meta then
    caps._meta = caps._meta or vim.empty_dict()
    caps._meta.terminal_output = true
  end
  -- Boolean session config options are a declared capability, not a free
  -- default: an agent must not send `type: "boolean"` options to a client that
  -- did not advertise them.
  if switches.boolean_config_options then
    caps.session = caps.session or vim.empty_dict()
    caps.session.configOptions = { boolean = vim.empty_dict() }
  end
  return caps
end

---Agent capabilities for a client, tolerating lightweight test doubles.
---
---The predicate `has_session_capability` is the compatibility hook for doubles
---and the way tests revoke one capability without building a whole table. When
---present it is authoritative for the session subset.
---@param client table|nil
---@return table
function M.agent(client)
  local caps = {}
  local reported
  if client and type(client.agent_capabilities) == "function" then
    local value = client:agent_capabilities()
    if type(value) == "table" then
      reported = value
      caps = vim.tbl_extend("force", {}, value)
    end
  end
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
  -- A *bare* double that implements the call is stating support for it: the
  -- predicate exists to grant capability, not to deny an implemented method.
  -- A real client always implements every method, so this inference is limited
  -- to doubles that cannot report capabilities at all; otherwise an agent that
  -- explicitly advertises `loadSession: false` would look like it supports it.
  if reported == nil and client and type(client.load_session) == "function" then
    caps.loadSession = true
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
