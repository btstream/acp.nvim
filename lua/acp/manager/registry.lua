-- Built-in ACP adapter catalogue.
--
-- This is metadata only: how a package is fetched, which executable it ships and
-- what it needs at runtime. Protocol knowledge (modes, questions, terminal
-- output) stays in `acp.agents`; keeping the two apart means adding an agent
-- does not teach the installer anything about ACP.
--
-- Nothing here is fetched from the network at runtime. Every entry was checked
-- against the published npm package and its repository before being marked
-- installable; the `verified` field records that check so a future edit cannot
-- quietly promote an unverified package.
local M = {}

---@class AcpAgentPackage
---@field id string
---@field title string
---@field profile string
---@field package string npm name
---@field bin string the executable name the package ships
---@field entry string path inside the package that `bin` points at
---@field homepage string
---@field license string
---@field node_major integer minimum Node.js major version
---@field installable boolean false when the source is not verified yet
---@field verified string|nil when and what was verified
---@field requires string[] human-readable runtime requirements (not installed)
---@field notes string[]|nil caveats shown before installing

---@type table<string, AcpAgentPackage>
local REGISTRY = {
  claude = {
    id = "claude",
    title = "Claude ACP",
    profile = "claude",
    package = "@agentclientprotocol/claude-agent-acp",
    bin = "claude-agent-acp",
    entry = "dist/index.js",
    homepage = "https://github.com/agentclientprotocol/claude-agent-acp",
    license = "Apache-2.0",
    node_major = 22,
    installable = true,
    verified = "2026-11-13 npm 0.107.0: bin/paths/engines checked, published by Zed Industries with provenance",
    requires = { "Claude 凭据（由 adapter 自行登录，acp.nvim 不接管）" },
    notes = {
      "由 Zed Industries 发布，包内 engines 要求 Node.js >= 22。",
    },
  },
  pi = {
    id = "pi",
    title = "pi ACP",
    profile = "pi",
    package = "@geohar/pi-acp",
    bin = "pi-acp",
    entry = "dist/index.js",
    homepage = "https://github.com/georgeharker/pi-acp",
    license = "MIT",
    node_major = 22,
    installable = true,
    verified = "2026-11-13 npm 0.4.0: bin/paths checked, maintainer georgeharker, provenance present",
    requires = {
      "pi CLI v0.80.4+（@earendil-works/pi-coding-agent），需要单独安装",
      "pi 自己的模型 provider 与 API key",
    },
    notes = {
      "只使用 georgeharker/pi-acp 这个 fork（npm 名 @geohar/pi-acp），不是无 scope 的 pi-acp。",
      "adapter 会启动 pi --mode rpc；只装 adapter 但没有 pi CLI 时无法运行。",
      "包内 engines 写 Node.js >= 20，上游 README 要求 22+；这里按 22 检查。",
    },
  },
  -- OpenCode has no verified npm adapter package: it ships its own CLI, so the
  -- manager only reports what is already on PATH.
  opencode = {
    id = "opencode",
    title = "OpenCode",
    profile = "opencode",
    package = "opencode",
    bin = "opencode",
    entry = "",
    homepage = "https://opencode.ai/docs/",
    license = "",
    node_major = 0,
    installable = false,
    verified = "2026-11-13: distributed as its own CLI, not an npm adapter package",
    requires = { "opencode CLI（自行安装）" },
    notes = { "首版不托管安装：OpenCode 以独立 CLI 分发，不在 npm adapter 的范围内。" },
  },
}

---@return string[]
function M.ids()
  local out = {}
  for id in pairs(REGISTRY) do
    out[#out + 1] = id
  end
  table.sort(out)
  return out
end

---Look up one entry.
---@param id string
---@return AcpAgentPackage|nil
function M.get(id)
  return REGISTRY[id]
end

---Whether the manager may install this package.
---@param id string
---@return boolean
---@return string|nil reason
function M.installable(id)
  local entry = REGISTRY[id]
  if not entry then
    return false, "unknown agent " .. tostring(id)
  end
  if not entry.installable then
    return false, (entry.notes and entry.notes[1]) or "this agent is not installed by acp.nvim"
  end
  if not entry.verified then
    return false, "this package has not been verified against its published source"
  end
  return true
end

---The package name an id maps to, but only for managed installs.
---@param id string
---@return string|nil
function M.package_of(id)
  local entry = REGISTRY[id]
  return entry and entry.installable and entry.package or nil
end

return M
