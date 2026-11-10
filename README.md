# acp.nvim

Neovim 原生的 [Agent Client Protocol](https://agentclientprotocol.com) 客户端，界面参照
[Zed 的 Agent Panel](https://zed.dev/docs/ai/agent-panel)，默认连接
[OpenCode](https://opencode.ai)。默认使用原生分屏布局，也可交给
[edgy.nvim](https://github.com/folke/edgy.nvim) 等外部布局管理器。

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
- **工具栏**：左侧是模式徽标、模型名与可选用量，右侧是状态图标 / 动画与队列数量；模式和模型可点击，窄窗口优先保留状态。
- **随窗口实时重排**：winbar 由表达式在每次重绘时按真实窗口宽度计算，resize、拆分或布局插件调整后不会出现截断标记或错位。
- **转录随宽度重排**：聊天窗口宽度变化后自动重新排列表格、卡片和分隔线；连续拖动采用
  100ms 防抖，期间流式内容照常更新。阅读历史时尽量保持所在 block 与视口，不误报新消息。
- **全局状态栏友好**：所有操作信息走 winbar，`laststatus=0/2/3` 都能正常工作；
  不修改 `statusline` 或 `laststatus`，另外提供可选的状态栏组件。
- **edgy 兼容**：两个普通视图（`acp_chat` / `acp_input`），由 edgy 决定位置与尺寸。
- **纯 Lua，零运行时依赖**：不强制依赖补全框架、UI 框架或图标字体。
- **优先适配 OpenCode**：模型 / 模式选择、slash 命令补全、历史会话与删除，渲染 Agent 提供的子代理、重试、压缩与用量信息。

## 依赖

- Neovim 0.10 或更新（推荐 0.12+；0.10/0.11 使用兼容高亮语法）
- 代码块语法高亮可选依赖对应语言的 Tree-sitter parser 与 highlights query；缺失时显示纯文本，不影响对话。
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
| `:Acp sessions` | 打开会话浏览器：`<CR>` 切换、`<C-d>` 删除、输入即过滤 |
| `:Acp delete` | 打开同一个会话浏览器，用 `<C-d>` 删除选中会话 |
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
| `<C-c>`（普通模式） | 中止当前回合 |
| `q`（普通模式） | 隐藏面板（不中断会话） |
| `L`（普通模式） | 历史会话 |
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
| `<Tab>` | 展开 / 折叠工具调用或思考块；不可折叠时聚焦输入框 |
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

  -- 会话的工作目录。默认与 Neovim 的 cwd 一致（vim.fn.getcwd()）。
  cwd = nil,

  -- 本地保留的载荷预算，不是 Lua/Neovim RSS 的硬上限。
  memory = {
    max_block_bytes = 1024 * 1024,
    max_session_bytes = 16 * 1024 * 1024,
    max_cached_sessions = 8,
    max_total_bytes = 64 * 1024 * 1024,
    max_queued_messages = 16,
    max_queue_bytes = 4 * 1024 * 1024,
    max_drafts = 20,
  },

  layout = {
    backend = "native",   -- "native" | "external"（edgy 等布局管理器）
    position = "right",
    width = 0.38,         -- 0.05~1 为比例，>1 为绝对列数
    min_width = 42,
    max_width = 120,
    input_height = 8,
    min_input_height = 4,
    max_input_height = 24,
    focus_input_on_open = true,
    restore_focus = true,
    -- 锁定 ACP 窗口，阻止其它 buffer 占用（winfixbuf）
    lock_buffer = true,
  },

  ui = {
    icons = true,         -- false 时使用纯 ASCII
    -- 旧键，等价于 thoughts.default_expanded = true
    show_thoughts = false,
    thoughts = {
      default_expanded = false,      -- 默认展开思考内容
      show_collapsed_header = true,  -- 折叠时显示 "Thinking" 头部
    },
    follow_output = true,
    wrap = true,
    picker = "vim",       -- "vim" = vim.ui.select（推荐）| "internal" = 内置浮窗
    session_picker = "snacks", -- "snacks"（可用时）| "internal"
    highlights = {},      -- 覆盖任意高亮组，见「外观」
    title = { placement = "auto" },   -- "auto" | "winbar" | "off"
    toolbar = {
      placement = "auto",             -- "auto" | "winbar" | "off"
      show_usage = false,
      animate = true,
      animation_interval = 120,
    },
    separator = {
      form = "dot",                   -- "dot" | "turn" | "off"
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

  notices = true,         -- 显示 Agent 的时间线通知

  transport = {
    -- 单条 JSON 消息的字节上限；超过会断开连接
    max_line_bytes = 8 * 1024 * 1024,
    -- 保留多少字节的 agent stderr 用于诊断
    stderr_keep_bytes = 64 * 1024,
    -- 关闭时等待 agent 自行退出的毫秒数，超时后升级为 SIGKILL
    shutdown_timeout = 2000,
    -- 普通请求的超时（毫秒，0 表示不限制）
    request_timeout = 30000,
    -- 单轮对话的绝对上限（毫秒，0 表示不限制）；默认 10 分钟
    prompt_timeout = 600000,
    max_pending_bytes = 16 * 1024 * 1024, -- 待分发消息及队列开销的估算预算
    dispatch_budget_ms = 4,               -- 每批处理后让出主循环；无法抢占单条请求
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

`extend()` 只是把下面两个 view 定义插入你的 `opts.right`，不会覆盖已有配置。

> **注意**：两个视图必须作为**数组元素**写进列表，不能写成具名字段。
> edgy 只遍历 `ipairs(views)`，`right = { { ft = "acp_chat" }, input = { ft = "acp_input" } }`
> 里的 `input` 是具名字段，edgy 会完全忽略它，导致输入框脱离 edgebar、
> 布局错位。

```lua
-- 正确
right = {
  { ft = "acp_chat",  title = "Agent", wo = { winbar = false } },
  { ft = "acp_input", title = "Message", size = { height = 8 }, wo = { winbar = false } },
}

-- 错误：acp_input 是具名字段，edgy 不会管理它
right = {
  { ft = "acp_chat", title = "Agent" },
  input = { ft = "acp_input", title = "Message" },
}
```

acp.nvim 在无法接管时会给出警告，而不是静默错位。

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
  toolbar_winbar = false, -- input 视图也交给 edgy
})
-- 再配合：
require("acp").setup({
  layout = { backend = "external" },
  ui = { title = { placement = "off" }, toolbar = { placement = "off" } },
})
```

`views()` 返回 `{ chat = ..., input = ... }`，不是数组；须把两项放入 edgy 的视图列表，
或直接在配置函数中调用 `extend(opts, { title_winbar = true, toolbar_winbar = false })`。
左侧布局使用 `extend(opts, { position = "left" })`，并同步设置 ACP 的 `layout.position`。

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

## 轮次分隔符

默认在每两轮对话之间画一条细分隔线，中间一个圆点：

```
────────────────────────── ● ──────────────────────────
```

`ui.separator.form` 控制样式：

| 值 | 效果 |
|---|---|
| `"dot"` | 细分隔线 + 居中圆点（默认） |
| `"turn"` | 细分隔线 + 轮次，形如 `󰇚 Turn 2` |
| `"off"` | 不画分隔符 |

```lua
require("acp").setup({
  ui = { separator = { form = "turn" } },
})
```

面板太窄、放不下两侧的线时，只保留中间的标记。分隔符本身不绑定任何 block，
光标停在上面时 `<Tab>` 不会误展开相邻的卡片。

## 外观

样式使用**静态定义**，多数链接到 Neovim / Tree-sitter 高亮组；模式徽标默认使用固定
前景和背景色，可通过 `ui.highlights` 覆盖。插件不在运行时混合主题颜色。
正文里的 Markdown（粗体、斜体、删除线、标题、引用、链接）链接
到 treesitter 的 `@markup.*` 捕获组，所以在对话记录里的呈现和普通 Markdown buffer
遵循主题的相应样式，但渲染器并非完整的 Markdown 实现。

`acp_chat` 的标题栏（winbar）与正文共用同一个背景（`AcpNormal`），读起来是对话
记录的页眉，而不是一条独立的色带。`acp_input` 的工具栏仍然用 `StatusLine` 的颜色，
因为它是工具栏而非页眉。

对话记录的标题行拆成了图标和文字两组：`AcpUserIcon` / `AcpUserTitle`、
`AcpAssistantIcon` / `AcpAssistantTitle`。用户标题默认链接到用户图标；助手两组默认均链接到 `Keyword`；
想区分时单独覆盖即可。助手回合开头的 Markdown 标题会用 `AcpAssistantTitle`，
正文中间的标题仍保留各自的 `AcpH1`–`AcpH4` 级别。

两处例外，都是为了让表格读起来安静一些：

- 行内代码链接到 `String`。`@markup.raw` 在多数主题里是暖色强调色，放在正文中
  会抢注意力。
- 表格边框链接到 `NonText`。`@punctuation.special` 会被主题染成橙色、品红之类
  的高亮色，整个表格会变成霓虹网格。

两种覆盖方式，都会优先于内置定义：

1. 在 `setup()` 里通过 `ui.highlights` 传入
2. 任何时候直接 `vim.api.nvim_set_hl`

```lua
require("acp").setup({
  ui = {
    highlights = {
      AcpUser = { link = "Identifier" },
      AcpToolTitle = { fg = "#7aa2f7" },
    },
  },
})

-- 等价，但不必重新 setup
vim.api.nvim_set_hl(0, "AcpSeparator", { fg = "#3b4261" })
```

切换 colorscheme 后会重新应用内置定义与 `ui.highlights` 配置。
直接 `nvim_set_hl` 的临时覆盖不保证跨主题保留；需持久化时使用配置或自己的 `ColorScheme` 回调。
Neovim 0.12+ 的工具栏区域继承背景；旧版本使用兼容语法，外部插件重映射 `WinBar` 时颜色可能不同。

可用的组：`AcpNormal` `AcpMuted` `AcpBorder` `AcpTitle` `AcpToolbar` `AcpToolbarAccent`
`AcpToolbarModePlan` `AcpToolbarModeBuild` `AcpToolbarIdle` `AcpToolbarRunning`
`AcpToolbarWaiting` `AcpToolbarCancelling` `AcpUser` `AcpUserChip` `AcpAssistant`
`AcpUserIcon` `AcpUserTitle` `AcpAssistantIcon` `AcpAssistantTitle`
`AcpThought` `AcpToolTitle` `AcpToolTag` `AcpCardBg` `AcpCodeBlockBg` `AcpCodeLang`
`AcpTableHead` `AcpTableBorder` `AcpToolRunning` `AcpToolSuccess` `AcpToolError`
`AcpToolCancelled` `AcpMdCode` `AcpBold` `AcpItalic` `AcpStrike` `AcpMdLink` `AcpH1`
`AcpH2` `AcpH3` `AcpH4` `AcpQuote` `AcpLink` `AcpPlan` `AcpPlanDone` `AcpPlanPending`
`AcpNotice` `AcpNoticeWarn` `AcpNoticeError` `AcpPermission` `AcpChild` `AcpSeparator`
`AcpStreaming` `AcpSelection` `AcpPinned`

插件自绘的 picker（`ui.picker = "internal"` 的模型/模式/权限选择框，以及
`:Acp sessions` 的内置窗口）另有一套组，默认都链接到主题组：

| 组 | 默认链接 | 作用 |
|---|---|---|
| `AcpPickerNormal` | `NormalFloat` | 浮窗背景与普通文字 |
| `AcpPickerBorder` | `FloatBorder` | 圆角边框 |
| `AcpPickerTitle` | `FloatTitle` | 浮窗标题 |
| `AcpPickerSelection` | `AcpSelection` | 光标所在行 |
| `AcpPickerItem` | `Normal` | 每行的标题文字 |
| `AcpPickerMatch` | `Search` | 过滤时命中的字符 |
| `AcpPickerCurrent` | `StatusLine` | 当前会话的箭头、`✓ current` |
| `AcpPickerCurrentItem` | `AcpTitle` | 当前行标题（只强调前景，不画背景） |
| `AcpPickerDescription` | `Comment` | 行尾右对齐的描述 |
| `AcpPickerMeta` | `Comment` | 会话列表里的更新时间 |
| `AcpPickerEmpty` | `Comment` | `no match` / `no matching sessions` |
| `AcpPickerSeparator` | `NonText` | 列表与页脚之间的分隔线 |
| `AcpPickerPrompt` | `AcpToolbarAccent` | 过滤提示符与输入内容 |
| `AcpPickerFooter` | `Comment` | 页脚提示与临时状态（`deleting...`） |

浮窗的边框、标题和背景通过 `winhighlight` 映射到前三个组，因此在
`style = "minimal"` 的浮窗里也能单独改色，而不必动全局的 `NormalFloat`。
`AcpPickerItem` 链接到 `Normal`：浮窗里 `winhighlight` 已经把 `Normal` 映射到
`AcpPickerNormal`，而 snacks 列表里它仍然是列表自己的背景色，不会多出一层浮窗底色。

snacks 后端只接管行内容：它的窗口沿用你已有的 snacks 主题，不套用上面三组。

`ui.icons = false` 会把所有图标换成 ASCII，适用于不支持的终端。

## 权限与安全

- ACP 本身不是沙箱，插件无法限制 Agent 进程访问文件系统。
- 只声明真正实现的客户端能力；未实现的 `fs/*` 和 `terminal/*` 请求会返回标准 JSON-RPC 错误。
- Agent 提供的标题、路径、链接都按不可信文本渲染，不自动执行、不自动打开。
- 写入由 Agent 自身完成；acp.nvim 不会静默保存或覆盖你的 buffer。
- 日志默认不记录密钥与完整提示词；开启 `log.protocol` 时会先脱敏再截断。

## 行为细节

### 工作目录

会话的工作目录默认就是 **Neovim 的当前目录**（`vim.fn.getcwd()`），面板、Agent
和你看到的是同一个目录。可以用 `cwd` 显式固定：

```lua
require("acp").setup({ cwd = "/home/user/projects/my-app" })
```

`:Acp sessions` 的列表也按这个目录过滤。若该目录下没有会话，acp.nvim 会自动
退回展示 Agent 知道的所有会话，而不是提示「没有会话」。

> 切换到历史会话时，acp.nvim 会使用**该会话自己的目录**发起 `session/load`。
> ACP 规范要求 cwd 与会话一致，Agent 会在不匹配时拒绝该请求。

### 面板尺寸

原生布局的 `layout.width` 为 `0.05~1` 时按编辑器宽度取比例，`>1` 时为绝对列数。
先应用 `min_width` / `max_width`，再限制为编辑器宽度的 60%；窄屏或窗口空间不足时，
实际宽度可能小于 `min_width`。输入高度受 `min_input_height` / `max_input_height` 约束。
外部布局模式下由布局管理器决定这些尺寸。

两个面板窗口均设置 `statuscolumn = " "`，不覆盖用户全局的行号栏配置。

构建面板时会临时关闭 `'equalalways'`，等两个窗口都创建完、尺寸设置好之后再恢复。
否则第二次 split 会立刻重排，把配置的宽度覆盖掉。

### 会话标题

标题显示在对话记录窗口的标题栏（winbar）里，未生成时回退为会话 ID 短码。

为兼容未推送 `session_info_update` 的 OpenCode 版本，
acp.nvim 在**会话创建后、切换会话后、以及每回合结束后**查询列表，并用
session id 做缓存，因此切换后标题立即更新。

若 Agent 主动推送 `session_info_update`，该路径同样生效，两边不冲突。
历史先重放到暂存对象，成功后提交；失败保留旧会话与队列，不会先清空界面。
同一时间只执行一次历史重放。选择仍在运行的缓存会话时直接查看，不重复加载它的历史；
较早的加载结果也不会抢走后来新建/选择会话的焦点。

### 会话浏览器

`:Acp sessions` 默认使用 **snacks.nvim 的 picker**：自带 fuzzy 搜索、实时预览，
并沿用你已有的 snacks 主题。未安装 snacks 时自动回退到内置窗口，不会报错。

| 按键 | 说明 |
|---|---|
| `<CR>` | 切换到选中会话 |
| `<C-d>` | 删除选中会话（二次确认） |
| 输入 | fuzzy 过滤（fzf 语法） |
| `<Esc>` / `q` | 关闭 |

列表右侧显示更新时间，当前会话行首有箭头标记；右侧预览区显示完整会话 ID、
目录与创建/更新时间。删除后列表原地刷新，可连续删除。

想强制使用内置窗口：

```lua
require("acp").setup({ ui = { session_picker = "internal" } })
```

内置窗口（回退时）支持 `j`/`k` 移动与 `<BS>`/`<C-u>` 编辑过滤。
`q` 关闭、`gg`/`G` 跳转；这些按键对应的字母可用大写 `Q`/`J`/`K` 输入过滤，
`g` 用于过滤（`gg` 仍可跳到首项）。

- 删除非当前会话：当前对话不受影响。
- 删除当前会话：确认后自动新建一个会话。
- Agent 未声明 `sessionCapabilities.delete` 时给出提示，不弹出无法兑现的确认框。

### 窗口保护

ACP 的两个窗口默认锁定到自己的 buffer（`winfixbuf`），因此 `:edit`、`:bnext`、
插件里的「在当前窗口打开」等操作都不会把对话记录或输入框替换成别的文件。

- 关闭窗口、`:q`、隐藏面板都仍然正常。
- 从面板 `:split` / `:vsplit` 会得到一个可用的普通窗口，而不是被锁死的副本。
- 需要临时解除（例如配合某些窗口管理插件）时：

```lua
require("acp").setup({ layout = { lock_buffer = false } })
```

> `winfixbuf` 需要 Neovim 0.10+。更早的版本上插件会跳过锁定并记录一条 debug 日志。

### 消息排队

同一会话同时只运行一个 prompt。生成中提交的消息会本地排队，
当前回合结束后依次发送，工具栏显示 `+N queued`。
队列默认最多 16 条、估算载荷 4 MiB；超过限制时拒绝入队并保留输入草稿。
队列属于会话运行时，不属于当前窗口：切换到 B 不会停止 A 的队列，也不会把 A 的错误
显示到 B。历史替换复用同一个 outbox，待发送消息不会被重放覆盖。

再次 `setup()` 会建立新的运行环境并取消旧任务。存在待发送消息时默认拒绝重新配置，
避免静默丢弃；先等待队列清空，或者**明确同意丢弃后**调用：

```lua
require("acp").setup({ layout = { backend = "native" } }, { discard_queued = true })
```

队列目前只保存在本次 Neovim 进程内，不是持久化 outbox；正常退出或崩溃不会恢复它。

### 中断与恢复

Agent 崩溃或退出时，正在运行的工具会被标记为失败，并提示 `:Acp reconnect`。
重连会调用 `session/load` 重放 Agent 侧历史，不会自动重发上一条 prompt。
断连会暂停各会话队列、取消旧请求并使旧选择器失效。当前会话恢复成功后继续发送尚未开始
的排队消息；其他会话在选中并恢复后继续。已发出的 prompt 不自动重试，避免重复执行工具。
任务的单次结算保证不等于 Agent 操作的 exactly-once 执行保证。

### 草稿持久化

未发送的输入和附件按「项目 + 会话」保存在
`stdpath("state")/acp/drafts.json`，重启后自动恢复。空草稿会被清除，
最多保留 50 条。
内存中的历史草稿默认最多 20 条（`memory.max_drafts`），当前输入框不受淘汰影响。
磁盘读写有缓存与 150ms 合并窗口，普通保存异步写入，退出时执行最终 flush；
崩溃可能丢失尚未完成持久化的最近修改。
保存始终使用输入框原本的项目/会话身份，不依赖保存时哪个会话可见；消息接受后清理对应
草稿，即使发送过程切换了会话，也不会清空新会话的输入框。仅附件的草稿同样会保留。

### 长会话与性能边界

- 控制器维护 block 变更版本与有限变更日志，渲染只重建变化块及行坐标受影响的后缀；
  稳定前缀保留文本、元数据与 extmark。窗口宽度变化、换主题或变更日志落后时走完整路径。
  当前变化消息仍会物化完整文本；含代码的消息仍重新排版，但会复用语法分析结果，并非逐字符零复制。
- 代码语法缓存与布局宽度分离，已闭合代码不会因后续文字追加而重新解析；缓存最多
  64 项、约 2 MiB。单代码块超过 256 KiB 时降级为纯文本，语法捕获最多 20,000 项。
- 每会话仍保留最多约 2,000 个 block，同时应用字节预算。超大 block 会显示截断标记，
  会话超预算会批量移除最旧记录；这些限制不修改 Agent 侧历史，重新加载仍受本地预算限制。
- 非活动、空闲会话按 LRU 淘汰；当前会话、运行中、有待发送消息或权限请求的会话不会
  被淘汰。因此受保护会话可暂时超过缓存数量/总载荷预算，预算也不包括 Lua 对象、渲染缓存与 Neovim buffer 的全部开销。
- 协议消息按时间预算有序分批处理，超出待分发队列预算时断开连接；单条 JSON 解码或单块排版仍不可抢占。
  普通通知在该批次内直接归约，不再逐条投递第二个无预算队列；权限 UI 单独调度。
- 独立使用 session/view 的代码可保留兼容渲染路径。启用 `session:track_changes()` 后，
  直接修改 block 必须调用 `session:touch(block)`；仅状态/折叠变化可用 `touch(block, false)`。

### 切换模型与模式

有三种方式，任选其一：

1. **直接点击** winbar 上的模型名或模式徽标（不显示下拉箭头）。工具栏只显示模型名，
   例如 `DeepSeek V4.1 Flash` 而不是 `commandcode/DeepSeek V4.1 Flash`；
   选择器里仍保留完整名称，便于区分不同 provider 的同名模型。

   > 鼠标须在当前模式启用。默认 `mouse = "nvi"` 已覆盖普通、可视、插入模式，
   > 不需要改为 `a`；`mouse = ""` 会关闭鼠标支持。终端也须正确转发鼠标事件。
2. 输入时按 `<M-m>` 切换模型、`<M-b>` 切换模式。
3. 普通模式按 `M` / `m`，或执行 `:Acp model` / `:Acp mode`。

普通选择器（模型、模式、权限确认）默认走 **`vim.ui.select`**，因此
telescope、fzf-lua、snacks.nvim、dressing 等插件会自动接管，无需额外配置。
选中后立即生效，工具栏同步更新。会话浏览器独立使用 `ui.session_picker`。

想用插件自带的浮动选择器（带模糊过滤，适合上百个模型的场景）：

```lua
require("acp").setup({ ui = { picker = "internal" } })
```

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

# 重连与性能回归
nvim --headless -u tests/minimal_init.lua -l tests/integration_reconnect.lua
nvim --headless -u tests/minimal_init.lua -l tests/perf.lua

# 布局预览
nvim --headless -u tests/minimal_init.lua -l tests/render_preview.lua

# 真实 OpenCode 冒烟测试（需要已登录）
nvim --headless -u tests/minimal_init.lua -l tests/manual_opencode.lua
```

`:checkhealth acp` 会检查 Neovim 版本、Agent 可执行文件、edgy 与日志路径。

可运行配置位于 `examples/minimal/init.lua` 和 `examples/edgy/init.lua`。
后者需要事先把 edgy.nvim 加入 runtimepath；这些示例不会自动安装依赖。
当前代码检查记录与验证边界见 [docs/status.md](docs/status.md)。
运行时所有权、任务生命周期与模块边界见 [docs/architecture.md](docs/architecture.md)。

## 许可证

MIT
