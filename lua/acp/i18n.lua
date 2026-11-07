-- UI strings. Only chrome is translated; agent content is never rewritten.
local M = {}

local strings = {
  en = {
    panel_title = "Agent",
    no_session = "No session",
    input_placeholder = "Message the agent",
    send = "Send",
    stop = "Stop",
    running = "Running",
    idle = "Idle",
    queued = "queued",
    waiting = "Waiting",
    thinking = "Thinking",
    tool_running = "running",
    tool_pending = "pending",
    tool_completed = "done",
    tool_failed = "failed",
    tool_cancelled = "cancelled",
    plan = "Plan",
    you = "You",
    attach_file = "file",
    attach_selection = "selection",
    select_model = "Model",
    select_mode = "Mode",
    select_config = "Configure",
    select_session = "Sessions",
    permissions_title = "Permission required",
    permission_cancelled = "Permission request cancelled",
    started = "Session started",
    stopped = "Session stopped",
    connected = "Connected to %s",
    disconnected = "Agent disconnected",
    auth_hint = "OpenCode requires authentication. Run `opencode auth login` in a terminal, then reconnect.",
    quota_hint = "This is a provider-side limit, not an acp.nvim error. Click the model name in the toolbar, press <M-m> while typing, or run :Acp model.",
    no_locations = "No file location under cursor",
    usage = "Context",
    compaction = "Context compacted",
    retry = "Retrying",
    child = "subagent",
    notice = "Notice",
    empty_chat = "Start a conversation with the agent.",
    confirm_new = "Start a new session?",
    current_session = "current",
    delete_session = "Delete session",
    delete = "Delete",
    cancel = "Cancel",
    confirm_delete = 'Delete session "%s"? This cannot be undone.',
    confirm_delete_active = "This is the active session; a new one will be started.",
    delete_unsupported = "This agent does not support deleting sessions",
    no_session_list = "This agent does not support listing sessions",
    no_sessions_found = "No stored sessions found",
    session_deleted = "Session deleted",
    errors = {
      not_running = "No agent process is running",
      no_session = "No active session",
      list_failed = "Unable to list sessions: %s",
      delete_failed = "Unable to delete the session: %s",
    },
  },
  zh = {
    panel_title = "Agent",
    no_session = "未连接",
    input_placeholder = "输入消息",
    send = "发送",
    stop = "停止",
    running = "生成中",
    idle = "空闲",
    queued = "条排队",
    waiting = "等待确认",
    thinking = "思考中",
    tool_running = "执行中",
    tool_pending = "等待",
    tool_completed = "完成",
    tool_failed = "失败",
    tool_cancelled = "已取消",
    plan = "计划",
    you = "你",
    attach_file = "文件",
    attach_selection = "选区",
    select_model = "模型",
    select_mode = "模式",
    select_config = "会话配置",
    select_session = "历史会话",
    permissions_title = "需要确认",
    permission_cancelled = "权限请求已取消",
    started = "会话已开始",
    stopped = "会话已停止",
    connected = "已连接 %s",
    disconnected = "Agent 已断开",
    auth_hint = "OpenCode 需要先登录。请在终端运行 `opencode auth login`，然后重新连接。",
    quota_hint = "这是模型服务商的额度限制，不是 acp.nvim 的错误。点击工具栏上的模型名、输入时按 <M-m>，或执行 :Acp model 切换模型。",
    no_locations = "光标所在行没有文件位置",
    usage = "上下文",
    compaction = "上下文已压缩",
    retry = "重试中",
    child = "子会话",
    notice = "提示",
    empty_chat = "开始与 Agent 对话。",
    confirm_new = "要开始新的会话吗？",
    current_session = "当前",
    delete_session = "删除会话",
    delete = "删除",
    cancel = "取消",
    confirm_delete = "确定删除会话「%s」？此操作无法撤销。",
    confirm_delete_active = "这是当前会话，删除后会为你新建一个会话。",
    delete_unsupported = "该 Agent 不支持删除会话",
    no_session_list = "该 Agent 不支持列出会话",
    no_sessions_found = "没有找到已保存的会话",
    session_deleted = "会话已删除",
    errors = {
      not_running = "Agent 进程未运行",
      no_session = "没有活动会话",
      list_failed = "列出会话失败：%s",
      delete_failed = "删除会话失败：%s",
    },
  },
}

local current = "zh"

function M.setup(lang)
  if strings[lang] then
    current = lang
  end
end

---@param key string
---@param ... any
---@return string
---Look up a possibly dotted key, e.g. "errors.not_running".
---@param pack table
---@param key string
---@return any
local function lookup(pack, key)
  local value = pack[key]
  if value ~= nil then
    return value
  end
  local node = pack
  for part in key:gmatch("[^%.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
    if node == nil then
      return nil
    end
  end
  return node
end

function M.t(key, ...)
  local pack = strings[current] or strings.en
  local value = lookup(pack, key)
  if value == nil then
    value = lookup(strings.en, key) or key
  end
  if type(value) == "string" and select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, value, ...)
    if ok then
      return formatted
    end
  end
  return value
end

function M.lang()
  return current
end

return M
