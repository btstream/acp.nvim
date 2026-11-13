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
- 一个已登录的 ACP Agent。默认是 OpenCode；首次使用可以打开 `:Acp` 后运行 `:Acp login`，
  插件会执行 Agent 自己提供的登录方式：

```bash
opencode auth login      # 也可以在终端里手动完成
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

### 工作指示器

输入区的 spinner 默认每 120ms 更新，使用 libuv timer 并合并 UI 回调；焦点在其他窗口时
也会明确刷新 ACP winbar。隐藏面板或切到其他标签页时停止，返回后恢复。已停止/关闭的
timer 会在下一次状态、窗口或焦点同步时重建，不需要重启插件。

卡住时查看 `:AcpDebug` 的 `spinner`：

- `state` / `timer_active`：区分正常动画、隐藏、关闭动画和失效 timer。
- `ticks` / `frame_changes`：帧推进情况；`max_tick_gap_ms` 是历史最大 tick 间隔，
  应与 `interval_ms` 比较，而不是当作纯阻塞耗时。
- `max_schedule_delay_ms` / `max_refresh_delay_ms`：UI 队列等待时间。
- `bar_evaluations` / `last_evaluated_frame`：winbar 表达式是否在更新，不代表物理屏幕已经绘制。
- `redraw_backend`、错误计数、`active_errors` / `last_error`：重绘方式及当前/历史错误。

重复错误只在每个错误阶段首次发生时记日志。`last_bar_status=waiting` 是等待权限，
`state=static` 是关闭了动画，都不是 spinner 卡死。libuv 同样无法在主循环阻塞时绘制：
JSON 解码、单块排版或 Treesitter 解析很重时仍可能暂停，恢复后会跳过错过的帧。
可结合 `render.timings`（需 `ui.render.profile=true`）和 transport 统计定位重型任务。

带 UI 的回归：`python3 tests/integration_spinner.py`（额外需要测试依赖 `pynvim`，插件本身不需要）。

### 输入区

进入 `acp_input` 窗口或缓冲区时自动切换到插入模式，离开时退出插入模式，避免把输入
状态带到转录区或编辑窗口。按 `<Esc>` 可暂时在输入区使用普通模式；再次进入时恢复插入。

下表的按键都是默认值，全部可以通过 `keymaps.input` 修改。

| 按键 | 配置字段 | 说明 |
|---|---|---|
| `<C-s>` | `send` | 发送；回合进行中且输入框为空时改为中止 |
| `<C-c>`（普通模式） | `cancel` | 中止当前回合 |
| `q`（普通模式） | `close_panel` | 隐藏面板（不中断会话） |
| `<C-]>`（普通模式） | `add_selection` | 附加当前选区 |
| `M` / `<M-m>` | `pick_model` | 普通模式 / 输入时选择模型 |
| `m` / `<M-b>` | `pick_mode` | 普通模式 / 输入时选择模式 |
| `L`（普通模式） | `pick_session` | 历史会话 |
| `<C-x><C-u>` | — | 补全 `/命令` 或 `@文件`（Vim 内置触发，不受 `keymaps` 控制） |
| `<leader>ai`（任意 buffer） | `keymaps.inline` | 在光标/选区上开始内联编辑 |
| `@path/to/file` | — | 发送时自动作为附件 |
| 点击 winbar 的模型 / 模式 | — | 打开选择器（鼠标区域，不是键位） |

### 转录区

同样，全部可以通过 `keymaps.chat` 修改。

| 按键 | 配置字段 | 说明 |
|---|---|---|
| `i` / `<C-s>` | `focus_input` | 聚焦输入框 |
| `<CR>` | `open_location` | 打开光标所在位置的文件 |
| `<Tab>` | `toggle_block` | 展开 / 折叠工具调用或思考块；不可折叠时聚焦输入框 |
| `[b` / `]b` | `prev_block` / `next_block` | 上一个 / 下一个消息块 |
| `G` / `gg` | `scroll_bottom` / `scroll_top` | 最新 / 最早 |
| `S` | `add_selection` | 附加当前选区 |
| `F` | `add_file` | 附加当前文件 |
| `R` | `add_diagnostics` | 附加诊断 |
| `M` / `m` | `pick_model` / `pick_mode` | 选择模型 / 模式 |
| `<C-n>` | `new_session` | 新建会话 |
| `L` | `pick_session` | 历史会话 |
| `g?` | `help` | 帮助（列表按当前配置生成） |
| `q` | `close_panel` | 隐藏面板 |

转录区只读：从输入框或其他窗口直接切入时也会退出插入模式。默认 `i` / `<C-s>`
切到输入框，`S` / `R` 仍执行附加选区 / 诊断；未绑定业务动作的插入入口（如 `a`、
`o`、`A`）静默忽略。关闭 `focus_input` 后，`i` 也静默忽略。`keymaps.chat` 配置的
业务映射优先于这些兜底映射。

所有按键都是 buffer-local，不会污染全局映射。

### 输入区补全：blink.cmp / nvim-cmp / 原生菜单

`/` 补全当前 Agent 提供的命令名称和说明，`@` 模糊查找项目文件。只在 `acp_input`
生效，不补全聊天转录、不调用命令、不自动发送消息。两个框架**二选一**，均为可选依赖。

**blink.cmp**：将下面配置合并进已有 `setup` / lazy.nvim `opts`，不要再次调用 setup：

```lua
sources = {
  per_filetype = { acp_input = { "acp" } },
  providers = {
    acp = { name = "ACP", module = "acp.completion.blink" },
  },
}
```

参见 [`examples/completion_blink.lua`](examples/completion_blink.lua)。接受候选使用现有 blink
按键；若自定义 `enabled` 排除了 `nofile` buffer，请为 `acp_input` 放行。

**nvim-cmp**：在 nvim-cmp 和 acp.nvim 都能被 require 后注册 source，配置仅作用于输入区：

```lua
local cmp = require("cmp")
require("acp.completion.cmp").setup() -- 幂等注册名为 acp 的 source
cmp.setup.filetype("acp_input", {
  enabled = true,
  sources = { { name = "acp", keyword_length = 0 } },
  matching = { disallow_symbol_nonprefix_matching = false },
})
```

完整 lazy.nvim 示例及 Enter 确认映射见 [`examples/completion_cmp.lua`](examples/completion_cmp.lua)。
本插件不修改两个框架的全局 sources 或按键。建议保持 `<C-s>` 发送、使用补全框架按键确认；
若把发送也绑定到 `<CR>`，需要自行做“菜单有选中项时确认，否则发送”的条件映射，避免误发送。

**不安装框架**：仍可用 `<C-x><C-u>`，文件索引异步完成后显示原生菜单。支持例如：

```text
@lua/acp/ui/chat.lua
@Makefile
@"docs/中文 file.txt"
```

补全和发送共用引用语法；带空格、引号、反斜杠等字符的路径会自动使用 JSON 字符串引用。
邮箱中的 `@` 不触发文件补全。提交时才检查和附加可读文件，补全过程不会读取所有文件正文。

#### 项目文件发现与缓存

默认从当前**会话目录**寻找 Git 根目录；非 Git 项目使用会话目录。自动选择 `rg --files`、
`fd` / `fdfind`、`git ls-files`，均异步执行并覆盖递归文件；不仅搜索已打开的 buffer。
最后回退到异步目录遍历，无外部工具也能使用。内置遍历不解析 ignore 文件，建议安装 rg / fd。

```lua
require("acp").setup({
  completion = {
    native = true,      -- 保留原生触发；不会自动与框架同时弹两个菜单
    max_items = 200,    -- 只限制原生菜单，先在完整索引中匹配再截取
    picker = "vim",    -- "vim" | "fzf-lua" | "snacks" | "telescope"
    files = {
      backend = "auto", -- 或 "rg" | "fd" | "git" | "builtin"
      root = false,    -- 或绝对路径 / function(session_cwd) return root end
      hidden = true,
      ignored = false,
      cache_ms = 10000,
      max_bytes = 16 * 1024 * 1024,
      max_projects = 4,
      command = false, -- 自定义 argv，cwd=root，输出 NUL 分隔的相对路径
    },
  },
  keymaps = { input = { pick_file = "<M-f>" } }, -- 可选，默认不占用按键
})
```

框架获得完整索引并自行模糊排序，不会先截断前 200 个文件。`max_bytes` 是索引路径和条目
开销的估算预算，不是总 RSS 上限；超限会明确报错而非提供不完整索引，可在 `:AcpLog` 查看原因。
隐藏和忽略规则遵循所选工具；`.git` 元数据固定排除。`ignored=true` 可能纳入敏感的被忽略文件，
请谨慎启用。缓存按项目/选项复用，过期重建；`:AcpCompletionRefresh` 清理缓存，下一次请求重新扫描。
会话在仓库子目录时，插入路径相对会话目录，必要时使用 `../`，确保发送时能解析到同一文件。

#### 使用 fzf / 其它文件选择器

打开输入区后，`:Acp files` 或 `require("acp").pick_file()` 使用上述 `completion.picker`
选择器；也可单次指定：

```lua
require("acp").pick_file({ backend = "fzf-lua" })
```

fzf-lua、Telescope 和 Snacks 都复用同一个完整项目索引；`"vim"` 使用 `vim.ui.select`，
也支持已有的 dressing / UI 接管。选择结果插入 `@路径`，**不打开文件、不发送消息**。
与原有 `:Acp file`（附加当前文件）不同。原始 fzf 二进制不是补全菜单的强依赖，
fzf-lua 只是可选的交互式搜索入口，不会在每次按键时重新扫描项目或弹出终端。

### 图像附件

输入区可以附加图像，以 ACP `image` 内容块发送。这需要 Agent 声明
`promptCapabilities.image`（OpenCode 支持）；未声明时附加内嵌图像会被明确拒绝，
而不是等发送后才由 Agent 报错。

```lua
require("acp").setup({
  context = {
    images = {
      enabled = true,
      max_bytes = 3 * 1024 * 1024, -- 单张上限
      max_per_message = 4,
      clipboard = "auto",  -- 或 false，或自定义 argv
      path_mode = "link",  -- @shot.png 默认按 resource_link
      ttl_hours = 24,
      max_cache_bytes = 64 * 1024 * 1024,
    },
  },
})
```

三种用法：

| 方式 | 说明 |
|---|---|
| `:Acp image` | 读取系统剪贴板中的截图并附加 |
| `:Acp image path/to.png` | 附加指定文件 |
| 直接粘贴 / 拖拽图像文件路径 | 只对输入区生效，识别 `file://`、引号和转义路径 |

`require("acp").paste_image()`、`require("acp").add_image(path)` 是对应 API。
`paste_image` 默认绑定 `<C-v>`（普通模式和插入模式），与 OpenCode TUI、pi 的习惯一致。
这会覆盖输入区的 `i_CTRL-V`（字面量插入）和普通模式 `CTRL-V`（块选择）；只在
`acp_input` 内生效，不影响其它 buffer。需要改用其它键时：

```lua
keymaps = { input = { paste_image = "<M-v>" } },
```

附加图像会在 **`acp_input` 的粘贴光标处**显示浅黄色底、深色粗体的行内标签 `[Image 1]`，
多张图片使用独立编号，不再放到 winbar。可通过 `ui.highlights.AcpInputImage` 覆盖样式。
标签是可编辑占位符，不是图片预览：粘贴后光标位于标签之后，可正常移动到两侧。
标签后按退格、标签前按 Delete 可整块删除图片附件；支持撤销/重做。
发送时只移除受跟踪的图片占位符，不会移除用户自己输入的同名文字；图片仍单独作为附件发送。
文字和图片按输入区的实际位置交错发送为 ACP 内容块，聊天记录也在原位置显示对应编号，
不会把图片统一挪到消息头或末尾。排队时会冻结位置，后续草稿编辑不会改变已排队消息。
剪贴板读取是异步的，位置会跟随读取期间的文本编辑；若用户清空或切换草稿，旧结果会丢弃。
用户离开窗口或主动退出插入模式后，回调不会抢回焦点或重新进入插入模式。

**为什么不用终端的粘贴快捷键**：终端只在 bracketed paste 中传文本，截图不会传给
Neovim；OSC 5522 需要终端专用协商并改变普通粘贴处理，本插件暂不接入。
目前剪贴板图像由本插件主动读取
（`wl-paste` / `xclip` / `pngpaste` / `powershell.exe`），
与 OpenCode TUI、pi 等终端客户端的做法一致。

图像数据只在发送时编码：草稿、本地队列和会话块里只有路径、大小和摘要，避免 base64
在三个地方各放大 33%。字节按 sha256 存在 `stdpath("state")/acp/images`（目录 0700、
文件 0600，按 `ttl_hours` 与 `max_cache_bytes` 回收）。`max_bytes` 会与
`transport.max_line_bytes` 交叉校验，配置阶段就拒绝无法装进一条消息的上限。
清理时保护草稿（含持久化）、内存队列与会话块仍引用的图片；活跃引用可能使缓存超过预算。
`path_mode = "inline"` 时 `@shot.png` 会内嵌字节；默认 `link` 只发送引用，避免每次提及
都把整张图重新编码。协议日志会把 base64 载荷替换为 `<base64 N bytes>`。

### 内联编辑

`require("acp").inline()`（默认 `<leader>ai`，普通和 Visual 模式）在光标处或选区上方
打开输入框，让 Agent 修改当前 buffer。字符/行选区默认按整行处理，块选区保留列范围；
`inline.expand_selection = false` 保留字符选区的精确范围。无选区（普通模式）时不会把请求
限制成“只能在光标处插入”：Agent 按用户请求修改副本，光标位置只作为提示。
`inline.scope = "context"` 时改为只允许修改光标周围的上下文窗口。

通过当前 session 提交正常 prompt 回合，回复保留在聊天记录中，不创建新 session。
当前回合或队列未完成时拒绝 inline 提交；inline 运行时，普通聊天仍可排队。
要求 Agent 编辑同目录下的私有副本（`.acp-inline-*`）：

- 读/搜索/思考/取回默认放行；编辑权限仅授权本次登记的副本，其它写入或命令默认拒绝。
- 结果按选区范围过滤，精确字符/块选区不扩大为整行；越界改动提示丢弃数量。
- 等待或审查期间源内容、文件名或换行约定变化时，拒绝应用冲突结果。
- 副本权限为 0600，默认大小上限 `inline.max_copy_bytes = 8 * 1024 * 1024`；
  请求结算后删除，正常退出清理；下次使用时尝试清理超过一天且所属进程已退出的孤儿。
  目录不可写时退回 `stdpath("state")`。

这些是 ACP 权限请求约束，不是操作系统沙箱；无法阻止绕过权限协议的 Agent 直接修改文件。

审查方式可配置，默认逐块审查：

```lua
inline = {
  review = {
    mode = "diff", -- "diff" 逐块确认；"write" 直接写回（仍可一次撤销）
    by_filetype = {
      markdown = "write",
      text = "write",
      ["*"] = "diff",
    },
  },
},
keymaps = { inline = { normal = "<leader>ai", visual = "<leader>ai" } },
```

diff 默认在新 tabpage 里打开并排的真实窗口：
`3-column` 为「原文 │ 结果 │ 提案」，`2-column` 去掉只读的原文，只留「结果 │ 提案」。
各栏**不使用** Vim 的 diff 模式（它会把同一 tab 里所有 diff 窗口互相比较，无法表达
「原文↔结果」「结果↔提案」两组对比）：插件按同一份对齐表给每栏插入 filler 行，三栏行数
完全相同，`scrollbind`/`cursorbind`/折叠由 Neovim 原生同步，语法高亮按文件自身语言启动。
结果列初始等于原文；源 buffer 在审查期间不变，全部决定后一次应用接受的块。
宽度不足 `min_split_width`，或 `target = "float"` 时，回退为复用工具卡片渲染的
card 视图（同样的 diff 背景与语法高亮）。

- 光标停在某个变更块上，`ga`/`gr` 接受/拒绝该块；Visual 选区可一次处理被覆盖的所有块。
  三栏的显示行一一对应，所以在**任意一栏**都可以选择和决定。
- `]c` / `[c`（或 `]h` / `[h`）按审查顺序循环跳到下一个/上一个块，已决定的块仍可访问；
  光标留在当前栏。`u` 把当前块的决定清回 pending。
- `g2` / `g3` 全部接受 / 全部拒绝，`g1` 全部接受并永久改用直接写回，
  `q` / `<Esc>` 拒绝剩余部分并关闭；`:Acp inline-reset` 清除 always-accept。
- 结果列只用于展示决定结果，是 `nomodifiable`；手动编辑会被下一次决定覆盖，因此被禁止。
- 审查不修改 `diffopt`，也不开启任何窗口的 `diff`。
- 按结果到达时的 filetype 解析：精确 filetype、复合 filetype 的第一段、`"*"`、默认值。

`:Acp inline [diff|write]`、`:Acp inline-stop`、`:Acp inline-reset` 是对应命令。
命令支持行范围（如 `:'<,'>Acp inline diff`）。显式 `diff|write` 优先于 always-accept
和 filetype 配置；`<C-d>` 切换本次模式。同一时间只运行一个 inline 请求。

浮窗外观可配置；颜色仍由 highlight group 决定：

```lua
inline = {
  window = {
    border = "rounded",     -- none/single/double/rounded/solid/shadow，或 8 个字符
    title_pos = "left",     -- left | center | right
    style = "minimal",      -- minimal | default
    highlights = {          -- 只映射窗口 chrome，可用 ui.highlights 改颜色
      normal = "AcpInlinePrompt",
      border = "AcpInlineBorder",
      title = "AcpInlineTitle",
    },
    prompt = {
      placement = "cursor", -- cursor（跟随光标）| window（窗口左上）
      width = 72,
      height = 3,
      offset = { row = 0, col = 0 },
      follow_cursor = true,
    },
    review = {
      placement = "center",      -- center | cursor（仅 target = "float" 时生效）
      width = 140,
      height = 25,
      target = "buffer",         -- buffer（新 tab 真实窗口）| float（浮窗）
      layout = "3-column",       -- 3-column | 2-column
      min_split_width = 90,      -- 更窄时回退 card 渲染
      context = 3,               -- 上下文行数：card 回退保留的行，分栏中不折叠的行
      syntax = true,             -- card 回退使用文件自身语法
      advance = false,           -- 决定后跳到下一个 pending 块
      max_rows = 4000,           -- card 回退的行数上限
      fold = true,               -- 折叠离变更超过 context 行的未修改行
      sync_scroll = true,        -- scrollbind/cursorbind
      relative_number = false,   -- 相对行号（按真实行计算，跳过 filler）
      hints = true,              -- 在当前块后显示 ga/gr 提示
      foldcolumn = 1,            -- 折叠列宽度，0 隐藏
    },
  },
},
```

`placement = "cursor"` 优先放在光标下方，空间不足时翻到上方，水平位置跟随光标列，
并始终夹在屏幕内；`follow_cursor = false` 可让输入框停在打开时的位置。

审查界面的外观（与常见的三栏 merge 视图一致）：

- 三栏共用同一份对齐：块内的行用 `linematch` 按相似度配对，块里没有任何相似行
  （整段改写、翻译）时改为从上到下配对。有对应的行是 `modify`，两侧都有内容；只在原文中
  存在的是 `delete`，只在提案中存在的是 `add`，对面一定是 `╱` filler。着色与对齐来自
  同一份数据，不会出现 modify 行对着 filler 的情况。
- 每一栏只显示**它自己这一侧**相对结果的变化：

  | 栏 | pending | 已接受 | 已拒绝 |
  |---|---|---|---|
  | 原文 | `AcpReviewDelete` + 字符级 `AcpReviewDeleteText` | `AcpReviewDimmed`（被替换） | 无底色（保留） |
  | 结果 | `AcpReviewPending` | `AcpReviewAdd` + 字符级 `AcpReviewAddText` | 无底色 |
  | 提案 | `AcpReviewAdd` + 字符级 `AcpReviewAddText` | `AcpReviewAdd`（已采用） | `AcpReviewDimmed`（被丢弃） |

- 字符级标记只用于相似的行对；一行里超过一半都变了（改写、翻译）时只用整行底色，避免满行碎片。
- 行号列由 `statuscolumn` 绘制：最左一格是块的状态条（`▎`，已接受/已拒绝块的首行为 `✓`/`✗`），
  颜色为 `AcpReviewStatePending/Current/Accepted/Rejected`，三栏同一行同色；后面是**真实行号**
  （原文/提案保留各自文件的行号，结果列按当前结果计数），filler 行没有行号。
- 光标所在块在结果列行尾显示 `ga accept · gr reject · ]c next`（`AcpReviewHint`，`hints = false` 关闭）。
- `winbar` 每栏一个彩色徽章（`A` 原文 / `→` 结果 / `B` 提案），只有结果列显示
  `hunk i/n · ✓/✗/pending` 计数。
- 光标行使用 `AcpReviewCursorLine`（复制主题 `CursorLine` 的底色、去掉下划线），
  避免 `cursorbind` 把下划线画到三栏。
- filler 用 `AcpReviewFiller`：固定的低对比灰 `fg`，不跟随主题。
- 所有组都是**静态定义**：运行期不做混色。`AcpReviewAdd/Delete/Pending` 的底色复制自主题的
  `DiffAdd/DiffDelete/DiffChange`，字符级标记复制自 `DiffText`（只复制 `bg`，不带主题的前景与下划线；
  `ColorScheme` 时重新复制）。主题的颜色区分度不够时，用 `ui.highlights` 覆盖。
- card 回退沿用 `AcpDiffAdd/AcpDiffDelete`，状态用 `AcpInlineAccepted/Rejected`。

审查配色示例（放入 `setup()`，颜色按你的主题调整）：

```lua
ui = {
  highlights = {
    AcpReviewAdd = { bg = "#243c2c" },        -- 新增 / 提案侧
    AcpReviewDelete = { bg = "#44292e" },     -- 删除 / 原文侧
    AcpReviewPending = { bg = "#26384a" },    -- 结果列中未决定的块
    AcpReviewAddText = { bg = "#2f5a3a" },    -- 提案侧变化的字符
    AcpReviewDeleteText = { bg = "#6a3038" }, -- 原文侧变化的字符
    AcpReviewFiller = { fg = "#4b5260" },
  },
}
```

也可在 `setup()` 之后用 `vim.api.nvim_set_hl(0, "AcpReviewPending", { bg = "#26384a" })`
即时调整；希望切换主题后仍保留配置时，推荐使用上面的 `ui.highlights`。
card 里的 diff 使用 `AcpDiffAdd/AcpDiffDelete`。

审查窗口的行为约束：

- 窗格选项只写窗口局部值，打开后会立刻把选项的“新窗口继承值”还给用户；审查期间
  新开的补全、通知等浮窗不会继承审查的 `statuscolumn`、折叠、`winhighlight` 等选项。
- 若外部仍换掉了窗格 buffer（例如手动关掉 `winfixbuf` 后 `:edit`），重新进入时会把
  审查 buffer 放回并恢复选项。
- 三个窗口都设置 `winfixbuf`，`:edit`、`:enew`、`:bnext` 和插件“在此打开”都会被拒绝
  （`E1513`），因此结果列不会变成真实文件的 buffer。关闭窗口仍然允许。
- 每栏按文件语言显式 `vim.treesitter.start()`，包括 `lua`/`markdown` 之外 Neovim 没有自带
  ftplugin 的语言（Python、JavaScript、TypeScript、Go 等）；没有对应 parser 时静默回退到
  legacy `syntax`，无 parser 也没 syntax 时就是纯文本。

### 可选的懒渲染与历史分页

默认仍使用全文渲染。建议先开启 A，确认效果后再开启 B：

```lua
ui = {
  render = {
    lazy_syntax = true, -- A：仅在视口附近解析/绘制代码、diff 语法颜色
    profile = false,   -- true 时在 :AcpDebug 的 render.timings 查看分层耗时
    budget_ms = 4,     -- 共享调度器的主循环软预算；同步操作不可抢占
    overscan = 1,      -- 可见区上下各预加载一屏
    commit_rows = 2000, -- 超过此行数时提交也分片；0 关闭
    pagination = {
      enabled = false, -- B：需要时显式开启，默认不改变原生搜索/复制语义
      page_blocks = 64,
      max_blocks = 192,
      page_bytes = 256 * 1024,
    },
  },
}
```

- **A** 保留完整 buffer 文本、基础高亮、conceal、卡片背景和跳转信息，只延迟语法装饰。
  原生搜索和复制不变；文本仍走已有增量排版路径，不因懒高亮重建稳定历史。
- **B** 首先显示最近一页，之后的新消息始终自动追加，无论你正在看哪里；只有更早的历史
  按需加载，接近顶部时自动预取。顶部保留“更早消息”提示，可按键加载。
  `gg` 加载最早保留内容，`G` 回到最新并跟随，`[b` / `]b` 可跨页。
- 分页只改变显示范围，不修改 Session/Agent 历史。原生 `/` 和 Visual 复制只覆盖当前
  已加载文本，不提供跨未加载历史的原生搜索。`Chat:transcript()` 的显式完整导出仍包含
  Session 保留的全文，但该操作会临时全量排版。
- 接收尾部、分页排版、语法装饰和大型提交使用共享工作调度器。stdout 解析超出接收预算时，
  未处理的尾部保序排队，并计入积压限制；溢出时明确断连。分页排版中的表格和 Markdown 在结构行边界让出；
  超过 `commit_rows` 的首次布局/翻页提交按行分片写入。单个 JSON 解码、单次 Treesitter
  解析、diff 计算、非分页排版、单条超大消息分帧仍不可抢占。接收首次回调与消息派发仍使用独立接收预算。
- Visual/Select 选区活动时暂停分页排版与回收，退出后刷新。当前可见块不会因分页而被
  回收，因此受保护范围可能暂时超过预算；单个大块也不会被强行拆开。
- `page_bytes` 是每次新增页面的源载荷目标，不是 RSS 上限。为同时保留阅读位置与最新输出，
  往回加载时窗口可以超过 `max_blocks`；返回底部再收缩。A 不减少全文行缓存，B 减少初始物化范围。

运行 `nvim --headless -u tests/minimal_init.lua -l tests/perf_lazy.lua` 可比较全文、A、B 的
首个布局提交耗时、语法解析、extmark 数量和 Lua 内存。具体耗时取决于内容和本机环境。
`tests/integration_lazy.lua [native|edgy|reconnect]` 用相同方式运行开启 A+B 的集成检查。

工具调用卡片折叠时只显示标题和一行预览。展开后，`execute`（shell）调用会在输出
之前以 `$ 命令` 的形式给出完整命令行——优先取 agent 的 `rawInput.command`，没有
结构化输入时退回标题；标题栏为了适配面板宽度仍会截断长命令，卡片里的是完整文本。
命令与输出之间留一个空行，多行命令（heredoc 等）逐行显示。

文件修改的卡片标题会区分 **Edit** 与 **Write**：ACP 本身没有 `write` kind，创建/
覆盖文件也报成 `edit`，所以插件按工具输入判断——带旧内容（`oldString` / `oldText`
/ `patchText`）的是 Edit，只有新内容（`content` 等）的是 Write；输入还没到时就退回
标题里的 `write` / `create`。

`edit` / `write` / `patch` 的卡片展开后直接在卡片里画出 diff：删除行用主题的
`DiffDelete` 背景、新增行用 `DiffAdd`，`+` / `-` 号单独配色，上下文行沿用卡片底色。
只有一个 hunk 时不显示 `@@` 头，多个 hunk 才用它分隔；一次涉及多个文件时，文件之间
画一条分隔线。行数超过 `ui.diff.max_lines`
或体积超过 `ui.diff.max_bytes` 时以一行提示收尾，不会把整个文件倒进 buffer。

diff 行还会按**被编辑文件自己的文件类型**着色：`.lua` 用 Lua 语法、`.py` 用 Python
语法，颜色取自 treesitter 的 `@capture` 组，所以和你在普通 buffer 里看到的一致。
红绿背景与语法前景同时生效。实现上只把「要显示的那几行」拼成片段解析，成本与文件
大小无关（30 行约 0.6 ms，800 行约 13 ms），结果按内容缓存，流式刷新命中缓存几乎零
成本。文件类型未安装 parser、扩展名未知或行数超过 `ui.diff.max_syntax_rows` 时
静默退化为纯文本，diff 本身不受影响。设 `ui.diff.syntax = false` 可整体关闭。

这些卡片**默认展开**，因为改动本身就是要看的内容；agent 还在执行时就能看到
`rawInput` 里的变更，完成后替换成权威的 diff。

- 用户按 `<Tab>` 手动折叠后，后续更新不会再把它弹开；
- 从历史会话加载（`:Acp sessions`）或重连恢复的卡片默认折叠，避免一次展开几十个
  diff；回放提交后，再新产生的 diff 恢复默认展开，历史卡片保持折叠；
- 同进程内切回仍在运行的缓存会话时，展开状态原样保留；
- `write` 拿不到旧文件内容，因此按“全新增”展示并标注 `(new content)`。

配置示例：

```lua
require("acp").setup({
  keymaps = {
    input = {
      send = "<C-CR>",                       -- 单个键
      pick_model = { n = "M", i = "<M-m>" }, -- 按模式分别指定
    },
    chat = {
      focus_input = { "i", "<C-s>" },        -- 多个键
      toggle_block = "<C-t>",
      scroll_top = false,                    -- 关闭该绑定
    },
  },
})
```

每个字段接受四种写法：单个键、键的列表、`{ n = ..., i = ... }` 模式表、`false`
（关闭）。配置里只会绑定该动作实际声明的模式，例如转录区没有输入模式，写成
`pick_model = { n = "T", i = "<M-t>" }` 时 `i` 那一项会被忽略。两个动作在同一模式
抢同一个键会在 `setup()` 时报错（`<Tab>` 与 `<C-i>`、`<CR>` 与 `<C-m>` 视为同一个键），
而不是让后一个悄悄生效。

按键必须写在其所属视图下。`keymaps.send` 这类扁平写法会直接报错，并在报错里指出
应该写成 `keymaps.input.send`——静默忽略一个写错位置的按键最难排查。

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
      default_expanded = false,      -- 已完成的思考默认展开
      show_collapsed_header = true,  -- 折叠时显示头部
      expand_while_streaming = true, -- 思考进行中实时展开
      collapse_on_finish = true,     -- 思考结束后自动折叠
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
    diff = {
      context = 3,                    -- 每个 hunk 保留的上下文行数
      max_lines = 800,                -- 超过后折叠成一行提示
      max_bytes = 512 * 1024,         -- 超过后不计算 diff
      syntax = true,                  -- 用被编辑文件的语法着色 diff
      max_syntax_rows = 800,          -- 超过后跳过着色（保持纯文本）
    },
  },

  keymaps = {
    input = {
      send = "<C-s>",
      cancel = "<C-c>",
      close_panel = "q",
      add_selection = "<C-]>",
      pick_model = { n = "M", i = "<M-m>" },
      pick_mode = { n = "m", i = "<M-b>" },
      pick_session = "L",
    },
    chat = {
      close_panel = "q",
      focus_input = { "i", "<C-s>" },
      toggle_block = "<Tab>",
      prev_block = "[b",
      next_block = "]b",
      open_location = "<CR>",
      help = "g?",
      add_selection = "S",
      add_file = "F",
      add_diagnostics = "R",
      pick_model = "M",
      pick_mode = "m",
      new_session = "<C-n>",
      pick_session = "L",
      scroll_bottom = "G",
      scroll_top = "gg",
    },
  },

  permissions = {
    prompt = "select",
    -- 谨慎使用：自动放行的 option kind
    auto_allow = {},
    -- 权限窗口旁的只读详情（命令、diff、rawInput）
    show_details = true,
  },

  context = {
    max_file_bytes = 512 * 1024,
    max_selection_lines = 2000,
  },

  notices = true,         -- 显示 Agent 的时间线通知

  capabilities = {
    -- 声明给 Agent 的客户端能力；不能用的能力不要打开
    elicitation = { form = true, url = false },
    auth_terminal = true,      -- 终端登录（:Acp login）
    terminal_output_meta = false,
    boolean_config_options = true,
    fs = false,
    terminal = false,
  },

  transport = {
    -- 单条 JSON 消息的字节上限；超过会断开连接。日志会给出实际大小
    max_line_bytes = 32 * 1024 * 1024,
    -- 保留多少字节的 agent stderr 用于诊断
    stderr_keep_bytes = 64 * 1024,
    -- 关闭时等待 agent 自行退出的毫秒数，超时后升级为 SIGKILL
    shutdown_timeout = 2000,
    -- 普通请求的超时（毫秒，0 表示不限制）
    request_timeout = 30000,
    -- 单轮对话的绝对上限（毫秒，0 表示不限制）；默认 10 分钟
    prompt_timeout = 600000,
    max_pending_bytes = 64 * 1024 * 1024, -- 未消费接收数据的估算上限；0 = 不限，超限断开
    spill_bytes = 64 * 1024 * 1024,       -- 完整消息异步落盘的工作集目标；不是硬内存上限
    text_chunk_bytes = 64 * 1024,         -- 解码后超大文本的切片大小；0 = 不切片
    dispatch_budget_ms = 4,               -- 每批分发/接收切片后让出主循环；不可抢占单条消息
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

diff 卡片使用主题自带的 diff 组，所以红绿配色与你的 review 窗口一致：

| 组 | 默认链接 | 作用 |
|---|---|---|
| `AcpDiffAdd` | `DiffAdd` | 新增行的整行背景 |
| `AcpDiffDelete` | `DiffDelete` | 删除行的整行背景 |
| `AcpDiffAddSign` | `DiffAdd` | `+` 号 |
| `AcpDiffRemoveSign` | `DiffDelete` | `-` 号 |
| `AcpDiffHunk` | `NonText` | 多 hunk 时的 `@@` 分隔行 |
| `AcpDiffMeta` | `Comment` | 卡片内分隔线与“已省略 N 行”提示 |
| `AcpDiffFile` | `Title` | 多文件时的路径表头 |

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

### 思考块

思考进行中会实时展开并显示 `Thinking`，正文随 chunk 更新；思考结束（Agent 转入正文、
工具、计划，或回合结束）后自动折叠并改为 `Thought`。历史会话和重连重放的思考保持折叠。

跟随输出时，超过一屏的内容在自动折叠后仍保持尾部锚定，保留原有尾部空行，后续消息继续追加。
内容不足一屏时从顶部正常显示，不添加顶部留白；鼠标到达末尾后不能再将内容向上推移来扩大底部空白。
上翻阅读历史或手动折叠卡片时不强制跳到最新位置；聊天窗口启用局部 `smoothscroll` 以处理跨屏换行。
鼠标上滚离开末尾会暂停自动跟随，滚回实际末尾后自动恢复，并清除新消息提示；判断依据是视口，
不要求光标也停在最后一行。暂停期间仍正常接收消息并追加到 buffer，只是不抢占阅读位置。

`<Tab>` 手动操作始终优先：流式中折叠后不会被后续 chunk 弹开。需要改变默认值时：

```lua
ui = { thoughts = { expand_while_streaming = false, collapse_on_finish = false } }
```

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

### 登录

Agent 在 `initialize` 里声明登录方式时，`:Acp login` 会使用它：

- 只有一个方式时直接执行；多个时用选择器挑选（显示名称和说明）。
- `terminal` 类型会在新的 `:terminal` 分屏里运行**你自己配置的** Agent 命令，只追加 Agent 给出的
  参数和环境变量（ACP 规定登录方式不能指定命令）。启动前会显示实际执行的命令；命令成功退出后
  会重启 Agent 进程并重试刚才失败的操作。连续失败会停止重试，`:Acp login` 可重新开始。
- `agent` 类型（或没有 type）调用 `authenticate(methodId)`，成功后直接重试。
- `session/new`、`session/load`、`session/prompt` 返回 `auth_required`（-32000）时也会进入同一流程。
  超时、断线等本地失败使用不同的错误码，不会误触发登录。
- Agent 完全没有提供登录方式时只提示查看它的文档。
- `:Acp logout` 仅在 Agent 声明 `auth.logout` 时可用。

### 权限请求

Agent 请求权限时弹出选择器，并在旁边打开一个只读详情浮窗：

- `Esc` / `q` 关闭视为拒绝，优先选择 `reject_*` 选项；
  若 Agent 没有提供拒绝项，则返回 `cancelled`。
- 关闭面板不会让权限请求永久挂起。
- 详情浮窗按工具类型显示：`execute` 显示完整命令和工作目录，`edit` 显示 diff，
  其它显示 `content` 或格式化后的 `rawInput`。`permissions.show_details = false` 可关闭。
- 等待回答或批准的 tool card 会显示对应状态，在卡片上按 `<CR>` 可重新打开该请求。
- 可用 `permissions.auto_allow = { "allow_always" }` 显式放开某类请求。
  提问型的权限请求（pi 的 select/confirm、Claude 的 ExitPlanMode）不会被自动回答。

### 提问

Agent 通过 elicitation 提问时（Claude 的 AskUserQuestion、OpenCode 的 question 工具），
acp.nvim 显示表单：

- 只有一个单选字段时直接弹出选择器；多个字段时打开表单，`<CR>` 编辑当前字段，
  `<C-s>` 提交，`q` 取消，`d` 拒绝。
- 选项旁的 `<key>_custom` 字段会成为 "Other"，也可以在选择选项后作为备注一起提交。
- 不支持的结构（嵌套对象等）会回复 `decline` 并提示。
- 需要浏览器时（URL 模式）弹确认后交给 `vim.ui.open`。

## 已知限制

- 未实现客户端侧的文件读写与终端能力（`fs/read_text_file`、`terminal/*`），
  这些功能由 Agent 自行完成。
- 登录方式由 Agent 提供；插件不内置任何 Agent 专属的登录命令或凭据处理。
- 修改审阅（逐块接受 / 拒绝）尚未提供：可以展开工具调用查看完整 diff，但不能在
  插件里应用或回滚某一块改动。
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
