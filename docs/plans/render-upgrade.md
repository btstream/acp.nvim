# acp.nvim 对话渲染升级：Zed 卡片 + Markdown 渲染

状态：待实施
创建：2026-11-09

> 本文档位于仓库内，便于在任意机器上检出代码后直接按计划实施。
> 文中「当前」的行号以提交 `c63233b` 为基准；若代码已演进，请以函数名为准重新定位。

---

## 1. 目标

参考 Zed 的对话输出形态，把 `acp_chat` 从「纯文本行」升级为：

1. **工具调用渲染成卡片**：标签 + 带背景的内容块（无圆角）
2. **Markdown 输出正确渲染**：行内格式、代码块语法高亮，接近 opencode 的效果
3. **Thought 默认隐藏、可手动展开**，并提供配置项控制默认状态
4. 卡片**只用于工具块**，用户消息 / 助手消息 / plan 等保持现状

已与用户确认的三条设计约束：

| 编号 | 决定 |
|---|---|
| 1 | 卡片不要圆角 |
| 2 | Thought 默认保持隐藏，可手动展开，并提供选项控制 |
| 3 | 只有工具块使用卡片样式 |

---

## 2. 已完成的可行性验证

以下结论均在真实 Neovim（v0.13.0-dev / LuaJIT）中实测，不是推测。

### 2.1 卡片背景

| 验证项 | 结果 |
|---|---|
| 单个 extmark 用 `end_row` 覆盖多行背景 | 可用 |
| `hl_eol = true` 把背景铺到窗口右边缘 | 可用 |
| 换行产生的续行是否继承背景 | 继承（实测 3 个屏幕行全部着色） |
| 背景与前景高亮叠加（`hl_mode="combine"`） | 可用 |
| `end_col` 超过行长 | **报错** `Invalid 'end_col': out of range`，因此内边距必须用真实空格字符 |
| 空行（长度为 0）上加背景 | 可用（`end_col=0` + `hl_eol`） |

结论：**无圆角方案下，卡片 = 连续背景带**。不需要 `virt_text` 覆盖，也不需要自控换行，`hl_eol` 天然铺满。

### 2.2 行内 Markdown 解析成本

对一行含 `**bold**`、`*italic*`、`` `code` ``、`[link](url)`、`~~gone~~` 的文本重复 200 次：

| 方案 | 耗时 |
|---|---|
| treesitter `markdown_inline` | 51.2 ms（0.256 ms/行） |
| 手写扫描 + gsub | 0.7 ms（0.0035 ms/行） |

结论：**行内手写扫描器，快约 70 倍**，且无依赖。

### 2.3 代码块语法高亮

| 验证项 | 结果 |
|---|---|
| `vim.treesitter.get_string_parser(code, lang)` | 可用 |
| highlights query 能拿到精确字节区间 | 可用 |
| 60 行 Lua 解析 + 遍历 | 2.35 ms |
| parser 缺失时行为 | 抛错，需 `pcall` 包裹并降级 |
| 解析器是否随 Neovim 分发 | 是（`/usr/lib/nvim/parser/` 已有 markdown、markdown_inline、lua 等） |
| capture 解析为高亮组 | 优先 `@<capture>.<lang>`，回退 `@<capture>`，`hlexists` 均为 1 |

结论：**代码块用 treesitter，仅 fence 闭合后执行一次并缓存**。

### 2.4 conceal 隐藏标记字符

| 验证项 | 结果 |
|---|---|
| extmark `conceal = ""` 隐藏指定区间 | 可用 |
| 需要 `conceallevel >= 2` | 是（当前 chat 窗口为 0，必须改） |
| conceal 后字节偏移是否不变 | 不变，因此与现有增量缓存兼容 |

结论：**保留原始字符，用 conceal 隐藏标记**，`text` 与字节偏移保持一致，增量缓存逻辑无需改动。

---

## 3. 现状分析

### 3.1 现有渲染管线

```
reducer.apply()            更新 AcpSessionState.blocks
  ↓
Chat:render()              blocks.render_block() → lines/meta
  ↓
blocks.render_block()      按 kind 分派到 render_user / render_assistant / render_tool / ...
  ↓
blocks.render_text()       逐行 → render_line()，带增量缓存
  ↓
render_line()              仅识别 # 标题 / > 引用 / - * 列表 / `code` / ``` fence
  ↓
Chat:render()              nvim_buf_set_lines 增量写入 + 按行打 extmark
```

关键文件：

- `lua/acp/ui/blocks.lua`（519 行）：块渲染
- `lua/acp/ui/chat.lua`（525 行）：缓冲区写入与高亮
- `lua/acp/ui/highlights.lua`（96 行）：高亮组定义
- `lua/acp/session/reducer.lua`：把 ACP update 压成 block
- `lua/acp/config.lua`：默认配置

### 3.2 缺失能力清单

| 缺失 | 现状 | 影响 |
|---|---|---|
| 行内格式 | `**bold**` 等原样显示 | 最影响观感 |
| 代码块语法高亮 | 整块只有一个 `AcpCodeFence` 颜色 | 代码不可读 |
| 多级标题 | `#`/`##`/`###` 渲染结果相同 | 层次丢失 |
| 工具卡片 | 只有一行 `▸ ✓ 标题 done` | 与目标差距最大 |
| thought 单块折叠 | 只有全局 `ui.show_thoughts` 开关 | 无法按需查看 |
| 任务列表 / 水平线 | 未处理 | 次要 |

### 3.3 相关代码位置（当前行号）

| 位置 | 内容 |
|---|---|
| `blocks.lua:107-147` | `render_line()`，行内语法解析入口 |
| `blocks.lua:162-212` | `render_text()`，增量渲染核心 |
| `blocks.lua:220-236` | `indent_lines()`，行前缀缩进 |
| `blocks.lua:280-289` | `render_thought()` |
| `blocks.lua:291-302` | `tool_icon()` |
| `blocks.lua:304-386` | `render_tool()` |
| `blocks.lua:466-517` | `render_block()` 分派 + 宽度失效 |
| `chat.lua:168-330` | `Chat:render()`，写 buffer + 打 extmark |
| `chat.lua:332-350` | `apply_line_highlights()` |
| `chat.lua:405-416` | `Chat:toggle_current()` |
| `chat.lua:515-523` | `Chat:transcript()` |
| `highlights.lua:4-38` | 高亮组表 |
| `config.lua:66-96` | `ui` 默认配置 |

---

## 4. 数据结构扩展

### 4.1 `AcpRenderedLine`

```lua
---@class AcpRenderedLine
---@field text string
---@field segments {s: integer, e: integer, group: string}[]|nil
---@field bg string|nil        -- 整行背景高亮组；nil 表示无背景
---@field tag string|nil       -- 卡片标签行标记（用于样式区分，不参与布局）
```

新增字段都是可选的，现有渲染函数不设置即保持原行为，向后兼容。

### 4.2 块级新增字段（`AcpBlock`）

```lua
---@field _code_hl table|nil  -- 代码块高亮缓存（fence 闭合后生成）
---@field _card_w integer|nil -- 卡片填充宽度缓存（随宽度失效）
```

---

## 5. 实施计划

### 阶段 0（共享前置）：行背景绘制机制

代码块背景（阶段 2）与工具卡片（阶段 3）都需要「给一段连续行加背景」。
先把这个机制单独做掉，后续两个阶段都复用它。

**修改** `blocks.lua`：`AcpRenderedLine` 增加 `bg` 字段（见第 4 章）。

**修改** `chat.lua`：新增背景合并绘制。

```lua
local ns_bg = vim.api.nvim_create_namespace("acp_chat_bg")

---Paint contiguous runs of lines that share the same `bg` using one extmark.
---@param meta table[] lines metadata produced by render()
---@param prefix integer first rewritten row (0-based, inclusive)
---@param end_line integer exclusive end row of the rewritten range (-1 for all)
local function apply_backgrounds(buf, meta, prefix, end_line)
  local last = end_line == -1 and #meta or end_line
  local row = prefix
  while row < last do
    local bg = meta[row + 1] and meta[row + 1].bg
    if bg then
      local stop = row
      while stop + 1 < last and meta[stop + 2] and meta[stop + 2].bg == bg do
        stop = stop + 1
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_bg, row, 0, {
        end_row = stop + 1,
        end_col = 0,
        hl_group = bg,
        hl_eol = true,
        hl_mode = "combine",
        priority = 50,
      })
      row = stop + 1
    else
      row = row + 1
    end
  end
end
```

要点：

- 独立 namespace `ns_bg`，与行内高亮 `ns` 分开，增量更新互不干扰
- 只在本次重写的区间内绘制：先 `nvim_buf_clear_namespace(buf, ns_bg, prefix, end_line)`，
  再调用 `apply_backgrounds`
- 优先级 50，低于行内段（100），保证文字颜色不被背景覆盖
- `hl_eol = true` 让背景铺到窗口右边缘（已实测，换行续行也会继承）

**修改** `chat.lua:meta`：每行增加 `bg` 字段。padding 行同样要写 `block_id`，
否则光标停在 padding 上按 `<Tab>` 无法定位到块。

**修改** `chat.lua:transcript()`：复制时 rstrip 掉卡片/代码块的尾部填充空格。

**测试** `tests/spec_backgrounds.lua`（新增）

- 连续同 `bg` 的行合并成一个 extmark（用 `nvim_buf_get_extmarks` 计数断言）
- 相邻但 `bg` 不同的两段不会被合并
- `bg` 为 nil 的行不产生 extmark
- 增量渲染后旧背景不残留

---

### 阶段 1：行内 Markdown 解析器

**新增文件** `lua/acp/ui/markdown.lua`

职责：把一行的行内 Markdown 解析成 `segments` + `conceal` 隐藏标记。

```lua
---@class AcpInlineSegment
---@field s integer        -- 起始字节（0-based）
---@field e integer        -- 结束字节（exclusive）
---@field group string
---@field conceal boolean|nil  -- true 表示隐藏该区间

---@param line string
---@param base_hl string
---@return AcpInlineSegment[] segments
---@return boolean has_conceal
function M.parse_inline(line, base_hl)
```

解析规则（单遍从左到右，优先级从高到低）：

1. `` `code` `` → `AcpMdCode`，反引号 conceal
2. `[text](url)` → 文本用 `AcpMdLink`，括号部分 conceal
3. `**bold**` / `__bold__` → `AcpBold`，定界符 conceal
4. `*italic*` / `_italic_` → `AcpItalic`，定界符 conceal
5. `~~strike~~` → `AcpStrike`，定界符 conceal
6. 其余文本 → `base_hl`

边界要求：

- 未闭合标记按普通文本处理（流式期间必须正确）
- `**` 优先于 `*`，`__` 优先于 `_`
- 行内代码内部不解析其他语法
- 强调定界符两侧需要边界（避免 `snake_case` 被识别成斜体）
- 不做递归/嵌套（`**bold with `code`**` 内部代码按外层处理即可）

**修改** `blocks.lua:render_line()`

- 非 fence 分支调用 `M.parse_inline()`
- 返回的 conceal 段写入 `line.conceal` 新字段
- 保持 `line.text` 不变（字节偏移一致）

**修改** `chat.lua:apply_line_highlights()`

- 对 `seg.conceal` 的段设置 `conceal = ""`
- 这需要窗口 `conceallevel = 2`

**修改** `layout/init.lua:apply_window_options()`

- chat 窗口加 `vim.wo[win].conceallevel = 2`
- 同时设 `concealcursor = "nvic"`，避免光标所在行恢复显示标记

**测试** `tests/spec_markdown.lua`（新增）

- 每种语法单独用例
- 未闭合标记
- 嵌套边界（`snake_case`、`2*3*4`）
- 多字节字符（中文）偏移正确
- 空行、纯文本

---

### 阶段 2：代码块语法高亮

**新增文件** `lua/acp/ui/code_hl.lua`

```lua
---@param code string      -- 代码块内容（不含 fence）
---@param lang string      -- fence 语言标识
---@param line_offset integer -- 代码块在 block 内的起始行号（用于映射 extmark 行）
---@return {line: integer, s: integer, e: integer, group: string}[]|nil
function M.highlight(code, lang, line_offset)
```

实现要点：

1. `pcall(vim.treesitter.get_string_parser, code, lang)`，失败返回 `nil`（降级为纯文本）
2. 取 `highlights` query，遍历 `iter_captures`
3. capture 名 → 高亮组：先试 `"@" .. name .. "." .. lang`，回退 `"@" .. name`
4. 用 `metadata.priority` 排序，低优先级先写，高优先级后写（extmark 后写覆盖）
5. 结果缓存到 `block._code_hl`，fence 闭合时计算一次
6. 语言别名映射：`js`→`javascript`、`ts`→`typescript`、`sh`/`bash`→`bash`、`py`→`python`，避免因别名导致 parser 找不到

**修改** `blocks.lua:render_text()`

fence 状态机扩展：
- 记录 fence 起始行索引
- 遇到闭合 fence 时，取代码内容调用 `code_hl.highlight()`
- 把返回的高亮区间映射到已生成行的 `segments` 上（覆盖 `AcpCodeFence`）
- 流式期间未闭合 → 保持纯文本，闭合后再补高亮

**新增高亮组**（`highlights.lua`）

```
AcpCodeBlockBg  -- 代码块背景（比卡片更淡）
AcpCodeLang     -- fence 语言标签
```

**代码块背景**（已确认要做）

`render_text` 在 fence 内生成的行设 `bg = "AcpCodeBlockBg"`，覆盖范围包含
fence 语言标签行与代码行。实际绘制复用第 5.0 节的背景合并机制——因此
该机制必须在阶段 2 之前落地，不要等到阶段 3。

**测试** `tests/spec_code_hl.lua`（新增）

- 有 parser（lua）时产生预期数量区间
- 无 parser（不存在的语言）时返回 nil 且不抛错
- 语言别名解析
- 多行代码的行号映射正确
- fence 内行带 `AcpCodeBlockBg`，fence 外不带

---

### 阶段 3：工具卡片

**修改** `blocks.lua:render_tool()`

新结构（对照 Zed 截图）：

```
▸ ✓ Run Command                      ← 头部：折叠符 + 状态图标 + 标签
                                     ← 卡片背景开始（padding 行，bg）
  grep -n "iced" Cargo.toml | head   ← 内容行（bg，左侧 2 列内边距）
                                     ← 卡片背景结束（padding 行，bg）
```

具体规则：

| 项 | 规则 |
|---|---|
| 标签映射 | `execute`→`Run Command`、`edit`→`Write`、`read`→`Read`、`search`→`Search`、`fetch`→`Fetch`、`think`→`Thinking`、其他→`block.name` 或 `Tool` |
| 头部样式 | 折叠符 `AcpSeparator`、图标按状态、标签 `AcpToolTag`（muted 小字风格） |
| 状态后缀 | 保留现有 `done`/`failed`/`running`，用 `AcpMuted` |
| 内容来源 | `block.detail`（reducer 已把 `content` 压平） |
| 内边距 | 左 2 列、上 1 行、下 1 行，全部为**真实空格文本**，并设 `bg` |
| 填充宽度 | `ctx.width - 2`，用 `nvim_strwidth` 计算，补足空格 |
| 折叠状态 | `expanded = false` 时只输出头部；`true` 时输出卡片 |
| 背景组 | `AcpCardBg` |
| locations | 展开时列在卡片下方，不放进卡片内 |

**背景绘制**：直接复用阶段 0 的 `apply_backgrounds()`，阶段 3 不需要再写绘制逻辑，
只需在 `render_tool` 产出的卡片行上设置 `bg = "AcpCardBg"`。

**修改** `chat.lua:transcript()`

复制时去掉行尾填充空格：

```lua
for _, line in ipairs(lines) do
  out[#out + 1] = (line:gsub("%s+$", ""))
end
```

**新增高亮组**

```
AcpCardBg   -- 卡片背景（zed_style 下低对比度）
AcpToolTag  -- 工具标签
```

**测试** `tests/spec_cards.lua`（新增）

- `execute` 渲染出 `Run Command`
- 折叠时只有头部一行
- 展开时包含上下 padding 行且都有 `bg`
- padding 行宽度等于 `ctx.width`
- 连续卡片行合并成一个 extmark
- 两个相邻卡片不会被合并
- `transcript()` 不含尾部空格

---

### 阶段 4：Thought 折叠

**修改** `blocks.lua:render_thought()`

```lua
local function render_thought(block, ctx)
  local expanded = block.expanded == true
  local caret = expanded and ctx.icons.chevron_down or ctx.icons.chevron_right
  -- 折叠：只输出一行 "▸ Thinking"
  -- 展开：输出 caret + 正文（缩进 2 列）
end
```

**修改** `chat.lua:toggle_current()`

```lua
if block.kind == "tool" or block.kind == "compaction" or block.kind == "thought" then
```

**修改** `blocks.lua:render_block()` 的 thought 分支

现有逻辑：`if not ctx.show_thoughts then return {} end`

新逻辑（已确认）：
- `ctx.show_thoughts == true` → 完全展开（兼容旧行为）
- `ctx.show_thoughts == false` → 输出一行折叠头部 `▸ Thinking`，可展开
- 头部可见性由 `ui.thoughts.show_collapsed_header` 控制，默认 `true`

**新增配置** `config.lua`

```lua
ui = {
  -- 旧键保留，映射为 default_expanded
  show_thoughts = false,
  thoughts = {
    -- 是否默认展开思考内容
    default_expanded = false,
    -- 折叠时是否显示一行头部（便于发现和展开）
    show_collapsed_header = true,
  },
}
```

兼容处理：`show_thoughts = true` 视同 `thoughts.default_expanded = true`。

**测试** `tests/spec_thoughts.lua`（新增）

- 默认隐藏时只有折叠头
- `<Tab>` 展开后显示正文
- `show_thoughts = true` 完全展开
- 折叠头关闭时不输出任何行

---

## 6. 高亮组汇总

新增（`highlights.lua`）：

```lua
AcpCardBg       = { link = "NormalFloat" }      -- 卡片背景（工具块）
AcpToolTag      = { link = "Comment" }          -- 工具标签（Run Command / Write）
AcpCodeBlockBg  = { link = "NormalFloat" }      -- 代码块背景（比 AcpCardBg 更淡）
AcpCodeLang     = { link = "Comment" }          -- fence 语言标签
AcpMdCode       = { link = "String" }           -- 行内代码（需带 bg）
AcpBold         = { bold = true }
AcpItalic       = { italic = true }
AcpStrike       = { strikethrough = true }
AcpMdLink       = { link = "Underlined" }
AcpH1           = { link = "Title", bold = true }
AcpH2           = { link = "Title" }
AcpH3           = { link = "Function" }
AcpH4           = { link = "Function" }
```

两种背景的区分：

| 组 | 用途 | 视觉 |
|---|---|---|
| `AcpCardBg` | 工具卡片 | 较明显的背景块 |
| `AcpCodeBlockBg` | 代码块 | 更淡，避免与卡片混淆 |

`zed_style` 下把 `AcpCodeBlockBg` 调得比 `AcpCardBg` 更接近 `Normal`，并给
`AcpMdCode` 一个轻微 `bg`（行内代码在 Zed/opencode 里都有底色）。

现有 `AcpHeading` 保留（向后兼容），新标题按级别映射到 `AcpH1..H4`。

---

## 7. 需要特别注意的坑

| # | 问题 | 处理 |
|---|---|---|
| 1 | `conceallevel` 未设置导致 `**` 裸露 | `layout/init.lua` 为 chat 窗口设 2 |
| 2 | `transcript()` 复制出尾部填充空格 | 复制时 rstrip |
| 3 | padding 行缺 `block_id` 导致 `<Tab>` 失效 | meta 中 padding 行沿用所属块 id |
| 4 | 宽度变化后卡片填充错乱 | 卡片宽度缓存纳入 `_md_width` 失效逻辑 |
| 5 | CJK 宽度计算错误 | 统一用 `nvim_strwidth`，不用 `#` |
| 6 | 增量渲染时旧背景残留 | 更新区间内先 `clear_namespace(ns_bg, ...)` |
| 7 | 流式期间未闭合标记闪烁 | 未闭合按纯文本处理 |
| 8 | 未闭合 fence 时跑 treesitter | 只在闭合后解析 |
| 9 | 无 parser 时抛错 | `pcall` 包裹并降级 |
| 10 | 折叠切换不触发重渲染 | `block_signature` 已含 `expanded`，确认 thought 走同一路径 |
| 11 | 背景与行内高亮争抢 | 背景 `priority=50`，行内 `priority=100`，且 `hl_mode="combine"` |
| 12 | 性能回退 | 复用 `_md_*` 增量缓存；代码高亮只在 fence 闭合时跑一次 |

---

## 8. 验证方式

### 8.1 基线

当前状态：**204 个单元测试 + 15 集成 + 3 重连 + 8 edgy 全部通过**。

### 8.2 新增测试文件

```
tests/spec_backgrounds.lua  行背景绘制（阶段 0）
tests/spec_markdown.lua     行内解析（阶段 1）
tests/spec_code_hl.lua      代码高亮 + 代码块背景（阶段 2）
tests/spec_cards.lua        工具卡片（阶段 3）
tests/spec_thoughts.lua     thought 折叠（阶段 4）
```

并在 `tests/run.lua` 注册。

### 8.3 性能预算

现有基准（`tests/perf.lua`）：

| 项 | 当前 | 上限 |
|---|---|---|
| 1000 blocks 首次渲染 | 14–18 ms | 1500 ms |
| 200 次流式更新 | ~240 ms | 1500 ms |
| 展开单个块 | ~1–2 ms | 300 ms |
| 1600 行 markdown | 1–3 ms | 400 ms |
| 1000 次 toolbar 渲染 | ~3 ms | 300 ms |

新增功能后要求：**1000 blocks 首次渲染不超过 100 ms**（卡片与高亮增加开销，但仍是低频路径）。

### 8.4 视觉验证

`tests/render_preview.lua` 生成 `tests/preview.txt`，可反复对比输出。建议补充：
- 一个含粗体/斜体/行内代码/链接的助手消息
- 一个含多个工具卡片（execute/edit/read）的会话
- 一个折叠与展开的 thought 块
- 一个含 lua 代码块的助手消息（验证语法高亮）

### 8.5 手工验证

```
nvim --headless -u tests/minimal_init.lua -l tests/render_preview.lua
```

以及用真实 opencode 跑一轮，确认：
- 工具卡片背景连续无断裂
- 换行时背景不错位
- 复制 transcript 不带尾部空格

---

## 9. 实施顺序与风险

| 阶段 | 内容 | 风险 | 预期改动量 |
|---|---|---|---|
| 0 | 行背景绘制机制（共享前置） | 低（新增能力，不改现有输出） | 改 ~60 行 + 测试 |
| 1 | 行内 Markdown | 低（纯文本层） | 新增 ~150 行 + 测试 |
| 2 | 代码块高亮 + 背景 | 中（依赖 treesitter） | 新增 ~100 行 + 测试 |
| 3 | 工具卡片 | 中（改布局与 buffer 写入） | 改 ~120 行 + 测试 |
| 4 | Thought 折叠 | 低 | 改 ~40 行 + 测试 |

建议每阶段独立提交，跑完整测试后再进入下一阶段。

依赖关系：

- **阶段 0 必须最先完成**：阶段 2（代码块背景）与阶段 3（工具卡片）都依赖它
- 阶段 1、2 都改 `render_line` / `render_text`，应顺序合并而非并行
- 阶段 3、4 互相独立，可与阶段 1 并行开发

---

## 10. 已确认的设计决策

以下四点已与用户确认，实施时按此执行，不再需要二次询问。

1. **折叠状态的 thought 显示 "▸ Thinking" 头部** —— 是。
   折叠时输出一行头部，用户按 `<Tab>` 展开。对应配置
   `ui.thoughts.show_collapsed_header = true`（默认开启）。

2. **代码块加背景** —— 是。
   使用 `AcpCodeBlockBg`，比工具卡片 `AcpCardBg` 更淡，以便区分「代码块」与
   「工具卡片」两种语义。背景覆盖范围：fence 语言标签行 + 代码行，不含上下文。

3. **diff 内容渲染成真实 +/- 行** —— 本次不做，留待后续迭代。
   当前 `reducer.tool_content_text()` 把 `type=="diff"` 压成 `diff: path`，
   行为保持不变。

4. **表格支持** —— 本次不做，留待后续迭代。

### 本次范围之外（记录备查）

若后续要做，可参考以下切入点：

- **diff 渲染**：`reducer.tool_content_text()` 目前丢弃 `item.type == "diff"` 的具体
  内容。需要保留 `item.oldText` / `item.newText`，在 `render_tool` 里按行计算
  `+` / `-` / 上下文前缀，并用 `AcpDiffAdd` / `AcpDiffDelete` / `AcpDiffContext`
  三个高亮组着色。
- **表格**：`render_line` 目前逐行处理，无法判断表格边界。需要在 `render_text`
  里增加块级状态（识别 `|---|` 分隔行），并为每列计算宽度后补齐空格再渲染。

---

## 11. 附录：关键 API 验证备忘

供实施时参考，均已实测。

```lua
-- 多行背景
vim.api.nvim_buf_set_extmark(buf, ns, start_row, 0, {
  end_row = end_row + 1,
  end_col = 0,
  hl_group = "AcpCardBg",
  hl_eol = true,
  hl_mode = "combine",
  priority = 50,
})

-- conceal 标记
vim.api.nvim_buf_set_extmark(buf, ns, row, s, { end_col = e, conceal = "" })
-- 需要: vim.wo[win].conceallevel = 2

-- 代码高亮
local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
if ok then
  local tree = parser:parse()[1]
  local query = vim.treesitter.query.get(lang, "highlights")
  for id, node, metadata in query:iter_captures(tree:root(), code) do
    local name = query.captures[id]
    local group = vim.fn.hlexists("@" .. name .. "." .. lang) == 1
      and ("@" .. name .. "." .. lang)
      or ("@" .. name)
    local sr, sc, er, ec = node:range()
    -- sc/ec 为字节偏移
  end
end
```
