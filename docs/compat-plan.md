# 多 agent 兼容与架构重整计划

更新：2026-11-13。状态：阶段 0–9 已实现，自动化测试全部通过；**真实 agent 的手工验收（M1–M4）
尚未进行**，见 §7。本文是实施计划与验收记录，不是对当前实现的完整描述；实现细节以
`docs/architecture.md` 与 `docs/status.md` 为准。

## 阅读提示

- §0.1、§1 是**实施前的快照**（2026-11-12 的审计结论），保留下来是为了说明当时的判断依据。
  其中提到的文件、行号与「现状」大多已被后续重构改变，不要当作当前实现来读。
- 每个阶段末尾的「状态」段记录实际做了什么、与计划哪里不同。
- §6 的决策多数已在实现中定案，未定的会明确标注。

## 0. 目标与原则

**目标**：以 OpenCode、Claude Code（claude-agent-acp）为主力，同时完整兼容 pi（pi-acp）
和任何遵循 ACP v1（规范 1.17）的 agent。

**原则**

- 不重写 transport、RPC、重放事务、渲染调度：这些部分稳定，只做注入和边界修整。
- 先打地基再加功能：先建交互中心、能力模块，再在其上实现 elicitation、认证、终端等。
  不在旧结构上堆叠第四份「待回答状态」。
- 每个阶段可以单独合并：有自己的测试、验收标准，并且不让 OpenCode 现有行为回退。
- 测试先行：每个阶段开始前，先在 mock agent 中加入对应 agent 的行为场景。
- 用户配置向后兼容：旧配置项保留含义；新配置项都有安全的默认值。

## 0.1 探测记录（2026-11-12 快照）

> 这一节是实施前的调研记录，保留作为依据。除 OpenCode 外都没有真实握手确认，见 §5、§7。

- OpenCode 2.2.7 真实握手：与下表一致。`session/new` 只返回 configOptions：`model`、`effort`（category
  thought_level：off/low/high/max/default）、`mode`（build/plan）；登录方式为 terminal 类型 `opencode-login`，
  带 `_meta["terminal-auth"]`（`opencode auth login`）。
- Claude 与 pi 的报文形态取自上游源码与 claude-agent-acp 录制的协议场景
  （`src/tests/acp-scenarios/origin-main/plain/*.jsonl`）。截至本文更新时仍**未**用真实 adapter 握手
  （需要 npx 下载）。
- ExitPlanMode 的实际形态：`toolCall.kind = "switch_mode"`、`toolCall.name = "ExitPlanMode"`、
  `toolCall.title = "Approve Plan"`，"Ready to code?" 在 `_meta.permission.title`；选项依次为
  `exit-plan-default`(allow_once)、`exit-plan-clear-auto`、`exit-plan-auto`、`exit-plan-bypass`(allow_always)、`reject`(reject_once)。
- Claude 的权限请求标题统一放在 `_meta.permission.title`；工具名同时出现在 `toolCall.name` 与 `_meta.claudeCode.toolName`。

## 1. 现状摘要（实施前快照：2026-11-12 的三份审计）

> **已过时。** 下表描述的是本项目开始改造**之前**的状态，用于说明为什么需要这份计划。
> 现在每一条都已被后续阶段改变，行号引用全部失效。当前实现请读 `docs/architecture.md`。
> 若要看每条问题的结局，对照各阶段的「状态」段。

| 领域 | 当时的现状 | 当时的影响 |
|---|---|---|
| 客户端能力声明 | 只有 `session.notices` | Claude 禁用 AskUserQuestion；OpenCode 取消提问；三个 agent 都不下发登录方式 |
| agent → 客户端请求 | 只处理 `session/request_permission`；elicitation、fs、terminal 都返回 -32601 | 没有提问通道 |
| 权限状态 | 存了三份（client、控制器、`app/permissions`） | `$/cancel_request` 后会重复回复；picker 没有排队 |
| 权限 UI | 不显示 `toolCall.content`、`rawInput`；关闭时默认选 reject；`auto_allow` 按 kind 匹配 | 批准时看不到内容；pi 的提问可能被自动回答 |
| JSON `null` | 解码后变成 `vim.NIL` 漏进 reducer | 块只更新一半 |
| 模式与配置 | 只认 configOptions；`currentModeId` 读错层级；boolean 配置项无法选择 | pi 无法切换；Claude 徽章不准确 |
| 认证 | `authenticate` 没有调用方；错误提示写死 OpenCode | Claude 和 pi 首次使用无法在插件里登录 |
| agent 专属逻辑 | OpenCode `_meta` 写在 reducer 里；徽章只认 plan/build；错误提示按字符串匹配 | 每接入一个 agent 都要改核心代码 |
| inline | 依赖 agent 写文件前请求权限；提问被自动拒绝 | Claude 在 acceptEdits/bypass 模式下、pi 可能直接改原文件 |
| controller | 当时 1446 行，全局表 `S`，和 inline 循环依赖 | 改动成本高，难以测试 |
| 测试 | mock agent 只模拟 OpenCode | 其它 agent 的行为没有回归保障 |

三个 agent 的关键差异（实施前调研结论，仍可作为参考；行为已由 mock profile 复现）：

| | OpenCode | Claude Code | pi |
|---|---|---|---|
| 提问 | elicitation form（客户端不支持时取消提问） | elicitation form（客户端不支持时禁用该工具） | 用权限请求包装：select 选项全是 `allow_once`；confirm 为 yes/no |
| 计划审批 | 未确认 | 权限请求（ExitPlanMode，"Ready to code?"） | 无 |
| 模式 | configOptions（build/plan） | `modes` + configOptions（default/acceptEdits/plan/auto/bypassPermissions；选项带 `_meta.kind`：standard/plan/auto_review/full_access） | `modes` = 思考级别，**同时**提供 configOptions（model + `thought_level`） |
| 执行前权限 | 有 | 有（选项顺序有含义） | 无 |
| 终端输出 | 文本 | 文本；客户端声明 `_meta.terminal_output` 后改用 `_meta` | 未经 `terminal/create` 的伪 terminal content；**输出只在 `_meta.terminal_output` 里**，没有文本 |
| 认证 | terminal（`opencode auth login`） | terminal（claude.ai / console） | terminal（`--terminal-login`） |

## 2. 阶段总览

```text
阶段 0  测试地基（多 profile mock agent）
   │
阶段 1  协议地基（null 规范化、能力模块、请求注册表、创建中缓冲、取消语义）
   │
阶段 2  交互中心（迁移权限请求，行为不变 + 修复现有 bug）
   │
   ├── 阶段 3  提问与权限详情（elicitation form、提问型权限、权限详情）  ← 里程碑 M1：Claude/OpenCode 能提问
   ├── 阶段 4  认证（terminal auth、authRequired 流程）
   │
阶段 5  agent profile 与规范化 controls（预设、模式回退、移出 OpenCode 专属逻辑）  ← M2：pi 完整可用
   │
   ├── 阶段 6  呈现补全（终端 _meta、rawOutput、plan 去重、停止原因……）
   ├── 阶段 7  inline 安全与提问                                         ← M3：inline 在三个 agent 上都安全
   └── 阶段 8  会话管理与上下文补全
阶段 9  架构收尾（controller 拆分、依赖注入），穿插在 1–8 中进行                   ← M4
```

预估工作量（单人，含测试和文档）：阶段 0–2 约 4–5 天；阶段 3–4 约 4 天；阶段 5 约 3 天；
阶段 6–8 约 5 天；阶段 9 穿插进行，收尾约 2 天。

实际执行与计划的两点差异：

- **阶段 9 并非「穿插进行」**：1–8 各阶段只做了各自的改动，架构收尾（状态拆分为三个
  store、事件分发表、注入化）是一次性完成后提交的。计划原本想把它摊平到每个阶段，实际没有。
- **里程碑 M1–M4 的手工验收全部未做**：所有自动化门禁都通过，但没有在真实 OpenCode /
  Claude Code / pi 上跑过。这是本计划唯一未完成的验收项，见 §7。

---

> **以下各阶段的「改动」清单是实施前的计划原文，保留作为历史记录。** 其中出现的行号
> （如 `controller.lua:676`）与部分文件名已被后续重构改变，读的时候请以每个阶段末尾的
> 「状态」段为准；那里写的是实际做了什么，以及和计划不同的地方。

## 阶段 0：测试地基

**目标**：在改任何行为之前，让测试能模拟三个 agent 的真实行为。

**改动**

- `tests/mock_agent.py` 支持 `ACP_MOCK_PROFILE=opencode|claude|pi|generic`（默认 opencode，现有测试不变）。
  各 profile 的差异集中放在一张表里：
  - `initialize`：agentCapabilities、authMethods（`terminal` 类型和 `_meta["terminal-auth"]`）。
  - `session/new`：opencode 只返回 configOptions；claude 返回 `modes` + configOptions；
    pi 只返回 `modes`（思考级别）。
  - 场景触发词（prompt 文本中包含特定标记时触发）：
    - `@ask`：claude/opencode 发 `elicitation/create`（单选 + 多选 + `_custom`）；pi 发 select 型权限请求。
    - `@plan-approve`：claude 发 ExitPlanMode 权限请求（完整的五个选项）。
    - `@null`：在 tool_call、tool_call_update、session_info_update 中放 `null` 字段。
    - `@bash`：pi 发伪 terminal content + `_meta.terminal_output`；claude 在客户端声明后发 `_meta`。
    - `@auth`：`session/new` 返回 authRequired（-32000）。
    - `@cancel-request`：发出权限请求后，用 `$/cancel_request` 撤回。
    - `@early-update`：在 `session/new` 返回之前推送 `available_commands_update`。
  - 记录收到的客户端请求和回复，供测试断言（例如「权限请求只被回复一次」）。
- `tests/spec_protocol_conformance.lua`（新增）：对每个 profile 跑一遍
  initialize → new → prompt → cancel → load，断言没有报错、没有丢弃更新、每个请求都只回复一次。

**状态**：已完成。mock 支持 `ACP_MOCK_PROFILE`、`ACP_MOCK_LOG`、`ACP_MOCK_EARLY_UPDATE`、
`ACP_MOCK_AUTH_REQUIRED`/`ACP_MOCK_AUTH_MARKER`（`--mock-login`）与 `@ask`/`@plan-approve`/`@bash`/`@null`/`@cancel-request`；
`t.pending` + `ACP_TEST_PENDING=1` 的机制保留在 harness 里，但当前已无 pending 用例。
`tests/spec_protocol_conformance.lua` 现为 19 项，全部通过；阶段 0 时原本有 8 项 pending，
已按计划在后续阶段逐项转为普通断言。`@early-update` 与 `@auth` 的用例是后续阶段补的
controller 级测试。

**验收**：新的一致性测试对 4 个 profile 运行，无 -32601、无重复回复、无丢弃更新。

---

## 阶段 1：协议地基

### 1.1 `null` 规范化
- `protocol/client.lua` 的解码处改为 `vim.json.decode(line, { luanil = { object = true, array = true } })`。
- 全仓库搜索 `vim.NIL`：保留确实需要区分「显式 null」的地方（例如 diff 的 `oldText = null` 表示新文件；
  解码后这里得到 nil，需要确认 `ui/diff.lua` 已经把 nil 视为新建文件）。
- reducer 的 `apply` 改为先计算新值、成功后整体替换：出错时整条更新丢弃并记录日志，不留下只更新一半的块。

### 1.2 能力模块 `protocol/capabilities.lua`（新增）
```lua
-- 客户端声明：由配置和已实现的功能共同决定，只声明真正实现了的能力
M.client(config) -> table   -- initialize.clientCapabilities
-- agent 能力查询：统一路径语法，缺失即 false
M.supports(agent_caps, "prompt.image" | "prompt.embeddedContext" | "session.list" |
           "session.resume" | "session.close" | "session.delete" | "loadSession" | ...) -> boolean
```
- 能力声明随阶段逐步打开：阶段 3 加 `elicitation.form`，阶段 4 加 `auth.terminal` 和
  `_meta["terminal-auth"]`，阶段 6 加 `_meta.terminal_output`。每个能力都有对应的配置开关，
  默认开启，用于排查问题。
- 把散落的检查改成调用 `supports`：`app/prompts.lua`（image）、`app/attachments.lua`（embeddedContext）、
  `app/sessions.lua`（loadSession、delete）、`app/catalog.lua`（list）。

### 1.3 agent 请求注册表
- `protocol/client.lua` 的 `install_handlers` 不再写死方法，改为
  `client:on_agent_request(method, handler)`；没有注册的方法仍然返回 -32601。
- `elicitation/complete` 通知同样经注册表分发（阶段 3 使用）。

### 1.4 创建中的 session 先缓冲更新
- `session/runtime`：发出 `session/new` 时登记一个「创建中」的占位；在响应到达前收到的、
  sessionId 未知的更新先缓冲（有上限），创建成功后按顺序重放，失败则丢弃。
- 控制器不再直接丢弃这些更新。

### 1.5 超时与取消语义
- 超时可以按方法配置：`transport.timeouts = { initialize = 120000, session_new = 60000, session_load = 120000 }`。
  `npx` 冷启动 claude-agent-acp 时，30 秒不够。
- `session/load` 的超时在每收到一条回放更新时延长，而不是从发出请求时一次性计时。
- prompt 超时、任务被取消时，先发 `session/cancel`，再发 `$/cancel_request`
  （`protocol/client.lua`、`tasks.lua`）。
- `M.cancel` 处理 `cancelling` 状态：再次取消时强制在本地结束这一轮。

**测试**：`@null`、`@early-update` 场景；超时会发出 `session/cancel`；回放较长时 load 不超时。
**验收**：一致性测试中 null 和提前到达的更新两项转为通过；OpenCode 行为不变。

**状态**：已完成。null 归一化为 nil；reducer 采用回滚日志，失败更新整体丢弃；新增
`protocol/capabilities` 并移除 `protocol/client` 对 `ui/*` 的依赖（调度器注入）；agent 请求走
注册表且回复幂等；创建中的 session 更新有界缓冲后重放；按方法配置超时、load 随回放续期；
取消顺序为 `session/cancel` → `$/cancel_request`，并在本地结算，第二次取消强制结束回合。
一致性测试的 null 与撤回请求两项已转为普通测试；新增 controller 级提前更新、缓冲上限、
超时续期与取消顺序测试。

---

## 阶段 2：交互中心（行为不变的迁移）

**目标**：所有「agent 等待用户回答」的请求只有一个状态源，并且统一生命周期。

### 2.1 `app/interactions.lua`（新增）
```lua
---@class AcpInteraction
---@field id string              -- 内部 id，例如 "perm:12"、"elicit:3"
---@field type "permission"|"elicitation"   -- 后续可加 "terminal"、"fs"
---@field session_id string|nil
---@field tool_call_id string|nil
---@field request table          -- 原始参数（只读）
---@field state "pending"|"answered"|"cancelled"|"expired"
---@field created integer        -- 单调递增序号，用于排序

Interactions.new({ presenters, policies, notify })
Interactions:open(type, request, respond)   -- 由协议层调用；respond 只在这里持有
Interactions:answer(id, response)           -- 只回复一次；之后的重复调用直接忽略
Interactions:cancel(id, reason)             -- 按类型回复对应的取消结果：
                                            --   权限 -> outcome=cancelled
                                            --   elicitation -> action=cancel
Interactions:cancel_session(session_id)     -- session/cancel 时调用
Interactions:cancel_all(reason)             -- 断线、退出、shutdown 时调用
Interactions:on_remote_cancel(rpc_id)       -- agent 发来 $/cancel_request：标为 expired，并关闭对应的 UI
Interactions:pending(session_id?) -> AcpInteraction[]   -- 按 created 排序
Interactions:show_next()                    -- 打开最早的一个待回答请求
```

**策略链**：`open` 后依次询问各策略，第一个给出答案的生效；都不处理就交给呈现器（UI）：

1. `inline` 策略：仅在当前 inline 回合内生效（阶段 7 会改写这条策略）。
2. `auto_allow` 策略：仅对 `type == "permission"` 且被识别为工具权限的请求生效；
   提问型的权限请求（阶段 3.2）不能被自动回答。
3. 呈现器：picker、表单、权限详情等。同一时间只显示一个，其余排队，前一个关闭后再显示下一个。

### 2.2 迁移步骤
1. `protocol/client.lua` 删除 `self.permissions`、`resolve_permission`、`cancel_permissions` 的状态部分，
   改为在注册的 `session/request_permission` 处理器中调用 `interactions:open("permission", params, respond)`。
   `cancel`、`handle_exit`、`shutdown` 改为调用 `cancel_session` / `cancel_all`。
2. `jsonrpc.lua`：收到 agent 的 `$/cancel_request` 时，在回复 -32800 之前通知交互中心；
   `reply` 检查请求是否已经回复过，避免重复回复。
3. `app/permissions.lua` 变成「权限呈现器 + auto_allow 策略」，不再持有状态。
4. controller 删除 `S.pending_permissions`；toolbar 的等待提示从 `interactions:pending()` 读取。
5. inline 不再在 `on_client_event` 开头拦截事件，改为注册为策略（行为与现在相同）。

**顺手修复**：`show_pending` 按 `created` 排序；多个请求时排队显示，不再同时弹出多个 picker；
关闭 picker 时，只有存在 `reject*` 选项才选它，否则回 `cancelled`。

**测试**：`@cancel-request` 只回复一次，picker 被关闭；并发两个请求时依次显示；
session 取消和断线时，所有请求各回复一次。现有权限相关测试全部通过。
**验收**：权限请求的状态只存在一处；行为与迁移前一致（除上述三个修复外）。

**状态**：已完成。新增 `app/interactions` 作为唯一状态源；client 只保留回复回调（无交互
中心的测试替身仍走旧 emit 路径）。inline 与 `auto_allow` 变成策略，picker 变成排队呈现器；
`$/cancel_request` 关闭 picker 且不重复回复。控制器删除 `pending_permissions`，等待提示与
诊断从交互中心读取。新增单次回复、排队、撤回、会话取消和类型化取消测试；原有权限测试全部
迁移并通过。

---

## 阶段 3：提问与权限详情（里程碑 M1）

### 3.1 elicitation（form 模式）
- **schema 解析**（纯函数，新增 `app/elicitation_schema.lua`）：
  - 输入 `requestedSchema`，输出字段列表：
    `{ key, title, description, kind = "choice"|"multi"|"text"|"number"|"integer"|"boolean", options, default, required, constraints }`。
  - 单选：string + `enum` 或 `oneOf{const,title,description}`；多选：array + `items.enum`/`items.anyOf`，
    支持 `minItems`/`maxItems`。
  - 约定：存在 `<key>_custom` 字段时，把它和 `<key>` 合并显示为「选项 + Other（自由输入）」。
  - 不支持的结构（嵌套对象等）：整个请求回复 `decline`，并提示用户。
  - 校验 `required`、`minLength`/`maxLength`、`pattern`、`minimum`/`maximum`、`format`（email、uri、date……）。
- **呈现**（新增 `ui/form.lua`）：
  - 浮窗里显示 `message`，下面是字段列表；`<CR>` 编辑当前字段（选择题用 picker，文本和数字用输入框），
    `<C-s>` 提交，`q` 取消，`d` 拒绝。
  - 只有一个单选字段时简化为直接弹出 picker（Claude 单个问题、OpenCode 简单问题都是这种情况）。
  - 选项的 `description` 显示在选项旁；`_meta["_claude/askUserQuestionOption"].preview` 有内容时显示在预览区。
- **回复**：
  - 提交：`{ action = "accept", content = {...} }`，数值按 schema 类型转换。
  - 取消（`q`、关闭窗口）：`{ action = "cancel" }`；拒绝：`{ action = "decline" }`。
  - session 取消或断线时，由交互中心统一回 `cancel`。
- **能力声明**：`elicitation = { form = vim.empty_dict() }`（配置项 `elicitation.form = true`）。
- **url 模式**（可选，排在本阶段最后）：显示 URL 和说明，让用户确认后用 `vim.ui.open` 打开；
  回复 `accept`；收到 `elicitation/complete` 时关闭提示。声明为 `url = {}`。
  默认关闭，配置项 `elicitation.url = false`。
- **transcript**：在对应的 tool card 上标记「等待回答」，回答后显示答案摘要。

### 3.2 提问型权限请求的识别与呈现
满足以下任一条件，就把权限请求当作「提问」呈现，而不是当作「批准工具」：

- 所有选项的 kind 相同，例如 pi 的 select（全是 `allow_once`）。
- `toolCall.kind == "switch_mode"`，或者 `toolCall.rawInput.method` 是 `select`/`confirm`（pi UI 请求）。
- agent profile 提供的识别钩子判定为提问（阶段 5，例如 Claude 的 ExitPlanMode）。

呈现方式：

- 标题用 `toolCall.title`（"Ready to code?" 这类问题文本），正文显示 `toolCall.content` 的 markdown。
- 选项按 agent 给出的顺序排列，显示 `option.name`，不显示 kind。
- 不会被 `auto_allow` 自动回答；关闭时回 `cancelled`。

### 3.3 权限详情
- 权限 picker 增加详情区：
  - edit：显示 `toolCall.content` 里的 diff（复用 `ui/diff`）。
  - execute：显示完整命令（`rawInput.command`/`cmd`）和工作目录。
  - 其它：显示 `content` 文本或格式化后的 `rawInput`。
- 标题按 kind 生成（"Run command"、"Edit file"……），不再固定写 "Permission required"。
- transcript 里对应的 tool card 显示「等待批准」状态，并可以从卡片上直接打开权限窗口。

**测试**：schema 解析的单元测试（覆盖规范里的每种类型和 `_custom` 合并）；`ui/form` 的交互测试；
`@ask` 在 claude/opencode/pi 三个 profile 下都能回答，并断言 agent 收到的回复结构正确；
`@plan-approve` 选项顺序正确，关闭时回 `cancelled`；auto_allow 不会自动回答 pi 的 select。
**验收（M1）**：用真实的 Claude Code 和 OpenCode 手工验证：AskUserQuestion / question 工具能提问并收到答案；
ExitPlanMode 能看到计划正文并完成审批。

**状态**：已完成（**M1 未做**：没有在真实 Claude Code / OpenCode 上手工验证，见 §7）。
`elicitation.form` 默认开启；schema 解析拒绝嵌套对象与非 table 属性并回
`decline`；单字段选择简化为 picker，其余进入表单，`_custom` 同时支持「Other」和「选项 + 备注」。
`<C-s>` 提交、`q` 取消、`d` 拒绝；关闭表单窗口、取消/断线都由交互中心回 `cancel`，迟到回调
被忽略。提问型权限（`switch_mode`、pi select/confirm、或多个同 kind 选项）不再被 `auto_allow`
回答，标题优先取 `_meta.permission.title`，关闭时回 `cancelled`。权限详情是独立只读浮窗
（execute 命令与 cwd、edit diff、其它 content/rawInput），`permissions.show_details` 控制开关；
tool card 显示等待状态，`<CR>` 可直接重开请求。一致性套件中用客户端替身自动回 `cancel`，
真实表单交互由 controller/UI 测试覆盖。

---

## 阶段 4：认证

- **能力声明**：`auth = { terminal = true }`，以及 `_meta = { ["terminal-auth"] = true }`。
- **新增 `app/auth.lua`**：
  - 触发：`initialize` 后需要登录（例如 OpenCode 的 `authRequired`），或者 `session/new`、`session/prompt`
    返回 auth_required（按错误码判断，不再匹配字符串 "auth"）。
  - 只有一个登录方式时直接执行，有多个时用 picker 选择（显示 `name` 和 `description`）。
  - `type == "terminal"` 或带 `_meta["terminal-auth"]`：在一个新的 `:terminal` 分屏里运行
    agent 的命令（命令和参数来自方法本身，或者用当前 agent 配置的 `command` 加上方法给的 `args`/`env`）；
    终端退出后自动重连并重试刚才的操作。
  - `type == "agent"`（或没有 type）：调用 `authenticate(methodId)`，成功后重试。
- **新增 `:Acp login`**：手动触发登录；`:Acp logout` 仅在 agent 声明 `auth.logout` 时可用。
- 删除 `app/prompts.lua`、控制器中写死的 OpenCode 提示，改为显示 agent 给出的登录方式；
  完全没有提供登录方式时，提示查看 agent 文档。

**测试**：`@auth` 场景下三个 profile 的 terminal 方式（mock 的「登录命令」写一个标记文件后退出）；
agent 方式会调用 `authenticate`；登录后重试成功。
**验收**：首次使用 Claude Code 和 pi 时，可以在 Neovim 里完成登录。

**状态**：已完成。默认声明 `auth.terminal` 与 `_meta["terminal-auth"]`；新增 `app/auth`，
只按错误码 -32000 识别需要登录（客户端自造的失败改用 -32099，因此超时和崩溃不会误触发），
`session/new` / `session/load` / `session/prompt` 失败都会进入登录并在成功后重试。单一方式
直接执行，多个用 picker；terminal 类型在新 `:terminal` 分屏运行客户端自己配置的 agent 命令
（只采用方法给的 args/env，启动前展示），退出 0 后强制重启进程、恢复会话并重发失败的消息；
agent 类型调用 `authenticate`。连续失败最多重试 2 次后停止；`:Acp login` 重置计数。登录终端从
编辑器窗口切分（面板布局不变），放不下时改用新 tab。新增 `:Acp login` / `:Acp logout`（后者仅
在 agent 声明 `auth.logout` 时可用）。删除写死的 OpenCode 提示，无登录方式时提示查看 agent
文档；`health` 列出登录方式。顺带修复创建会话的 `creating`
守卫在任务被取消后永久卡住的问题，并声明 `session.configOptions.boolean`。mock 增加 `@auth`
场景与 `logout`。

---

## 阶段 5：agent profile 与规范化 controls（里程碑 M2）

### 5.1 预设与切换
- `config.agents` 增加内置预设（用户配置合并覆盖，不会替换掉用户已有的配置）：
  ```lua
  opencode = { command = "opencode", args = { "acp" }, profile = "opencode" },
  claude   = { command = "claude-agent-acp", args = {}, profile = "claude" },
  pi       = { command = "npx", args = { "-y", "@geohar/pi-acp" }, profile = "pi" },
  ```
  `profile` 省略时按 agent 名称推断，推断不出时使用 `generic`。
- 新增 `:Acp agent [name]`：切换 agent（关闭当前连接，用新 agent 连接；会话按 agent 分开记录）。
- `health.lua` 对每个已配置的 agent 检查可执行文件是否存在，并给出对应的安装提示。

### 5.2 profile 钩子（`lua/acp/agents/{generic,opencode,claude,pi}.lua`）
```lua
---@class AcpAgentProfile
---@field name string
---@field install_hint string
---@field classify_mode fun(control): "work"|"thinking"|nil   -- 模式是工作模式还是思考级别
---@field plan_mode fun(value_id): boolean                       -- 用于徽章样式
---@field unsafe_edit_mode fun(value_id): boolean                -- inline 使用（阶段 7）
---@field tool_name fun(tool_call): string|nil                   -- 如 _meta.claudeCode.toolName
---@field update_meta fun(update, session)|nil                   -- 读取专属 _meta（例如 opencode/*）
---@field is_question fun(permission_request): boolean|nil       -- 阶段 3.2 的扩展识别
---@field error_hint fun(err): string|nil
```
- OpenCode 的 `_meta` 解析（`session/reducer.lua`）移到 `agents/opencode.lua` 的 `update_meta`。
- 错误提示改为：先按错误码分类，再调用 profile 的 `error_hint`。
- 未知 agent 使用 `generic` profile：不做任何专属推断。

### 5.3 规范化的 controls
- `session/state` 新增派生字段 `controls`，在 configOptions、modes 或 `current_mode_update` 变化时重新计算：
  ```lua
  controls = {
    mode     = { id, current, options = {{id,name,description}}, source = "config"|"modes" } | nil,
    model    = {...} | nil,
    thinking = {...} | nil,    -- category thought_level，或者 profile 判定为思考级别的 modes（pi）
    extras   = { {id, name, type = "select"|"boolean", current, options} ... },
  }
  ```
- 有 configOptions 时优先使用（按 category 归类，其余放进 extras），**并完全忽略 `modes`**：
  pi 的 `modes` 只是 `thought_level` 配置项的重复表示。只有 `modes` 时才生成 mode，设置时调用 `session/set_mode`。
- 模式语义优先读选项的 `_meta.kind`（Claude：plan → 计划模式；full_access/auto_review → 不安全模式），
  没有时再用 profile 钩子。注意 Claude 的 acceptEdits 的 kind 是 standard，inline 的模式保护仍需 profile 判断。
- 修正 `session/state.lua`：从 `result.modes.currentModeId` 读取当前模式，`modes` 存的是
  `availableModes`。
- 处理 `current_mode_update`：同时更新 controls（对应 ExitPlanMode 之后的模式变化）。
- `app/options.lua` 按 control id 选择（不再按 category）；boolean 用开关切换；extras 用一个总的 picker。
- toolbar 只读取 controls：徽章样式由 `plan_mode` 判断（Claude 的 plan 模式也会显示为 plan 样式），
  思考级别单独显示一个小标记。
- 新增 `:Acp config`：打开 extras 和全部 controls 的 picker。

**测试**：三个 profile 的 controls 推导；切换走正确的方法（`set_config_option` 或 `set_mode`）；
`current_mode_update` 后徽章更新；boolean 配置项可以切换。
**验收（M2）**：用 pi 手工验证：模型和思考级别可以切换，提问可以回答，bash 输出可读（依赖阶段 6.1）。

**状态**：已完成（**M2 未做**：没有在真实 pi 上手工验证，见 §7；bash 输出依赖阶段 6.1，已完成）。
内置 `claude` / `pi` 预设并按 agent 名称推断
profile；新增 `agents` 模块承载模式语义、工具名、`_meta` 解析、提问识别、错误提示与安装提示，
OpenCode 的 `retry`/`compaction`/`child-session` 从 reducer 移出。新增 `session/controls`：
configOptions 优先并忽略重复的 `modes`，只有 `modes` 时按 profile 分出工作模式与思考级别，
模式语义先读 `_meta.kind`。修正 `modes.currentModeId` 层级与 `current_mode_update` 的 controls
刷新。`app/options` 按 control id 切换，boolean 直接翻转，`set_mode` 与 `set_config_option`
各走其源；新增 `:Acp config` 与 `:Acp agent [name]`，后者按 agent 分开保存会话标题与 cwd，
并在丢弃排队消息/打断回合时提示。工具栏按 value id 与 `plan` 语义着色，并显示思考级别。

---

## 阶段 6：呈现补全

1. **终端输出**：
   - 声明 `_meta.terminal_output = true`。
   - tool card 渲染 `_meta.terminal_info`、`terminal_output`、`terminal_output_delta`（追加）和 `terminal_exit`（退出码）。
   - terminal content 对应的 terminal 不是客户端创建的（例如 pi）时，回退到 `_meta` 输出或文本，
     不再只显示 "terminal: id"。
2. **tool card**：
   - `rawOutput` 在没有其它 content 时显示（不再只在 failed 时显示）。
   - 显示 tool content 里的 resource / resource_link。
   - 工具名称优先用 profile 的 `tool_name`；去掉标题两侧的反引号；补充 Claude MultiEdit `edits[]` 的 diff 还原。
3. **plan**：同一回合内复用已有的 plan 块，修正 `session/reducer.lua` 遇到 agent 文本就停止查找的问题；
   显示 `priority`。
4. **停止原因**：`max_tokens`、`max_turn_requests`、`refusal` 在 transcript 末尾显示一条说明。
5. **其它**：显示 usage 的 `cost`；使用 `session_info_update.updatedAt`；音频 content 显示为 `[audio]` 占位；
   `notice` 的块 id 改用单调计数器。

**测试**：`@bash`（pi 和 claude 两种形式）；rawOutput；plan 去重；停止原因的渲染。

**状态**：已完成。声明 `_meta.terminal_output`；reducer 解析 `terminal_info`/`terminal_output`/
`terminal_output_delta`/`terminal_exit` 并在卡片里显示输出与退出码，`terminal` content 不再
退化成 `terminal: <id>`。折叠卡片在 header 提示隐藏行数与退出码（`done · 2 lines · exit 2`），
`execute` 不再「跑完却完全看不到输出」。`rawOutput` 在无其它 content 时显示，
`resource`/`resource_link` 有摘要，标题去反引号，`edits[]` 逐条还原 diff。plan 以 turn 号为界
复用同一块并显示 `priority`。`max_tokens`/`max_turn_requests`/`refusal` 追加一条 notice。
工具栏显示 usage cost，记录 `updatedAt`，音频显示 `[audio]`，notice 块 id 改为单调计数器。

---

## 阶段 7：inline 安全与提问（里程碑 M3）

1. **防止 agent 直接改原文件**：
   - 提交时记录源文件在磁盘上的状态（mtime、大小、内容 hash）。
   - 回合结束时再检查一次。如果原文件被改动：中止应用，提示「agent 直接修改了原文件」，
     并提供选项：打开 diff（磁盘内容 vs buffer）、重新加载、保留 buffer。
2. **工作模式保护**（需要确认的决策，见 §6）：
   - 推荐做法：开始前通过 profile 的 `unsafe_edit_mode` 判断当前模式。如果是不安全的模式
     （Claude 的 acceptEdits/bypassPermissions/auto；OpenCode 的 edit 权限为 allow 时无法从 ACP 得知，
     只能依赖第 1 点兜底），提示用户并提供「临时切换到 default，结束后切回」或「仍然继续」。
   - pi 没有执行前权限：始终依赖第 1 点兜底，并在第一次使用时提示一次。
3. **提问交给用户**：inline 策略不再自动拒绝提问。
   - elicitation 和提问型权限请求都交给呈现器，由用户回答。
   - 有待回答的问题时，private copy 和 inline 预留不释放，直到这一轮真正结束。
4. **收窄 `allow_commands`**：只对 `execute` 生效；`delete`、`move`、未知 kind 一律拒绝，
   需要时用新的配置项 `inline.allow_kinds` 显式放开。
5. **默认 copy 位置**：评估把默认值从同目录隐藏文件改为 state 目录。同目录副本会被格式化工具、LSP、
   文件监听、git status 看到。代价是 agent 可能无法通过相对路径找到项目上下文，所以先保留可配置，
   默认值在手工验证后再决定。
6. **transcript 噪音**：inline 的 prompt 在聊天记录中折叠显示（只显示「inline: 请求摘要」），
   完整内容可以展开。

**测试**：mock 直接写原文件的场景会被检测到；inline 回合中的 `@ask` 能交给用户回答；
不安全模式会触发提示；`allow_commands` 的新范围。
**验收（M3）**：在三个 agent 上手工跑一遍 inline 编辑，包括 agent 先提问再改文件的情况。

**状态**：已完成（**M3 未做**：没有在三个真实 agent 上跑过 inline，见 §7）。新增 `inline/guard`：提交时记录源文件
mtime/大小/hash，回合结束后比对，直接写入时中止应用并提供重载/保留/查看差异。新增
`inline.guard_mode`（默认 `ask`，另有 `switch`、`off`），按 profile 的 `unsafe_edit_mode`
判定当前模式；`switch` 只切到语义中立的模式，不会切进 plan。inline 策略不再回答
elicitation 与提问型权限。`allow_commands` 收窄到 `execute`，其余 kind 需 `allow_kinds`
显式放开。inline prompt 在 transcript 中折叠为摘要，agent 回放消息时摘要自动失效。
私有副本默认仍是同目录隐藏文件。

---

## 阶段 8：会话管理与上下文补全

1. `session/list` 跟随 `nextCursor` 翻页（会话 picker 采用懒加载，标题查找翻完所有页）。
2. `session/resume`：agent 不支持 `loadSession` 但支持 `resume` 时，用 resume 恢复会话（不回放历史，
   只提示「已恢复」）。
3. `session/close`：切换或删除本地会话、退出 Neovim 时，对支持 close 的 agent 发送 close。
4. `Sessions:load` 加上 `loadSession` 能力检查。
5. `mcpServers` 配置：`config.mcp_servers`（stdio/http/sse），按 `mcpCapabilities` 过滤后传给 `session/new` / `session/load`。
6. **上下文**：
   - 不支持 `embeddedContext` 时，选区发 `resource_link` 加一个包含选中文本的 text 块。
   - 未保存的 buffer 在不支持 `embeddedContext` 时同样改用 text 块。
   - 剪贴板图片在 agent 不支持图片时，退化为保存成文件后发 `resource_link`。
   - 能力在发送时检查，而不是在附加时检查。
7. cwd 去掉末尾的 `/`（`resolve_cwd`）。
8. （可选）实现 `fs/read_text_file` / `fs/write_text_file`：读写 Neovim buffer，写入要经过交互中心确认。
   三个主力 agent 都不使用，只对通用 agent 有价值，排在最后，并由配置开关控制。
9. （可选）实现 `terminal/*`：Neovim 的 job 加只读输出 buffer。同上，由配置开关控制，排在最后。

**状态**：已完成（8、9 两项可选项未实现，保持关闭）。`session/list` 跟随 `nextCursor`
翻到最后一页（上限 100 页，遇到重复 cursor 即停），回退到不限目录时游标从头开始。
`Sessions:load` 与 `restore` 先查 `loadSession`：不支持但有 `resume` 时走新增的
`Sessions:resume`，只恢复 agent 端上下文、不回放历史，并明确提示「history is not
replayed」；两者都不支持才新建会话。`session/close` 在切换会话、删除会话与退出编辑器
（`close_all_on_exit`，同步 `vim.wait` 等待响应）三条路径发送，仅当 agent 声明
`sessionCapabilities.close` 且 client 真正实现了该方法时才发；切换离开仍在运行的会话
不会 close，避免打断用户留在后台的回合。`config.mcp_servers`
支持 stdio/http/sse，`Client:mcp_servers()` 按 `mcpCapabilities` 过滤后传给
`session/new`、`session/load`、`session/resume`。图片在 agent 不支持
`promptCapabilities.image` 时于编码前降级为 `resource_link`（不再读取字节），
移除发送前的直接拒绝。cwd 去掉末尾 `/`（保留根目录的 `/`）。

上下文块改为**发送时构建**（`context.block`），不再在附加时定型：未保存的 buffer 与
Visual 选区在 agent 声明 `embeddedContext` 时发 `resource`，否则发 `resource_link` +
一个携带同样文本的 `text` 块。这同时修复了两个缺陷——此前非 `embeddedContext` 的选区
只发链接、选中文本从不进入 prompt（pi 就是这种 agent），而不支持 `embeddedContext` 的
agent 仍会收到未声明的 `resource` 块。附带收益：`storage/drafts` 保存时会剥掉 `block`，
旧实现在草稿恢复后把这些附件**静默丢弃**；现在发送时重新构建，附件不再丢失。

过程中发现并修正一个真实缺陷：`capabilities.agent` 原先对「client 实现了
`load_session`」一律视为支持，而真实 client 总是实现该方法，导致显式声明
`loadSession: false` 的 agent 被误判为可加载。现在只在无法上报能力的轻量 double 上
做这种推断。

验证：1106 项单元/组件测试通过（阶段 8 新增 28 项，覆盖分页、mcp 过滤、图片降级、
能力探测、resume 回退、close 三条路径，以及上下文块在两种 `embeddedContext` 下的形态
与草稿恢复）。mock 新增 `resumeonly` profile、`session/resume` 与 `session/close` 处理、
`ACP_MOCK_CLOSE_LOG`。未在真实 agent 上手工验收（不单独设里程碑，随 M1–M3 覆盖）。

---

## 阶段 9：架构收尾

计划原本想把每个步骤摊到前面的阶段里顺手做，实际没有做到：阶段 1–8 各自只改了自己的
功能，架构收尾是一次性完成的（见下方「状态」）。下表保留当初的分工设想。

| 步骤 | 内容 | 建议在哪个阶段一并完成 |
|---|---|---|
| 9.1 | 事件分发表：`controller.on_client_event` 的 if 链改为 `handlers[name]`，各领域服务自行注册 | 阶段 2 |
| 9.2 | `protocol/client` 不再 require `ui.work_scheduler`，调度器由连接服务注入 | 阶段 1 |
| 9.3 | inline 依赖注入：`inline.setup({ state = getter, send = fn, interactions = ... })`，删除对 controller 的反向 require | 阶段 7 |
| 9.4 | `app/*` 通过呈现器接口调用 UI（permissions、options、sessions 不再直接 require picker） | 阶段 2、5 |
| 9.5 | 全局表 `S` 拆成三部分：连接 store（client、connection、generation）、会话 store（runtime、current session、titles、cwds）、视图 store（chat、input、panel、chrome）；外部只能通过访问函数读取 | 阶段 5 之后 |
| 9.6 | `health` 通过 `config` 模块读取配置，不再 require controller | 阶段 5 |
| 9.7 | 更新 `docs/architecture.md`、`docs/status.md` | 每个阶段结束时 |

**验收（M4）**：没有循环 require（加一个测试：遍历模块的 require 图，断言没有环）；
protocol 和 session 两层不 require `ui/*`；controller 不超过 700 行（预算由测试守护）。

**状态**：已完成，验收条件全部由 `tests/spec_architecture.lua` 守护（15 项，含 controller 行数预算）。

- 9.1 已完成：`app/events` 是事件分发表（`handlers[name]`），`dispatch` 忽略未知事件，
  `register` 允许服务或测试替换单个处理器。controller 的 `on_client_event` 只剩一次转发。
- 9.2 已完成：`protocol/*` 与 `session/*` 都不 require `acp.ui*`；调度器由连接服务注入。
- 9.3 已完成：`acp.inline.setup({ state, send, is_question })` 注入三个钩子，inline 不再 require
  controller；`presenter.select` / `presenter.diff_lines` 取代对 `ui.picker`、`ui.diff` 的直接依赖。
- 9.4 已完成：`app/presenter` 是 `app/*` 访问 UI 的唯一入口（picker、form、权限详情、会话浏览器、
  图标、diff）。它按调用时 require，因此测试替换 `acp.ui.picker.select` 等仍然生效。
- 9.5 已完成，按「真拆」执行：`app/stores` 把状态拆成 `connection` / `session` / `view` 三张
  真实表，字段按语义命名（`session.current`、`connection.phase`），`config` 留在顶层。扁平名
  （`state.session`、`state.chat`）只是 metatable 提供的兼容视图，`rawget` 读不到；`controller.stores()`
  返回三张表。controller、`app/*`、`tasks` 与全部测试都改为显式 store 路径（685 处）。
- 9.6 已完成：`config.remember()` / `config.effective()` 保存并读取最近一次有效配置；
  `health` 只在需要运行时事实（活动 client 的登录方法）时才访问 controller。
- 9.7 已完成：`docs/architecture.md` 与 `docs/status.md` 已更新。

controller 拆到 599 行（现在约 640 行，见下面的行数预算说明）。拆出的职责：

| 新模块 | 原职责 |
|---|---|
| `app/bootstrap` | 服务构造与接线（原先 ~550 行的 `setup`） |
| `app/turn` | 提交、取消、系统块 |
| `app/window` | 窗口事件、keymap、`activate_session`、panel open/hide/focus |
| `app/status` | statusline、winbar、动画同步 |
| `app/attachments` | 图片 / 文件 / 选区 / 诊断 / 打开位置 |
| `app/runtime_ops` | outbox 派发、LRU 清理、cwd 解析、`ui_current`、`debug_state` |
| `app/connection_flow` | 登录后重发、agent 切换 |
| `app/events` | client 事件分发 |
| `app/presenter` | `app/*` → UI 的单向出口 |

当时的行数目标写成「少于 600」，但没有任何测试断言它——那个数字只是文档承诺。
后来托管安装又加了几个入口，实际到达约 640 行。现在预算是 700 行，**由
`tests/spec_architecture.lua` 实际断言**，超出时报错并提示把功能移进 `app/*`。
不再为凑行数把代码写成难以阅读的元编程。

验证：1101 项单元/组件测试通过，0 失败，0 项 pending（阶段 9 新增 14 项架构门禁与状态存储测试）。
`tests/integration_inline_safety.lua` 3 项通过。后续修复上下文块时又加了 5 项，当前总量见 §4。

---

## 3. 新增与变更的配置项

实际默认值（与实现一致）：

```lua
{
  agents = {                     -- 新增内置预设：claude、pi（用户配置合并覆盖）
    claude = { command = "claude-agent-acp", args = {}, profile = "claude" },
    pi     = { command = "npx", args = { "-y", "pi-acp" }, profile = "pi" },
  },
  capabilities = {               -- 新增：每项能力都可以单独关闭，用于排查问题
    elicitation = { form = true, url = false },
    auth_terminal = true,
    terminal_output_meta = true,
    boolean_config_options = true,  -- 声明 session.configOptions.boolean
    fs = false,                  -- 保留开关，但没有实现（见 §6 决策 3）
    terminal = false,            -- 同上
  },
  transport = {
    timeouts = { initialize = 120000, session_new = 60000, session_load = 120000 },  -- 新增
  },
  mcp_servers = {},              -- 新增：stdio/http/sse，按 mcpCapabilities 过滤后下发
  permissions = {
    prompt = "select",           -- 不变
    auto_allow = {},             -- 不变；但不再作用于提问型请求
    show_details = true,         -- 新增：权限窗口显示 diff / 命令
  },
  inline = {
    allow_commands = false,      -- 含义收窄：只对 execute 生效
    allow_kinds = {},            -- 新增：显式放开其它 kind
    guard_mode = "ask",          -- 新增："ask" | "switch" | "off"（见 §6 决策 1）
    copy_dir = "sibling",        -- "sibling" | "state"（见 §6 决策 2）
  },
}
```

旧配置项的含义都没有改变；`auto_allow` 是唯一一处行为收窄（不再回答提问型请求），
这种请求本来也不该被静默批准。

## 4. 测试策略

| 层次 | 内容 | 现状 |
|---|---|---|
| 单元 | schema 解析、controls 推导、能力查询、交互中心的生命周期（只回复一次、取消、过期）、profile 钩子 | 已实现 |
| 一致性 | 4 个 mock profile × 标准流程（initialize/new/prompt/cancel/load/auth），断言没有 -32601、没有重复回复、没有丢弃更新 | 已实现，0 项 pending |
| 场景 | `@ask`、`@plan-approve`、`@null`、`@bash`、`@auth`、`@cancel-request`、`@early-update` | 已实现 |
| UI 集成 | 现有 pynvim 测试，加上表单窗口、权限详情、终端输出的屏幕断言 | 已实现，见 `tests/integration_*.lua`（`integration_inline.lua` 依赖交互式权限选择，headless 下不稳定，不作门禁） |
| 结构 | require 图没有环；protocol/session 不依赖 ui | 已实现，由 `tests/spec_architecture.lua` 守护 |
| 手工 | 每个里程碑用真实 agent 验证（清单见 §7） | **未做** |

当前自动化总量：1106 项单元/组件测试，0 失败，0 pending；另有 inline 安全集成 3 项。

## 5. 风险

- **上游变化快**：claude-agent-acp 两周就发一个版本；pi-acp 是第三方维护，并且有多个 fork。
  应对：只依赖规范行为加 profile 钩子；mock 场景直接取自上游源码；在 profile 文件头部记录
  对应的上游版本号。**现状**：已按此实现，但没有持续跟踪上游变化的机制，升级后仍需人工复核
  一次协议日志。
- **未核实的信息（至今仍未核实）**：OpenCode 是否发 `plan` 更新、有没有计划审批流程；
  Claude ExitPlanMode 的 tool kind 是否稳定；Claude 在 `authMethods` 为空时能否使用环境变量中
  的 API key。这三条目前按「上游源码 + 录制的协议场景」推定实现，没有真实握手确认。
  确认方法见 §7。
- **交互中心迁移时权限行为回退**：应对：阶段 2 只做行为不变的迁移；现有权限测试必须全部通过
  才能合并。**结果**：已按此执行，原有权限测试全部保留并通过。
- **inline 模式保护会改动用户的 session 状态**：见 §6 决策 1，默认只提示、不自动切换。
  **结果**：默认 `"ask"`，`"switch"` 也不会切进 plan。

## 6. 决策记录

实施时定案的结论，以及仍未定的事：

1. **inline 遇到不安全的工作模式时怎么办** — **已定案**：默认 `"ask"`（提示用户，可选择
   临时切换或继续）。另有 `"switch"`（自动临时切到语义中立的模式，结束后切回；**不会**切进
   plan）与 `"off"`（只依赖磁盘变更检测兜底）。
2. **inline private copy 的默认位置** — **已定案**：保持同目录隐藏文件（`copy_dir = "sibling"`），
   同时提供 `copy_dir = "state"`。同目录副本让 agent 能通过相对路径找到项目上下文，代价是会被
   格式化工具、LSP 与 git status 看到。这一项**没有**经过真实 agent 的手工对比验证，只是维持现状。
3. **fs/terminal 客户端能力是否实现** — **已定案**：不实现。`capabilities.fs` 与
   `capabilities.terminal` 保留为 `false` 且没有对应实现，三个主力 agent 都用不到。
4. **elicitation url 模式** — **已定案**：实现但默认关闭（`elicitation.url = false`，主要用于
   MCP OAuth）。`elicitation/complete` 到达时关闭提示。
5. **会话按 agent 分开记录** — **已定案**：分开。切换 agent 后只显示当前 agent 的会话，
   标题与 cwd 缓存也按 agent 分开保存（`agent_store`）。

## 7. 手工验证清单（未完成）

> **状态：一项都还没做。** 所有自动化门禁（1106 项单元/组件测试、架构门禁、inline 安全集成）
> 都通过，但它们跑的是 mock agent。下面的清单需要在真实 agent 上手动跑一遍，才能认为
> 里程碑 M1–M4 真正达成。这个缺口在各阶段的状态段里也逐条提到过。

前置条件：装好对应的 agent（`opencode`、`claude-agent-acp`、`pi-acp`），用
`log.protocol = true` 记录一次协议日志，便于对照实际报文。

- [ ] **OpenCode**：提问（question 工具）、权限详情（diff、命令）、模型/思考级别/模式切换、
  会话 list/load/resume、inline 编辑。
- [ ] **Claude Code**：首次登录、AskUserQuestion（单选、多选、Other）、ExitPlanMode 审批与之后的
  模式徽章、acceptEdits 下的 inline 模式保护、TodoWrite 的 plan 不叠加、Bash 输出。
- [ ] **pi**：首次登录、思考级别切换、select/confirm 提问、bash 伪终端输出、inline 时直接写文件
  被检测到；**以及 `embeddedContext: false` 下的选区与未保存 buffer**（pi 不声明该能力，
  应该走「链接 + 文本块」路径）。
- [ ] **generic**（Gemini CLI 或 Codex adapter 任选一个）：基本对话、权限、未知更新类型不报错。

配套要确认的三条（§5 「未核实的信息」至今没有结论）：

- [ ] OpenCode 是否发 `plan` 更新、有没有计划审批流程。
- [ ] Claude ExitPlanMode 的 tool kind 是否稳定为 `switch_mode`（当前的提问识别依赖它）。
- [ ] Claude 在 `authMethods` 为空时能否使用环境变量中的 API key。

做完后请把结论写回对应阶段的状态段，并勾选这里的条目。
