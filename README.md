# acp.nvim

Neovim 原生的 [Agent Client Protocol](https://agentclientprotocol.com) 客户端，界面参照
[Zed 的 Agent Panel](https://zed.dev/docs/ai/agent-panel)，默认连接
[OpenCode](https://opencode.ai)，并把布局交给 [edgy.nvim](https://github.com/folke/edgy.nvim) 管理。

不是把 OpenCode 的 TUI 塞进终端窗口，而是用 Neovim 的 buffer、split 和 extmark 自己渲染
对话记录、工具调用和输入框。

```
┌──────────────────────────┬──────────────────────────────┐
│                          │ opencode · 重构认证中间件      │ ← winbar
│                          ├──────────────────────────────┤
│                          │ ❯ 你  [auth.lua] [选区 12-40] │
│                          │   把 token 校验提取成一个函数   │
│                          │                              │
│         编辑区            │ ▤ 计划                        │
│                          │   ✓ 阅读当前实现               │
│                          │   ◌ 提取校验逻辑               │
│                          │                              │
│                          │ ⏺ 我会先读取中间件，然后把…      │
│                          │                              │
│                          │ ▸ ✓ 编辑 auth.lua       完成  │
│                          │     +18 -11                  │
│                          ├──────────────────────────────┤
│                          │ Build · Claude Sonnet 5       │ ← 输入 winbar
│                          │ [auth.lua]                   │
│                          │ 输入消息…                     │
│                          │                        生成中 │
└──────────────────────────┴──────────────────────────────┘
```

## 特性

- **Zed 风格转录**：消息卡片、Markdown、代码块、可折叠工具调用、计划清单、压缩分隔线。
- **独立的输入区**：多行编辑、每个会话独立草稿、上下文附件、消息队列。
- **桌面级工具栏**：模式 / 模型 / 用量在左侧（模型和模式可直接点击切换），运行状态与待确认提示在右侧，窄窗口自动降级。
- **随窗口实时重排**：winbar 由表达式在每次重绘时按真实窗口宽度计算，resize、拆分或布局插件调整后不会出现截断标记或错位。
- **全局状态栏友好**：所有操作信息走 winbar，`laststatus=0/2/3` 都能正常工作；
  不修改 `statusline` 或 `laststatus`，另外提供可选的状态栏组件。
- **edgy 兼容**：两个普通视图（`acp_chat` / `acp_input`），由 edgy 决定位置与尺寸。
- **纯 Lua，零运行时依赖**：不强制依赖补全框架、UI 框架或图标字体。
- **优先适配 OpenCode**：模型 / 模式选择、slash 命令、子会话、重试、压缩、用量。

## 依赖

- Neovim 0.10 或更新（推荐 0.11+）
- 一个已登录的 ACP Agent。默认是 OpenCode：

```bash
opencode auth login
```

## 安装

### lazy.nvim

```lua
{
  "you/acp.nvim",
  dependencies = { "folke/edgy.nvim" }, -- 可选，但推荐
  cmd = { "Acp", "AcpLog", "AcpDebug" },
  opts = {},
}
```

最小配置即可使用：

```lua
require("acp").setup({})
```

## 使用

| 命令 | 说明 |
|---|---|
| `:Acp` 或 `:Acp toggle` | 打开 / 隐藏面板 |
| `:Acp open` / `:Acp hide` | 显式打开 / 隐藏 |
| `:Acp new` | 新建会话 |
| `:Acp stop` | 中止当前回合 |
| `:Acp sessions` | 选择并恢复历史会话 |
| `:Acp model` / `:Acp mode` | 切换模型 / 模式 |
| `:Acp reconnect` | Agent 崩溃后重连并恢复当前会话 |
| `:Acp disconnect` | 停止 Agent 进程（保留面板） |
| `:Acp permission` | 重新打开待确认的权限请求 |
| `:Acp file` | 附加当前文件 |
| `:Acp diagnostics` | 附加当前 buffer 的诊断 |
| `:AcpLog` | 打开日志 |
| `:AcpDebug` | 打印控制器状态 |

### 输入区

| 按键 | 说明 |
|---|---|
| `<C-s>` | 发送；回合进行中且输入框为空时改为中止 |
| `q` | 隐藏面板（不中断会话） |
| `<C-x><C-u>` | 补全 `/命令` 或 `@文件` |
| `@path/to/file` | 发送时自动作为附件 |
| 点击 winbar 的模型 / 模式 | 打开选择器 |
| `<M-m>` / `<M-b>` | 输入时选择模型 / 模式 |
| `M` / `m`（普通模式） | 选择模型 / 模式 |

### 转录区

| 按键 | 说明 |
|---|---|
| `i` / `<C-s>` | 聚焦输入框 |
| `<CR>` | 打开光标所在位置的文件 |
| `<Tab>` | 展开 / 折叠工具调用 |
| `[b` / `]b` | 上一个 / 下一个消息块 |
| `G` / `gg` | 最新 / 最早 |
| `S` | 附加当前选区 |
| `F` | 附加当前文件 |
| `R` | 附加诊断 |
| `M` / `m` | 选择模型 / 模式 |
| `<C-n>` | 新建会话 |
| `L` | 历史会话 |
| `g?` | 帮助 |
| `q` | 隐藏面板 |

所有按键都是 buffer-local，不会污染全局映射。

## 配置

```lua
require("acp").setup({
  agent = "opencode",
  agents = {
    opencode = { command = "opencode", args = { "acp" } },
    -- 任何 ACP Agent 都可以这样接入
    other = { command = "my-agent", args = { "--acp" } },
  },

  -- 默认为项目根目录（lazy.nvim 可用时）或当前文件所在目录
  cwd = nil,

  layout = {
    backend = "native",   -- "native" | "external"（edgy 等布局管理器）
    position = "right",
    width = 0.38,         -- 0~1 为比例，>1 为绝对列数
    min_width = 42,
    max_width = 120,
    input_height = 8,
    focus_input_on_open = true,
    restore_focus = true,
  },

  ui = {
    icons = true,         -- false 时使用纯 ASCII
    show_thoughts = false,
    follow_output = true,
    wrap = true,
    language = "zh",      -- "zh" | "en"
    zed_style = true,
    title = { placement = "auto" },   -- "auto" | "winbar" | "off"
    toolbar = {
      placement = "auto",             -- "auto" | "winbar" | "off"
      show_usage = false,
      animate = true,
      animation_interval = 120,
    },
  },

  keymaps = {
    send = "<C-s>",
    cancel = "<C-c>",
    close_panel = "q",
    focus_input = "i",
    open_location = "<CR>",
    prev_block = "[b",
    next_block = "]b",
    toggle_block = "<Tab>",
  },

  permissions = {
    prompt = "select",
    -- 谨慎使用：自动放行的 option kind
    auto_allow = {},
  },

  context = {
    max_file_bytes = 512 * 1024,
    max_selection_lines = 2000,
  },

  log = {
    level = "warn",       -- trace|debug|info|warn|error
    protocol = false,     -- true 时记录（脱敏后的）协议载荷
    max_bytes = 1024 * 1024,
  },
})
```

## 与 edgy.nvim 集成

把布局所有权交给 edgy：

```lua
{
  "folke/edgy.nvim",
  event = "VeryLazy",
  init = function()
    vim.opt.laststatus = 3        -- 面板才能完整折叠
    vim.opt.splitkeep = "screen"  -- 打开侧栏时编辑区不跳动
  end,
  opts = function(_, opts)
    -- 把 acp 的两个视图加到右侧 edgebar
    require("acp.integrations.edgy").extend(opts)
  end,
}
```

```lua
require("acp").setup({
  layout = { backend = "external" },
})
```

`extend()` 只是把下面两个 view 定义插入你的 `opts.right`，不会覆盖已有配置：

```lua
right = {
  { ft = "acp_chat",  title = "Agent",   size = { width = 0.38 }, wo = { winbar = false, winfixwidth = true } },
  { ft = "acp_input", title = "Message", size = { height = 8 },    wo = { winbar = false, winfixwidth = true } },
}
```

### 谁是 winbar 的所有者

默认 **acp 拥有两个 winbar**（这里是标题栏和操作栏），edgy 只负责位置和尺寸。
如果你希望 edgy 显示自己的标题栏：

```lua
require("acp.integrations.edgy").views({
  title_winbar = true,  -- chat 视图交给 edgy
})
-- 再配合：
require("acp").setup({
  layout = { backend = "external" },
  ui = { title = { placement = "off" }, toolbar = { placement = "off" } },
})
```

### 布局语义

| 操作 | 行为 |
|---|---|
| `:Acp hide` / `q` | 关闭两个视图，**不中断** Agent 与当前回合 |
| 单独关闭某个视图 | 不会被强行重开；下次 `:Acp open` 才补回 |
| `:Acp toggle` | 任一视图可见时隐藏，否则打开 |

外部布局模式下，acp 不会持续调整窗口尺寸，也不抢回被布局管理器移动的窗口。

## 状态栏集成

插件**不修改** `vim.o.statusline` 和 `vim.o.laststatus`。所有交互信息都在输入窗口的 winbar 里，
因此 `laststatus=3`（全局状态栏）下也完全正常。

需要把状态放进你自己的状态栏时：

```lua
-- 简短文本，例如 "◆"、"◆ ◌"、"◆ !"
require("acp").statusline()

-- 结构化数据
require("acp").status()
-- {
--   connected = true, connection = "ready",
--   running = false, waiting_permission = false, queued = 0,
--   agent = "opencode", model = "Claude Sonnet 5", mode = "Build",
--   session_id = "ses_...", usage = { used = 42000, size = 200000 },
-- }
```

lualine 示例：

```lua
{
  "acp",
  function()
    return require("acp").statusline()
  end,
  cond = function()
    return require("acp").status().connected
  end,
}
```

heirline 同理，只需调用 `statusline()` 或读取 `status()`。

## 外观

所有样式都通过语义化高亮组暴露，直接覆盖即可：

```lua
vim.api.nvim_set_hl(0, "AcpUser", { link = "Function" })
vim.api.nvim_set_hl(0, "AcpToolTitle", { fg = "#7aa2f7" })
vim.api.nvim_set_hl(0, "AcpSeparator", { fg = "#3b4261" })
```

可用的组：`AcpNormal` `AcpMuted` `AcpBorder` `AcpTitle` `AcpToolbar` `AcpToolbarAccent`
`AcpUser` `AcpUserChip` `AcpAssistant` `AcpThought` `AcpToolTitle` `AcpToolRunning`
`AcpToolSuccess` `AcpToolError` `AcpCode` `AcpCodeFence` `AcpInlineCode` `AcpHeading`
`AcpQuote` `AcpLink` `AcpPlan` `AcpPlanDone` `AcpPlanPending` `AcpNotice` `AcpPermission`
`AcpChild` `AcpSeparator` `AcpStreaming` `AcpSelection`

`ui.icons = false` 会把所有图标换成 ASCII，适用于不支持的终端。

## 权限与安全

- ACP 本身不是沙箱，插件无法限制 Agent 进程访问文件系统。
- 只声明真正实现的客户端能力；未实现的 `fs/*` 和 `terminal/*` 请求会返回标准 JSON-RPC 错误。
- Agent 提供的标题、路径、链接都按不可信文本渲染，不自动执行、不自动打开。
- 写入由 Agent 自身完成；acp.nvim 不会静默保存或覆盖你的 buffer。
- 日志默认不记录密钥与完整提示词；开启 `log.protocol` 时会先脱敏再截断。

## 行为细节

### 消息排队

同一会话同时只运行一个 prompt。生成中提交的消息会本地排队，
当前回合结束后依次发送，工具栏显示 `+N queued`。

### 中断与恢复

Agent 崩溃或退出时，正在运行的工具会被标记为失败，并提示 `:Acp reconnect`。
重连会调用 `session/load` 重放 Agent 侧历史，不会自动重发上一条 prompt。

### 草稿持久化

未发送的输入和附件按「项目 + 会话」保存在
`stdpath("state")/acp/drafts.json`，重启后自动恢复。空草稿会被清除，
最多保留 50 条。

### 切换模型与模式

有三种方式，任选其一：

1. **直接点击** winbar 上的 `模型名 ▾` 或 `模式名 ▾`（需要 `set mouse=a`）。
2. 输入时按 `<M-m>` 切换模型、`<M-b>` 切换模式。
3. 普通模式按 `M` / `m`，或执行 `:Acp model` / `:Acp mode`。

选择器支持模糊过滤：直接输入关键字即可筛选。OpenCode 可能返回上百个模型，
过滤器会让它保持可用。选中后立即生效，工具栏同步更新。

> 不要使用 `<C-m>`：在终端里它与 `<CR>` 是同一个键。

### 权限请求

Agent 请求权限时弹出选择器：

- `Esc` / `q` 关闭视为拒绝，优先选择 `reject_*` 选项；
  若 Agent 没有提供拒绝项，则返回 `cancelled`。
- 关闭面板不会让权限请求永久挂起。
- 可用 `permissions.auto_allow = { "allow_always" }` 显式放开某类请求。

## 已知限制

- 未实现客户端侧的文件读写与终端能力（`fs/read_text_file`、`terminal/*`），
  这些功能由 Agent 自行完成。
- 修改审阅（逐块接受 / 拒绝）尚未提供，目前可展开工具调用查看 diff 摘要与文件位置。
- 会话历史来自 Agent（`session/list`），acp.nvim 不额外保存一份对话库。
- 部分能力（压缩、用量、子会话）依赖 Agent 的扩展，缺失时会自动降级。

## 开发

```bash
# 单元测试
nvim --headless -u tests/minimal_init.lua -l tests/run.lua

# 界面集成测试（含 laststatus=0/2/3）
nvim --headless -u tests/minimal_init.lua -l tests/integration.lua

# edgy 兼容性测试
nvim --headless -u tests/minimal_init.lua -l tests/integration_edgy.lua

# 布局预览
nvim --headless -u tests/minimal_init.lua -l tests/render_preview.lua

# 真实 OpenCode 冒烟测试（需要已登录）
nvim --headless -u tests/minimal_init.lua -l tests/manual_opencode.lua
```

`:checkhealth acp` 会检查 Neovim 版本、Agent 可执行文件、edgy 与日志路径。

## 许可证

MIT
