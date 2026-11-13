# 当前状态与检查记录

检查日期：2026-11-09。本文是本轮检查的快照，不替代 README 和 `:help acp.nvim`。
后续更新：2026-11-11，见文末运行时、界面与补全改造记录。

## 检查范围

- 配置默认值与校验、公开命令、按键和示例配置。
- 原生布局、单窗口恢复、外部布局接口、窗口保护和工具栏。
- 会话历史重放、请求超时、stderr 保留与日志状态。
- 渲染、高亮、Markdown、代码块、表格、工具卡片和思考块的现有测试。
- README、帮助文件、健康检查中的集成说明与当前代码的对应关系。

## 本轮修正

| 问题 | 修正 |
|---|---|
| 重复加载缓存会话会追加相同历史 | 每次加载重建会话记录；拒绝重叠重放和重载运行中的目标会话 |
| 默认 `mouse="nvi"` 被误报为无法点击 | 按模式标志判断；文档明确不要求包含 `a` |
| 0.10/0.11 不认识 `%$group$` 高亮语法 | 旧版本回退到 `%#group#`，0.12+ 保留继承背景语法 |
| 未知模式中的 `%` 被转义两次 | 在最终输出时统一转义 |
| 超长模式徽标导致极窄工具栏溢出 | 空间不足时移除徽标，优先保留状态 |
| 单独恢复输入框尺寸不稳定、恢复聊天框产生独立列 | 在同一列重建缺失视图并应用原生布局尺寸 |
| 第二次分屏失败留下窗口 | 回滚第一次分屏并恢复 `equalalways` |
| 输入框忽略自定义关闭快捷键 | 与聊天框一致使用 `keymaps.close_panel` |
| `request_timeout=0` 仍启用默认超时 | 明确禁用超时；同步响应不再创建无用计时器 |
| `stderr_keep_bytes=0` 仍保留全部 stderr | 明确保留空字符串 |
| 非数字宽度边界产生原始 Lua 错误 | 先做类型与范围校验 |
| 日志计数器初始化污染全局变量 | 使用同一局部计数器 |
| 内置会话浏览器的字符映射覆盖导航/关闭键 | 控制映射优先，支持大写字符过滤 |
| 浮窗删除确认导致浏览器提前关闭 | 确认期间保留浏览器 |
| 两个示例使用无效 Lua 注释，且有废弃配置 | 改为合法注释并移除 `ui.language` |
| 健康检查建议把具名视图表直接赋给 edgy | 改用 `extend(opts)` |

## 文档对齐

明确原生布局为默认、edgy/snacks 为可选依赖；普通选择器和会话浏览器使用不同配置。
更新模式徽标、状态图标、无下拉箭头、仅显示模型名、思考块折叠、高亮覆盖生命周期、
尺寸上限、Tree-sitter 可选依赖及完整测试命令。`views()` 返回具名表，不可直接作为
edgy 的数组列表。

## 验证与边界

| 检查 | 结果 |
|---|---|
| 单元/组件测试 | 385 通过，0 失败（本轮新增 15 项） |
| 界面、edgy、重连集成 | 全部通过 |
| 性能回归 | 通过 |
| StyLua（含 examples）与 git diff --check | 通过 |

自动化检查使用本机 Neovim v0.13.0-dev，Agent 通信测试使用仓库 mock agent。
旧版工具栏语法分支有模拟版本回归测试，并对照了 Neovim 0.10/0.11/0.12 的官方
选项文档；本轮未在真实 0.10/0.11 可执行文件上运行完整测试。

本轮未发送真实 OpenCode 模型请求，也不把字符串中的点击标记视为终端鼠标交互已验证。
实际终端鼠标转发、第三方布局组合和具体主题仍需用户环境实测。

已知能力边界仍包括：不实现客户端 `fs/*`/`terminal/*`、不提供逐块接受/拒绝修改、
会话列表和扩展信息依赖 Agent 能力、Markdown 渲染不等同于完整 Markdown 引擎。

## 后续性能优化（同日）

按「解析缓存/协议长度 → 内存预算/LRU → 变更范围渲染 → 背景/事件/表格/I/O」顺序完成：

- 闭合代码块复用语法区间，窗口宽度不再使语法分析缓存失效；全局缓存按条目与估算字节
  双重限制，主题变化失效。超大代码块降级，限制语法捕获数量。
- 完整协议行在分配/JSON 解码前检查大小。待分发队列有预算，按时间片有序处理；
  进程退出通知等待已收消息分发完成，显式停止则丢弃待分发消息。
- 会话使用载荷字节预算；闲置会话按 LRU 淘汰，当前/运行中/有队列或权限请求的会话
  受保护。队列超限保留当前输入，内存草稿数量受限。截断与历史裁剪都有可见提示。
- 控制器启用 block revision 与 256 项变更日志。稳定前缀复用文本、逐行 metadata 与
  extmark，只重新构建变化块及受影响后缀；日志落后或布局/主题变化有安全完整路径。
- 背景复用编辑后的实际 extmark 范围；chrome 刷新合并，状态更新不重拼工具输出；
  表格列宽改用二分水位分配，不按超长单元格的字符宽度逐格收缩。
- 草稿缓存读取、150ms 合并保存、异步写入和原子 rename，退出时同步 flush。

新增性能回归覆盖缓存命中/淘汰、预算、队列拒绝、LRU 保护、流式/折叠/裁剪与完整渲染
等价性（含高亮与背景）、日志回绕、后台分发顺序、异步确认及草稿落盘。

验证：400 项测试通过；界面、edgy、重连、性能回归全部通过。性能脚本新增 21,000 行
历史下的空渲染和尾部更新 P95 场景。一次本机 headless 测量中，原 200 次流式更新
由约 183ms 降至约 19ms；21,000 行历史的尾部更新 P95 约 0.3ms。

边界：字节预算不等于 RSS 硬上限，受保护会话可暂时超出缓存总预算；当前变化消息
仍物化完整文本，含 fence 时仍重新排版。时间片不能抢占单条 JSON 解码或单块排版；
草稿 JSON 编解码仍在主线程执行，首次读取/退出 flush 也可能同步等待。

## 运行时一致性改造（2026-11-10）

先用可控异步桩复现了草稿归属错误、后台队列停滞后被历史替换覆盖、旧创建结果污染新
配置、后台错误进入前台会话、发送失败不结算和挂起后局部错误处理失效，再增加对应回归。

按数据保护 → 任务生命周期 → 会话运行时拆分 → 修改/调度边界的顺序完成：

- 草稿显式携带项目和会话身份，支持附件-only 草稿；接受消息后只清理来源草稿，即使
  发送期间发生 UI 重入，也不清空另一个会话的输入。
- `session/runtime.lua` 管理稳定 outbox、发送预留、历史 stage/commit/rollback 和 LRU。
  历史投影与 outbox 分离；后台回合推进不依赖前台选择。失败加载保留旧数据与队列。
- `tasks.lua` 绑定控制器代际、client 及其代际、session 和操作 key/id；所有会话级请求
  在挂起前后验证身份。删除、断连、重配置取消旧任务，迟到结果/旧 UI 选择器不修改新状态。
- `async.lua` 在所有 resume 阶段处理局部异常，支持取消和 await 清理；RPC pending 和
  timer 随任务释放。初始化调用者等待同一真实结果，不提前成功；写入失败立即结算，
  残缺协议行后关闭传输，不继续拼接新请求。
- 只有 prompt task 结算其回合与队列；兼容事件不重复结算。普通通知在传输批次内直接
  归约，权限 UI 单独调度；exit 延后，以便先运行已结算的 RPC continuation。
- UI/控制器语义修改使用模型入口。重新打开死连接也创建新 client，避免复用旧事件绑定。

安全行为变更：队列非空时拒绝重新 setup；显式第二参数 `{discard_queued = true}`
才表示同意丢弃。队列仍是进程内状态，不保证重启恢复；已发请求不自动重发，不宣称
远端工具 exactly-once 执行。共享草稿文件仍没有跨 Neovim 进程事务锁。

当前架构与不变量详见 [architecture.md](architecture.md)。验证覆盖重入发送、任务取消、
旧清理不能释放新锁、事务回滚、恢复队列、后台删除、陈旧选择器、初始化等待者、同步
发送失败与部分写入失败。完整自动化使用 mock Agent，并非真实远端副作用验证。

最终验证：433 项测试通过（本阶段新增 33 项）；界面、edgy、重连、性能回归、StyLua
和 `git diff --check` 全部通过。最初的临时复现探针也确认草稿归属正确、旧结果不被接纳、
后台错误不进入新会话，后台队列能够推进。

## 模块拆分（2026-11-10）

按「低风险展示逻辑 → 文本与卡片 → 权限/选项 → 面板与 chrome → 会话/目录 →
prompts/连接 → 转录内核」的顺序拆分，未改变公开 API、配置、按键和异步语义。

| 模块 | 职责 |
|---|---|
| `app/connection.lua` | client 创建、启动结果接纳、断连与重连 |
| `app/sessions.lua` | 创建、加载、恢复、删除与会话浏览流程 |
| `app/catalog.lua` | `session/list`、标题与 cwd 缓存、标题刷新合并 |
| `app/prompts.lua` | 发送校验、`@file` 展开、本地队列与回合结算 |
| `app/permissions.lua` | 权限请求登记、自动放行、选择器与拒绝策略 |
| `app/options.lua` | 模型、模式与其它配置选择 |
| `ui/presenter.lua` | 工具栏与状态展示数据 |
| `ui/keymaps.lua` | 两个视图的 buffer-local 映射与补全挂载 |
| `ui/chrome.lua` | winbar、动画计时器与刷新合并 |
| `ui/panel.lua` | 视图/窗口创建、隐藏、聚焦与窗口事件 |
| `ui/text.lua` | Markdown 行、围栏、表格与流式排版 |
| `ui/blocks/*` | 消息、工具卡片、计划/通知/错误组件 |
| `ui/transcript.lua` | block → 行、元数据、位置映射与渲染缓存 |
| `ui/buffer_renderer.lua` | 行差异写入、内联高亮与背景 extmark |
| `ui/windows.lua` | 帮助浮窗与日志打开 |

保留的兼容入口：`acp.ui.blocks.render_block`、`render_text`、`indent_lines` 等仍是
块渲染与文本排版的公开入口。`controller.state()` 继续作为诊断视图，测试写入的
`titles`、`session_cwds`、`pending_permissions` 由服务通过 getter 读取。

验证：446 项单元测试通过（新增 13 项模块测试）；界面、edgy、重连、性能回归与
StyLua 全部通过。拆分未在真实 OpenCode 会话上重新验证远端副作用。

## 动画与拆分回归修复（2026-11-10）

后续定向探针发现，原测试未覆盖以下边界：生成中隐藏后重开动画不恢复（拆分前即存在）、
可见面板重复 open 重新绑定快捷键、断连取消标题查询后合并锁未释放、setup 未清空元信息
缓存，以及选区附件映射遗漏 `>`。本轮已修复，并增加对应测试。

- 动画按连接 ready、当前会话 running、输入视图可见且工具栏启用同步启停；隐藏重开和
  输入窗口恢复均能重新启动，重复 open 不重复创建 timer。
- 映射与补全移至 buffer 初始化；重复 open、隐藏重开和修复窗口不再重绑，恢复 `<C-]>`。
- 操作 scope 失效时同步重置 Catalog 的标题查询锁及合并请求；setup 创建全新标题/cwd 表。
- 销毁 chrome/panel 后丢弃旧实例的延迟刷新，释放 panel 的 autocmd group。

验证：456 项单元测试通过（新增 10 项）；界面、edgy、重连、性能脚本、StyLua 与
`git diff --check` 通过。9 轮同机对照中，200 次可见面板 open 的中位总耗时从修复前
约 33.7ms 降至约 0.12ms，ACP 映射重复安装次数归零。

边界：本轮不改变同步文本/代码排版机制；主线程处理大块内容时仍可能短暂掉帧。
自动化使用 mock Agent，未重新发送真实 OpenCode 请求或验证终端实际动画效果。

## 表格布局与流式缓存修复（2026-11-10）

- 单元格在测量前剥离 Markdown 标记，按可见文本计算自然列宽；代码、强调和链接高亮
  通过源字节边界映射到可见文本，再按实际换行切片调整坐标。表格不再二次 conceal，
  避免隐藏正常文字/边框以及将单元格高亮错误延伸到边框。
- 竖向边框使用独立的 `AcpTableBorder` 区间，不再以边框颜色覆盖整行单元格；保持
  水平边框与竖向边框一致，中文、emoji、行内代码与换行后的列边界对齐。
- 流式缓存只提交稳定前缀。尚未闭合的表格从首行重新排版，保留表头及已收到的全部
  行；表格闭合后的正文继续复用已有表格，不强制重新排版整条消息。

新增 9 项回归测试，覆盖边框坐标/高亮、可见列宽、换行后的行内样式、逐字符及逐行
追加、中英混排和多个表格、闭合表格缓存复用，以及完整/增量转录文本、元数据和
extmark 一致性。验证：465 项单元测试、界面、edgy、重连及性能回归全部通过。

## 聊天窗口尺寸变化重排（2026-11-10）

- Chat 同时监听 `WinResized` 与 `VimResized`，比较自身实际宽度以过滤无关事件；
  连续宽度变化采用 100ms 防抖。同一待处理宽度的重复事件不推迟已排队的刷新。
- 流式内容保留 40ms 调度，在拖动期间按上次稳定宽度更新；尺寸稳定后按最新内容重排。
  高度变化仅维护视口/跟随状态，不重建内容布局。
- 布局更新与内容更新分开：保留历史阅读的 block/行偏移锚点和视口，不误报新消息；
  已存在的新消息标记及同时收到的真实更新不会被布局刷新清除。
- 关闭窗口、切换会话和销毁视图会取消旧 resize；销毁时同时释放内容刷新 timer，
  避免已排队的旧回调访问新视图。隐藏后重新打开仍按实际宽度渲染。

新增 13 项 resize 回归测试；总计 478 项单元测试通过。原生布局和 edgy 集成新增
空闲会话调宽检查，界面、edgy、重连、性能与格式检查通过。无附加 UI 的集成测试
显式分发 resize 事件；另用附加 RPC UI 的临时探针验证真实 `WinResized` 自动重排，
65→36 列时表格从 7 行重排为 9 行。未在用户的实际终端/主题环境手动拖动验证。

## 历史回放接收链与诊断（2026-11-10）

针对大规模 `session/load` 回放触发 `max_pending_bytes`：

- 接收回调不再先把整批数据 `table.concat` 成一个字符串，而是逐行元素解帧；避免整批
  复制，并让分发能在输入行之间进行。
- 接收与分发共享 `dispatch_budget_ms`。估算积压超过预算一半时，回调内会同步消费；
  因此一次超过预算的 stdout 读取仍可处理，队列高水位约为上限一半。单条消息仍受
  `max_line_bytes` 约束。
- `max_pending_bytes` 现在统一统计未解帧输入、不完整消息、待分发消息及队列开销；超限
  仍断开并走既有暂存回滚。
- 新增低开销诊断：回调/消息/字节计数、最大输入与最大消息、积压高水位、批次与最慢行
  耗时、回放阶段标记。超限摘要不含正文；`log.protocol` 记录逐回调明细。
  `:AcpDebug` 也暴露传输统计。

可控测量：24 MiB、60,000 行的单次回调在 16 MiB 预算下完成，积压峰值约 8 MiB、耗时约
27ms；慢于预算的处理器仍会在硬上限处断开。新增 8 项传输限制测试和 1 项单行上限回归；
569 项单元测试、界面、edgy、重连、性能回归和格式检查通过。

边界：这不是操作系统管道背压，积压超过硬上限仍会断开；单条解码/归约不可抢占。
大突发下主循环可被持续占用至该批结束。真实 Agent 与终端环境仍需实测。

阶段 5（管道背压）评估结论：测量显示单次回调超限已可在既有 `jobstart` 传输内完成，
暂不迁移到自行管理 `uv.spawn`。仍保留的边界是：总积压超过硬上限、或处理速度持续低于
输入速度时断开；若后续真实回放仍在远低于上限处失败，再以独立原型评估高/低水位暂停
stdout 与死锁风险。

## 无总积压上限与 spool（2026-11-10）

- `max_pending_bytes = 0` 表示不因总积压断开；仍按输入行共享分发预算，避免只进不出。
  16/64/256/1024 MiB 各告警一次，`:AcpDebug` 暴露峰值与落盘状态。
- 新增 `transport.spill_bytes`（默认 64 MiB）：超过水位把最早的已解码消息写入
  `stdpath("run")/acp.nvim/acp-spill-*`（0600），内存降到低水位后按原始年龄顺序读回；
  后续新数据继续落盘，保证顺序。上限为正时先落盘、上限作为紧急保护。
- 打开/写入/读取失败都回退内存并记录；已写记录仍优先读完。停止、断连、退出关闭 fd 并
  删除文件，启动清理超过 24 小时的残留。
- 单条消息仍受 `max_line_bytes`。单次回调元素本身超过总预算时先解帧，由其产生的行
  触发落盘。

测量（60,000 行、24 MiB 单次回调、20µs/行处理）：不落盘内存峰值 26.6 MiB、约 1.25s；
`spill_bytes=8 MiB` 时峰值 2.0 MiB、约 1.64s，落盘与读回各 55,481 条，停止后文件清零。
即内存换约 31% 时间。

验证：581 项单元测试通过（新增 12 项：不限模式、分级告警、落盘顺序、上限保护、
打开/写/读失败回退、残留清理、关闭落盘、配置校验）；界面、edgy、重连、性能回归、
StyLua 与 `git diff --check` 通过。

边界：spool 不是持久化会话；磁盘满且回退内存后，若仍设上限可能断开。读取失败会丢弃
无法再读的剩余记录并告警。未做管道背压；真实 Agent 的大历史回放与磁盘吞吐仍需实测。

## 修复 userdata 长度崩溃与单条消息诊断（2026-11-10）

- `transcript` 的变更签名与 `diff` 尺寸改用类型安全长度函数：JSON `null` 解码为
  `vim.NIL`，此前对 `oldText`/`newText`/`text` 等直接取 `#` 会报
  “attempt to get length of a userdata value”，中断渲染任务。
- `entries`/`attachments`/`locations`/`child` 同样先判断类型。
- 单条消息超限日志补充实际字节数与上限；`max_line_bytes` 默认从 8 MiB 提高到 32 MiB，
  足以容纳大 diff/工具输出，同时仍保留单条硬限制。

新增 3 项回归（null diff 字段、上限尺寸记录、超限日志含尺寸）；583 项单元测试通过。

## 超大文本更新分片（2026-11-10，方案 A）

- 完整解码后，超过 `transport.text_chunk_bytes`（默认 64 KiB，0 关闭）的文本型
  `session/update` 按 UTF-8 边界切片，作为请求头部的有序工作项插回队列，使归约、输入、
  动画能在片间让出主循环；后续消息仍排在这些片之后。
- 只处理 `agent_message_chunk` / `agent_thought_chunk` / `user_message_chunk` 和单项
  工具文本；工具文本的分片携带累计内容，因为 reducer 会替换 content 数组。其它形状仍整条处理。
- 后续分片保留 `messageId`/`toolCallId` 与 `_meta`；切片后再解码不会递归切片。
  `:AcpDebug` 增加 `chunked_messages`/`chunk_parts`。

测量（约 8.4 MiB 单条文本、模拟每次归约 0.2ms、64 KiB 片）：不切片 1 次归约、约 13ms；
切片后 128 片、约 60ms，片间按 4ms 预算让出。开销来自逐片编码/解码，换的是单次阻塞缩短。

边界：仍先完整解码，峰值内存不降；工具表数组与 `rawOutput` 暂不切片；超大表格逐片
重排仍是 O(n²)。新增 6 项测试；589 项单元测试、界面、edgy、重连、性能与格式检查通过。

## 实时 diff 展开、历史折叠（2026-11-10）

实时 `edit`/`write`/`patch` 卡片在有内容后自动展开；历史回放仍折叠。修正点：原先
`historical` 在提交后永久保留，导致打开历史会话后继续对话产生的新 diff 也被折叠。
`Runtime:commit` 现清除该标记；回放期间已建立的块带有显式 `expanded=false`，不受影响。
手动 `<Tab>` 折叠仍然优先。

新增 1 项回归（提交前折叠、提交后打开新卡片、旧卡片保持折叠）；590 项单元测试通过。

## 思考流式显示与完成折叠（2026-11-10）

- 流式 thought 创建时按 `ui.thoughts.expand_while_streaming`（默认开）展开，标题为
  `Thinking`，正文实时渲染。
- 结束条件：转入正文/工具/计划等其它块、同 turn 换 messageId、`begin_turn`、
  `finish_turn`、取消/错误。结束时清 `status` 并按 `collapse_on_finish`（默认开）折叠，
  标题变 `Thought`。
- 手动 `<Tab>` 优先，流式中折叠不会被后续 chunk 弹开；`show_collapsed_header=false`
  仅隐藏已完成块；历史重放首帧即完成折叠。
- 思考开关随 session 创建注入，直接构造 state 时回落到配置默认值。

新增 10 项测试；600 项单元测试、界面、edgy、重连、性能与格式检查通过。

## 接收链与思考生命周期审查修复（2026-11-11）

以下修正取代上文早期实现对落盘保序、失败回退及工具分片的说明：

- 修复 Client 启动回调吞掉分片返回值的问题。追加文本改用惰性派发器直接交给 RPC，
  不生成整批 JSON 分片，不重新检测 UTF-8 边界片段，避免丢消息和无限重分片。
- 工具内容属于替换语义，恢复原子更新；diff、rawOutput 也不切片。取消累计前缀方案，
  避免二次方复制以及工具完成状态先于完整内容到达。
- spool 的磁盘前缀先于内存后缀消费，文本派发器先于所有后续消息完成。数据读写改为
  异步，写入按 64 KiB 提交；写入完成之前仍计入积压预算。分片、已读缓冲也计入估算。
- 创建/写入失败回退内存；部分写入尾部不计为已提交记录，旧的已提交记录仍优先读取。
  读取失败明确报错并断连，不丢弃剩余消息后继续运行。
- 排空或正常退出释放临时文件，启动清理恢复生效。在途 I/O 完成前不关闭/复用 fd，
  停止后的回调只清理资源，不恢复队列或派发消息。
- stdout 共享时间预算到期后不再逐元素同步执行 handler。不完整消息也检查 pending
  上限，断连清空 decoder 缓冲。默认 pending 上限由 16 MiB 调整为 64 MiB，以容纳
  默认允许的 32 MiB 消息；自定义更小 pending 上限仍可提前断开。
- Thinking 使用当前活动块指针，避免每次 append 扫描历史；已有工具/计划更新和取消
  都立即结束思考，取消后的迟到 thought 内容保留但不会重新展开。

回归覆盖：真实 Client → Process → RPC 加 spool 的分片/响应顺序、带编号的落盘及故障
回退保序、中文边界、短读拆开记录头、读故障断连、正常退出/启动清理、异步读写期间
停止、回调过期后不继续逐元素派发、17 MiB 分段接收、Thinking 原地更新与取消边界。
611 项单元测试通过；界面、edgy、重连、性能与格式检查通过。

边界：完整 JSON 解码、工具原子替换、单块排版和临时文件元数据操作仍不可抢占；
spill_bytes 是工作集目标而非 RSS 上限，输入回调、解码对象和临时复制仍占用额外内存。
异步落盘无法让超过有限预算的输入突发无条件成功；慢磁盘或过大突发仍会明确断连。

## 可选懒渲染 A → B（2026-11-11）

- `ui.render.lazy_syntax`（A）与 `pagination.enabled`（B）默认均关闭，保留原全文路径。
  A 保留文本、conceal、结构高亮、背景及原有增量排版，只按视口调度代码/diff 语法。
  装饰与布局分离，缩进传播源片段和 byte offset；当前视口优先，再按滚动方向预加载。
  语法独立 namespace，离开视口后清理；共用 CodeHL 64 项/2 MiB 缓存，单行大量 captures
  也分批写入 extmark。完整单次解析仍不可抢占。
- B 首先物化最近一页，页内通过 coroutine 按块分批排版，完成后原子提交。使用会话身份、
  版本、视图代次、宽度和主题代次丢弃旧任务；隐藏、切会话或销毁后不提交旧布局。
- 上下边缘预取及 <CR>/<Tab> 加载提示；gg/G、[b/]b 适配分页。回收同时参考块数和源载荷
  预算，超过高水位后回收至约 90% 低水位，可见块/操作块受保护。清理被回收块的 Markdown
  和 diff 缓存；单个大块不拆分，继续受既有模型限制，预算不是 RSS 硬上限。
- Visual/Select 期间暂停分页修改及回收，退出后刷新；阅读旧页时新输出不抢占位置。
  源文本 byte offset、同源行内偏移与 block/渲染行回退共同用于恢复阅读锚点，覆盖表格重排。
- 原生 / 与 Visual 复制仅覆盖已物化内容，不伪装全文搜索；显式 Chat:transcript() 导出仍是
  Session 保留的全文，导出时会临时执行全量文本排版。
- `profile=true` 启用分层计数，`:AcpDebug` 的 render 包含排版/写入/装饰耗时、行数、缓存
  块数、语法 extmark、任务状态及页范围。默认不开日志或采样。

新增 20 项回归，642 项单元测试通过。默认模式及开启 A+B 的 native/edgy/reconnect 集成
检查通过；原有性能 smoke test、StyLua 和 diff 检查通过。

新增 `tests/perf_lazy.lua` 比较三种模式。在本机单次 600 块混合代码/表格/普通文本样本中：

| 模式 | 首次布局提交 | 初始语法解析调用 | 物化行 | inline/语法 extmark | 缓存块 | Lua 增量 |
| --- | --- | --- | --- | --- | --- | --- |
| 全文 | 182.73 ms | 200 | 8600 | 33000 | 600 | 23639 KiB |
| A | 53.24 ms | 1 | 8600 | 17080 | 600 | 16509 KiB |
| B（含 A） | 5.19 ms | 1 | 926 | 1868 | 64 | 1615 KiB |

这是单次本机测量，不是性能保证；first_commit 不是物理屏幕绘制时间，Lua 增量不是 RSS，
extmark 计数不含背景 namespace。A 的全文文本排版/写入仍同步；B 才减少物化范围并将
页内排版切片。大单块、单次 Treesitter 解析及页提交的 buffer 写入仍可能超过软时间片。

## 工作指示器稳定性与诊断（2026-11-11）

- Chrome 动画从 Vim timer ID 改为可检查存活状态的 libuv handle；在安全 UI 上下文更新，
  原始 tick 合并，最多保留一个待处理 tick。handle + 代次过滤停止、替换、销毁后的旧回调。
- 同步状态时检查 is_active/is_closing，而不是只判断字段非空；停止/关闭、启动失败后可在
  下一次同步重建。窗口/焦点恢复会触发同步，切到其他 tab 暂停，返回后恢复；无需额外 watchdog。
- 按单调时间选帧，不在主循环恢复后补放积压。animate=false 会释放已有 handle 并显示静态帧。
  参数变化也会安全更换 handle；启动、tick、apply、redraw 错误独立记录，连续错误阶段仅首次日志。
- 明确定向刷新 ACP winbar，不移动焦点；API 不支持时回退 redrawstatus!，缓存兼容路径，
  不每帧重复探测失败。输入区 setter 错误可返回给 Chrome，不再被内部 pcall 静默吞掉。
- :AcpDebug 增加 spinner：timer 状态、tick/帧变化/求值/重绘计数、最大 tick 间隔、scheduled
  等待、刷新等待、最后求值帧、当前/历史错误。求值和重绘请求并不保证已经发生物理屏幕绘制。

657 项单元测试通过（新增 15 项）；默认及 A+B 的 native/edgy/reconnect 集成、性能与格式检查通过。
新增可选 tests/integration_spinner.py（测试依赖 pynvim）：附加真实 Neovim UI，检查 grid_line
中的实际 braille 帧。覆盖非当前输入窗口、停止 handle 后恢复、250ms 忙循环后的诊断与恢复、
redrawstatus! 兼容路径；不再只用 vim.wait 观察内存字段证明动画正常。

边界：UV callback 也依赖 Neovim 主循环。同步 JSON 解码、单块排版、解析或阻塞的其他插件仍会
暂停动画；此次不承诺消除所有视觉停顿。可用 max_tick_gap_ms 与 interval_ms 对比，再结合
scheduled/refresh 等待和 render/transport 统计定位。已失效 handle 的修复发生在下一次状态或
窗口/焦点同步，而不是在没有任何事件的情况下由另一个定时器持续轮询。

## 主循环工作调度与提交分片 P0–P3（2026-11-11）

- P0：`render_metrics` 增加 1/2/4/…/1024ms 延迟桶、溢出计数及最近 20 条 >8ms 慢任务
  （名称、耗时、block id/kind/工具类型/载荷规模，不含正文）；`block_layout` 单独计时，
  `write` 记录提交行数。默认 `profile=false` 时零采样、零记录。
- P1：`ui/work_scheduler` 统一调度接收尾部、分页排版、语法装饰和大型提交。每队列每轮
  最多一片，优先级只决定类别，协议消息保持 FIFO；片长按实际耗时计算，失败按任务隔离。
  stdout 回调超出预算时，未处理元素进入该调度器逐片解析，保序且不丢弃；停止后丢弃尾部。
- P2：分页排版中的 Markdown、表格在结构行边界让出（表格逐行、Markdown 每个源行、块边界），
  不再只能按完整 block 切换。单个 JSON 解码、单次 Treesitter 解析仍不可抢占。
- P3：`ui.render.commit_rows`（默认 2000，0 关闭）以上的提交通过 `write_chunked` 按行写入
  并让出；文本写入遇 textlock（E565）在下一片重试。分片期间内容更新作废旧提交、强制完整
  重排，避免增量写入基于半份布局；会话切换或销毁会取消排队/在途任务并恢复 modifiable。

新增 21 项回归（调度器优先级/FIFO/预算/失败隔离/取消/刷新、延迟桶与慢任务上限、接收尾部
恢复与停止丢弃、提交分片/失效/表格等价、配置校验）。678 项单元测试、默认及 A+B 的
native/edgy/reconnect 集成、性能 smoke、附加 UI spinner 与格式检查通过。

边界：共享预算是软上限，接收首次回调和消息派发仍有独立预算。同步 JSON 解码、单次 Treesitter
解析、diff 计算、非分页排版和单条消息分帧仍不可抢占；worker（P4）与后台解码（P5）尚未实施。

## 当前改动审核修正（2026-11-11）

- stdout 尾部改为单一 FIFO，续跑重置 deadline；退出等待原始输入与消息队列排空。
  延迟原始数据计入积压限制，停止后不再接受 stdout。
- 调度器保留协议续跑顺序，为未获执行的类别提升优先级，跳过已取消任务。
- 接通块内 checkpoint；可取消排版隔离 Markdown 缓存及临时展开状态。
- 分片写入在每次让出前恢复只读；增量文本也按行分批。旧提交不能清除新任务，
  宽度/语法代次/显示选项失效与写入错误会触发完整重排；页面跳转等待提交完成。
- 移除阻碍继续加载历史的隐式四倍窗口上限。最新消息始终物化；阅读历史期间允许窗口增长，
  返回底部再收缩，不再声称该模式有物化行数硬上限。
- 附加 UI 压力回归同时检查分片提交内容、让出期间只读及提交期间 spinner 多帧变化。

本轮验证：690 项单元测试、默认及 A+B 的 native/edgy/reconnect 集成、性能 smoke、
附加 UI spinner（含受控慢高亮的大型提交并发场景）、StyLua 和 git diff --check 通过。
性能测试现在使用真实窗口并等待完整提交，避免隐藏视图上的空 buffer 产生虚假的低耗时。

## 自动折叠后的尾部锚定与鼠标 EOF 边界（2026-11-11）

- 保留 Thought 卡片原有尾部空行；跟随输出时，自动收缩与后续追加统一按最后显示行贴底。
- 短转录从顶部正常显示，不添加顶部留白；聊天窗口局部 smoothscroll 与显式
  skipcol 处理高于一屏的逻辑行，支持输入区仍处于插入模式时更新非当前聊天窗口。
- WinScrolled 即时钳制与合并重检阻止 EOF 过滚；上翻阅读和手动卡片操作保持原有锚点。
- 新增 9 项单元回归与 `tests/integration_tail.py` 附加 UI 检查：实际鼠标事件、折叠与回复合并、
  非当前窗口、焦点/模式、尾部空行及 UI 网格帧中的 EOF 稳定性。

验证：699 项单元测试、默认及 A+B 的 native/edgy/reconnect 集成、性能 smoke、附加 UI
tail/spinner（含大型提交并发场景）、StyLua 与 git diff --check 均通过。

后续调整：短内容（含空会话提示及折叠后不足一屏的内容）改为顶部显示；自然剩余空间允许
存在，但禁止继续向下滚动将内容上推。保留长内容尾部锚定、原有尾部空行及输入焦点/模式。
调整后 700 项单元测试、默认及 A+B native 集成、附加 UI tail 检查和格式检查通过。

## 鼠标返回 EOF 恢复实时跟随（2026-11-11）

- 修复 WinScrolled 只会关闭 follow、不恢复 follow 的单向状态切换。现在以实际末尾显示行
  是否可见为准，上滚离开末尾暂停跟随，下滚返回末尾恢复；不再要求阅读光标接近 EOF。
- 恢复时清除 pending_new 和对应提示；暂停期间仍接收、归约与追加消息，不移动历史阅读位置。
- 只处理聊天窗口自身的纵向滚动，合并隔离提交/锚点恢复产生的程序滚动事件，保留重排、分页、
  选区保护和 EOF 过滚钳制。部分可见的超长换行尾行不算到达实际 EOF。
- 新增默认/分页的暂停→追加→返回→继续跟随回归、程序滚动隔离与部分尾行检查；附加 UI 用真实
  鼠标事件验证暂停时视口不变、回到新末尾后新消息自动跟随。

验证：705 项单元测试、默认及 A+B 的 native/edgy/reconnect 集成、性能 smoke、附加 UI
tail/spinner、StyLua 与 git diff --check 均通过。

## 原生补全 source 与完整项目文件索引（2026-11-11）

- 新增共享 `acp.completion` 核心、blink.cmp provider 与 nvim-cmp 的 `acp` source；只在可编辑
  `acp_input` 中交付候选，不修改全局 sources/按键，保留 `<C-x><C-u>` 异步原生回退。
- `/` 使用当前会话命令、说明和输入提示；`@` 使用完整项目索引。框架自行匹配排序，原生菜单
  在全量匹配后才受 `max_items` 限制，深层/后出现的文件不会被前 200 个候选遮蔽。
- 文件发现异步选用 rg → fd/fdfind → git → 内置遍历；按批排空 NUL 输出后才完成扫描，
  提供 TTL/LRU/估算字节预算与刷新入口。超限/失败不发布部分索引。取消立即丢弃查询结果，
  无订阅扫描延后 50ms 停止，避免连续按键的取消/订阅交接反复重启进程。
- 共享引用语法支持无扩展名、中文和 JSON 引号路径，补全与提交解析一致；显示/插入相对会话
  cwd，必要时使用 `../`。支持字面美元符号、空格、引号、反斜杠和换行文件名，不预读文件正文。
- `:Acp files` / `pick_file()` 可使用 vim.ui.select、fzf-lua、Snacks、Telescope；仅插入引用并
  返回输入区，不打开文件或发送。默认不占用按键，`:AcpCompletionRefresh` 清理索引缓存。
- 请求与选择接受检查绑定、会话/cwd、buffer tick、可编辑性及光标；销毁/隐藏取消，picker
  暂时取得焦点不会被普通 BufLeave 误取消。原生确认仅在旧后缀仍匹配且身份未变时删除后缀。

验证：733 项单元/组件测试通过（较本轮基线新增 28 项）；真实 blink.cmp v1.10.2、nvim-cmp
main 及原生菜单的 attached-UI 测试通过，覆盖命令、深层匹配、中文/空格、UTF-8 中间替换和
Makefile 附件。框架 Enter 确认不发送，原有 `<C-s>` 发送保留。默认及 A+B 的
native/edgy/reconnect、原有性能 smoke、tail/spinner 附加 UI 回归均通过。

`tests/perf_completion.lua` 的单次本机测量：10,001 个完整候选冷扫描/构建约 80ms，缓存请求
仍构建全部编辑候选约 49ms；期间推进 14 次 timer tick，尾部文件匹配通过。不是性能保证。
README、help、架构说明及两个 lazy.nvim 示例同步；StyLua 与 `git diff --check` 通过。

边界：第三方 picker 的真实交互 UI 本轮未运行，fzf-lua 使用 API 桩验证特殊路径往返；
Snacks/Telescope 适配仍需用户环境实测。内置遍历不解释 ignore 文件，不遍历目录符号链接；
索引预算不是 RSS 硬上限，框架和选择器物化候选仍有额外内存开销。未在真实旧版 Neovim 或
复杂 symlink cwd/跨根目录组合上做完整验证，也未向真实 Agent 发送模型请求。

## 图像附件（2026-11-11）

调研了两类现有实现后按同一路线落地：OpenCode TUI 与 pi 都用自己的按键读系统剪贴板，
都没有使用 OSC 5522；`img-clip.nvim` 等插件只负责把图像写文件并插入标记文本，无法生成
ACP `image` 块，因此没有引入依赖。

- `context/image`：按魔数识别 PNG/JPEG/GIF/WebP，内容寻址存入
  `stdpath("state")/acp/images`（临时名 + rename，目录 0700、文件 0600），可按 TTL 与总量回收。
- `context/init`：`file()` 识别图像后改用图像附件，避免把二进制当 text/plain 读取；
  `image()`/`image_bytes()` 只产出元数据，`to_prompt()` 在发送时才编码。
  `path_mode` 控制 `@shot.png` 是 `resource_link` 还是内嵌 `image`；文件消失时返回错误而非静默省略。
- `context/clipboard`：wl-paste / xclip / pngpaste / powershell.exe 链式读取，三态返回，
  避免空 Wayland 剪贴板回落读取旧 X11 截图；输出收集时限制字节数，stderr 最多保留 4 KiB。
- `ui/paste_image`：仅拦截输入区内“单个存在的图像路径”粘贴，其余交还原 `vim.paste`。
  `keymaps.input.paste_image` 默认为 `<C-v>`；不切窗口，读取期间用户离开后也不抢回焦点。
- 图片标签改为 `Input` 内可编辑的真实文本占位符，锚定粘贴光标，不再进入 winbar。
  虚拟文本不能承载光标与原生删除操作，因此不再使用；范围 extmark 提供高亮和附件关联。
  后方退格/前方 Delete 整块删除，撤销/重做同步恢复/移除附件；发送正文剔除受跟踪的占位符。
  按占位符在正文中的 UTF-8 字节位置生成交错的 text/image（或 resource_link）内容块；
  聊天记录以同一顺序在正文插回编号，不把图像文件名堆在标题上。排队前深拷贝位置元数据，
  已有完整本地图文消息时不再用 Agent 的碎片回显覆盖正文，避免偏移失效或重复图像标记。
  标签使用 `[Image 1]`、`[Image 2]` 等紧凑编号；`AcpInputImage` 默认浅黄色底、深色粗体。
  先前只调整 winbar 内排序的修复不符合需求，原测试也未断言屏幕位置。
  异步读取用独立 extmark 跟随编辑，以 input/config/草稿代次拦截过期结果；不强制 startinsert。
- 缓存清理保护草稿（含持久化）、队列与会话块引用；写入时即使用 0600，校验已有摘要文件，
  检查 rename 返回值。WebP 文件嗅探改读完整 12 字节头。图像测试隔离缓存，避免清理用户图片。
- `app/prompts`：按 `promptCapabilities.image` 拒绝内嵌图像并提示切换模型；链接形式仍可发送。
- 日志把 `data`/`blob` 的 base64 载荷替换为 `<base64 N bytes>`；配置校验交叉检查
  `context.images.max_bytes` 与 `transport.max_line_bytes`。

`tests/integration_image.lua` 覆盖能力门禁与过期草稿；附加 UI 的
`tests/integration_image_cursor.py` 和 `edgy` 参数覆盖真实屏幕标签位置、光标与模式，
edgy 分支使用真实 controller 和剪贴板命令。两种能力分支
（mock agent 声明/不声明 `image`）都通过。验证：778 项单元测试、默认及 A+B 的
native/edgy/reconnect、性能 smoke、tail/spinner 附加 UI 回归通过。

边界：不接入 OSC 5522 的终端协商（不是“Lua 无法观察 OSC 回复”）；
未做图像转码，非 PNG/JPEG/GIF/WebP 直接拒绝；未内联预览；未在真实 X11/WSL/macOS 剪贴板上运行，
只用真实 `wl-paste`（空剪贴板与桩输出两种）和命令桩验证。临时目录预算不是 RSS 上限。

## 内联编辑（2026-11-11）

参考 Zed 的 `<rewrite_this>`/单事务模型与 CodeCompanion 的 ACP 临时副本实现后，采用后者作为
架构基础：要求 Agent 编辑私有副本，权限严格匹配本次副本，结果按选区过滤回可编辑范围。ACP
不能临时注册工具，因此不使用 Zed 的自定义工具协议。

- `inline/selection`：在映射内用 `getregionpos()` 捕获；字符/行选择默认扩成整行，块选择逐行；
  精确字符/块范围不扩大权限；普通模式没有选区，按请求修改整个副本。拒绝分割 Tab/宽字符的块范围。
- `inline/copy`：同目录 `.acp-inline-*` 私有副本（0600），目录不可写时退回 state；行尾符跟随源 buffer。
- `inline/result`：行/UTF-8 字符 diff、越界过滤，始终按最初文本、文件名和换行快照检查冲突。
- `inline/apply`：仅写入真实修改的 hunks，保留其它行的 extmarks，单次撤销。
- `inline/diff_session`：独立只读 scratch 审查，`ga`/`gr`/`g2`/`g3`/`g1`；全部决定后才写源。
- `inline/anchor`：纯几何；`cursor` 优先下方、空间不足翻上方，记录屏幕格并夹进屏幕；
  源窗口滚动/光标移动/resize 重算，`window` 保留窗口左上锚点。
- `inline/review/layout`：窗格选项只写局部值，打开后恢复继承值，避免浮窗继承 statuscolumn/折叠/winhighlight；
  `BufWinEnter` 发现窗格 buffer 被换掉时放回并恢复选项。每栏设置 `winfixbuf`，`:edit`/`:enew`/`:bnext` 与插件切 buffer
  均以 `E1513` 拒绝，结果列不会变成真实文件；scratch 用 `bufhidden=hide` 兜底，
  真正销毁由 `close()` 负责。按文件语言显式 `vim.treesitter.start()`（复用
  `ui.code_hl` 的语言解析，覆盖无自带 ftplugin 的语言），失败静默回退 legacy `syntax`。
  新 tabpage 的真实窗口，**不用** Vim diff 模式：`3-column`（原文│结果│提案）或
  `2-column`（结果│提案）三栏按 `review/align` 插入 filler 行，行数恒等，
  `scrollbind`/`cursorbind`/`foldexpr` 折叠原生同步；`statuscolumn` 绘制状态条与真实行号；
  不修改 `diffopt`；打开失败时回滚窗口、buffer、autocmd 与选项。
- `inline/review/align`：纯函数对齐模型。块内行配对来自 `result.hunk_pairs`（linematch，块内无相似行时
  从上到下），行类型（modify/delete/add）、filler 与字符级范围（`result.char_ranges`，超过一半变化的行
  不做字符级标记）都来自同一份配对，modify 行对面必有内容、add/delete 行对面必为 filler。
  块高度与决策无关，决定只替换结果列块内文本。
- 外观：每栏只显示自己一侧相对结果的变化——原文 pending 为 `AcpReviewDelete`(+DeleteText)、接受后
  `AcpReviewDimmed`、拒绝后无底色；结果 pending 为 `AcpReviewPending`、接受后 `AcpReviewAdd`(+AddText)；
  提案为 `AcpReviewAdd`(+AddText)、拒绝后 `AcpReviewDimmed`。状态条 `AcpReviewState*`（三栏同行同色，
  已决定块首行 ✓/✗）；当前块在结果列行尾提示 ga/gr（`hints`）。winbar 徽章每栏一个，计数只在结果列。
  `AcpReviewCursorLine` 复制 `CursorLine` 底色去掉下划线。底色在 setup/ColorScheme 时从主题
  `DiffAdd/DiffDelete/DiffChange/DiffText` 复制（只复制 bg），运行期不算色；filler 为固定灰。
- `inline/review/card`：`min_split_width` 以下或 `target = "float"` 时回退；复用
  `ui.diff`/`ui.diff_hl` 的 `bg` 与语法 segments，只加 `@@` 头、状态 gutter 与 `row_hunk`。
  从原文提取上下文，不混入相邻提案；状态符号的语法偏移按 UTF-8 字节计算。
- `inline/diff_session`：两条路径共用状态机；接受 = 把提案行写入结果列，拒绝 = 不动；
  `ga/gr/g2/g3/g1/q`/`]c`/`[c`/`u`，`advance` 默认关闭；全部决定后 `apply.hunks` 一次写入。
  `]c/[c` 与 `]h/[h` 按稳定审查 hunk 顺序循环（含已决定块，支持撤销）；
  三栏显示行一致，任意一栏都能选择/决定/跳转，光标留在当前栏并打开目标折叠。
- `inline/ui`：从 `inline.window` 读取 border、title_pos、style、highlight 组、尺寸与
  offset；`follow_cursor` 控制是否随源光标移动；review 窗 resize 后重新渲染。
- `inline/review`：`diff` / `write` 策略，精确 ft → 复合 ft 首段 → `*` → 默认；always-accept 优先。
- 权限：读/搜索/思考/取回放行，仅副本的 edit 放行，其余拒绝；可配置放开写和命令。
- 当前 session 正常 prompt 回合，复用任务、权限路由、取消及队列结算；不创建新 session。
  忙碌或队列非空时拒绝 inline 提交；普通聊天仍可排队，完整回复进入当前聊天记录。
  断开/重配置时失效并清理；聊天选区使用同一 token 机制，按位置发送
  `resource` 或 `resource_link`，空光标取整行，无输入框时排队。

验证：863 项单元测试通过，新增精确范围、冲突、元数据变化、资源限制、extmark 回归、
普通模式提示与自由编辑、锚点翻转/夹取、三/两栏对齐布局、card 回退、不修改 diffopt、
光标与 Visual 选块与外观配置校验；补充两种布局的 EOF 插入逐块接受/拒绝、
对齐模型（modify 必对内容、add/delete 必对 filler、中英文改写从上到下配对）、字符级范围与 UTF-8 边界、
按决策重绘三栏、任意栏决定、状态条与提示随光标刷新、分屏失败回滚、高亮覆盖和 card 上下文/字节偏移回归；
16 项 inline 集成检查覆盖当前 session、普通模式按请求编辑、Visual 越界丢弃、
真实权限 RPC、取消/排队/断开、迟到结果、filetype 变化及单次覆盖。附加 UI 测试覆盖 Visual
映射、行范围命令、草稿恢复、窄窗口、分栏审查、card 回退、tab/浮窗目标、
配置化边框/标题/高亮与光标跟随；
`integration_inline_highlights.py` 检查实际 UI grid RGB，覆盖两/三栏「栏 × 决策」的逐行逐列底色、
字符级 AddText 区段、dimmed 前景、filler 斜线与无行号、状态条字形与颜色、
光标行无下划线、ColorScheme 后持久化；
附加检查 `winfixbuf` 对 `:edit`/`:enew`/`:bnext` 的拒绝与关窗仍可用、
浮窗不继承审查窗口选项/winhighlight、以及逐行 Tree-sitter 启动；
既有集成另行回归。
边界：未在真实 OpenCode/其它 Agent 上验证工具副作用；权限不是 OS 沙箱。未实现多选区、
冲突重定位或问题回复浮窗（回复在当前聊天记录）。崩溃孤儿仅按命名、PID 和一天 TTL 尝试清理。

## 多 agent 兼容阶段 1（2026-11-12）

协议地基已落地：

- JSON null 在解码时归一化为 nil；reducer 的每条更新带变更日志，失败时整体回滚。
- `protocol/capabilities` 统一声明与查询能力；`protocol/client` 不再依赖 `ui/*`，调度器由
  `app/connection` 注入。
- agent 请求改走注册表，未注册方法仍为 -32601；回复与 `$/cancel_request` 共用已答标记，
  每条请求最多回复一次。
- 创建会话期间的未知 session 更新进入 256 条 / 1 MiB 的有界缓冲，成功后重放，失败丢弃。
- `initialize` / `session/new` / `session/load` 使用独立超时；load 随回放续期。取消顺序改为
  先 `session/cancel` 再 `$/cancel_request`，并在本地结算 `cancelled`；第二次取消强制结束回合。

验证：895 项单元/组件测试通过，0 失败，6 项 pending（后续阶段）。新增 null 回滚、
请求注册表/重复回复、能力查询、创建缓冲、超时续期与取消顺序测试；一致性套件 4 个 profile
的 null 与撤回请求用例转为普通测试。

## 多 agent 兼容阶段 2（2026-11-12）

等待回答的请求迁入单一交互中心：

- `app/interactions` 保存唯一状态并保证只回复一次；inline 回合和 `auto_allow` 是策略，
  picker 是呈现器，同一时间只显示一个，其余排队。agent 的 `$/cancel_request` 会关闭 picker
  并标记过期，迟到回答被忽略。
- 控制器的 `pending_permissions` 删除；工具栏等待提示与诊断计数从交互中心读取。
- 关闭 picker 时只在存在 `reject*` 选项时显式拒绝，否则回复 `cancelled`；撤回的请求只回复
  一次。`auto_allow` 不再回答以权限包装的提问（统一 kind 或 `switch_mode`）。
- 权限策略与呈现测试改写为交互中心语义，新增单次回复、排队、撤回、会话取消与类型化取消测试。

验证：905 项单元/组件测试通过，0 失败，6 项 pending。

## 多 agent 兼容阶段 3（2026-11-12）

提问通道与权限详情：

- 默认声明 `elicitation.form`（配置可关）。`elicitation/create` 经交互中心排队；表单显示
  `message` 与字段，单选简化为 picker，`_custom` 合并为 Other，schema 支持 required/长度/
  pattern/数值/format 校验；不支持的结构回复 `decline`。
- 统一 kind、`switch_mode` 与 pi select/confirm 的权限请求按提问呈现，标题用问题文本，
  不被 `auto_allow` 回答，关闭时回 `cancelled`。
- 权限标题按工具 kind 生成，execute 附带命令；提问型请求优先使用
  `_meta.permission.title`（Claude 的 "Ready to code?"）。
- 权限详情为独立只读浮窗：execute 显示完整命令与 cwd，edit 复用 `ui/diff`，其它显示
  `content` 或格式化后的 `rawInput`；`permissions.show_details = false` 可关闭。
- 等待回答/批准的 tool card 显示对应状态，`<CR>` 在卡片上重新打开该请求。
- 新增测试覆盖多字段表单里无 `_custom` 的选择字段、非 table 的 schema 属性、Other-only 与
  「选项 + 备注」、字段顺序、字符长度、不可移植的 pattern、关闭表单窗口、撤回后的迟到回调、
  交互回收上限与 presenter 异常。

## 多 agent 兼容阶段 4（2026-11-12）

认证：

- 默认声明 `auth.terminal` 与 `_meta["terminal-auth"]`（`capabilities.auth_terminal` 可关）；
  同时声明 `session.configOptions.boolean`（本轮新增，`boolean_config_options` 可关）。声明关闭后
  agent 不再提供登录方式，未声明的 `elicitation/create` 回 -32601。
- 新增 `app/auth`：只按 `-32000` 识别 `auth_required`。客户端自造的失败（超时、断线、写入失败）
  改用 `-32099`，因此崩溃和超时不再被误判为登录；`session/new`、`session/load`、`session/prompt`
  失败都会进入登录并在成功后重试。
- 单一登录方式直接执行，多个用 picker。`terminal` 类型在 `:terminal` 分屏运行**客户端自己配置的**
  agent 命令，只采用方法给出的 `args`/`env`（按 ACP 要求，方法不能指定 command；env 覆盖同名
  配置），启动前展示命令与 env。退出码 0 后**强制重启** agent 进程（`Connection:restart`，因为
  `reconnect` 在连接健康时是 no-op），再重发失败的消息；`agent` 类型调用 `authenticate`。
- 同一登录流程连续成功后 agent 仍拒绝时，最多重试 2 次后停止并提示；`:Acp login` 会重置计数。
  登录终端打开失败（例如窗口太小）会报告错误而不是留下 `running` 状态；横向分屏放不下时改用
  新 tab，登录窗口优先落在面板记录的焦点窗口下方，不会替换聊天区或输入框。
- 重试保留原用户消息，不重复插入；失败的那一轮不再留下错误块。
- 新增 `:Acp login` 与 `:Acp logout`（后者仅当 agent 声明 `auth.logout`）；未连接时 `:Acp login`
  明确提示先连接，logout 成功后提示下次新建会话需要重新登录。
- 删除 `prompts.lua`、`controller.lua` 里写死的 OpenCode 提示；没有登录方式时提示查看 agent
  文档。`health` 报告当前登录方式。
- 修复 `Sessions:create` 的 `creating` 守卫：创建任务被重连取消后不再永久卡住后续创建。
- 切换连接时清理 `pending_auth_retry` / `auth_after_ready`；`disconnect()` 取消进行中的登录。
- 新增 auth 单元测试（错误码、命令与 env 合并、引用、重试上限、取消、打开失败、logout）、
  controller 级登录全流程与「超时/崩溃不触发登录」「重试不重复消息」测试；mock 增加 `@auth`
  场景与 `logout`，并把非认证失败从 `-32000` 改为 `-32099`。

验证：977 项单元/组件测试通过，0 失败，3 项 pending（终端输出 ×2、controls）。

## 多 agent 兼容阶段 5（2026-11-12）

agent profile 与规范化 controls：

- 内置 `claude` 与 `pi` 预设；用户配置按字段合并，不会替换掉预设。`profile` 省略时按 agent
  名称推断，未知 agent 用 `generic`。
- 新增 `lua/acp/agents/init.lua`：`plan_mode`、`unsafe_edit_mode`、`tool_name`、
  `update_meta`、`is_question`、`classify_mode`、`error_hint`、`install_hint`，全部有 generic
  默认值，并且都有实际调用方：工具名落到 tool card，提问识别交给权限模块（保留通用启发式兜底），
  错误提示追加到失败块，`health` 按 agent 给出安装提示并检查每个已配置的 agent。
  OpenCode 的 `retry` / `compaction` / `child-session` 解析从 reducer 移入 profile。
- 新增 `lua/acp/session/controls.lua`：有 configOptions 时忽略 `modes`（pi 两者重复）；
  只有 `modes` 时按 profile 分类为工作模式或思考级别；模式语义优先读选项 `_meta.kind`。
  修正 `state.lua` 从 `result.modes.currentModeId` 读取当前模式；`current_mode_update` 同时
  更新 controls 和 configOptions。
- `app/options` 按 control id 选择，boolean 直接切换，`session/set_mode` 与
  `session/set_config_option` 各走其源；新增 `:Acp config` 汇总全部 controls。
- 工具栏只读 controls：徽章按 value id 与 `plan` 语义着色（`mode_hl(label, key, plan)`），
  思考级别单独显示小幅标记。
- 新增 `:Acp agent [name]`：切换 agent 时关闭当前连接、保留各自会话元数据；切换前统计并提示
  被丢弃的排队消息与被打断的回合。
- 删除随 controls 失去调用方的死代码：`controls.any`、`Session:option_by_category`、
  `state.select_values`、`state.option_label`；`:Acp config` 的嵌套标题不再重复。
- 新增 profile、controls 推导、切换方法、boolean 切换、agent 切换提示、工具名/错误提示/
  安装提示接线的单元与 controller 级测试。

验证：1006 项单元/组件测试通过，0 失败，2 项 pending（终端输出 ×2）。

## 多 agent 兼容阶段 6（2026-11-13）

呈现补全：

- 声明 `_meta.terminal_output`（`capabilities.terminal_output_meta` 默认开）。reducer 解析
  `_meta` 的 `terminal_info` / `terminal_output` / `terminal_output_delta` / `terminal_exit`，
  output 是全量快照、delta 是追加，两者可同时出现；tool card 展开后显示输出与退出码，
  非零退出用错误色。`terminal` content 不再渲染成 `terminal: <id>` 占位。
- tool card：`rawOutput` 在没有其它 content 时显示（不再只在 failed 时）；content 里的
  `resource` / `resource_link` 显示为 URI 摘要；标题两侧反引号被去掉；Claude 的
  `rawInput.edits[]` 每个 hunk 都还原为 diff（此前只看第一个）。
  「是否有可渲染文本」以 `detail` 是否为 nil 判定，而不是 content 条目数：`terminal` 条目
  自身不带文本，按条目数判断会让 `rawOutput` 被跳过、卡片留空。
- 折叠卡片在 header 后缀里提示隐藏内容：`done · 2 lines`，终端非零退出再补 `exit 2`。
  `execute` 卡片不会自动展开，此前输出完全不可见；展开后提示消失。diff 卡片不受影响
  （它们本来就会自动展开，且没有文本摘要）。
- plan：以 turn 号为界复用同一块，agent 文本不再打断查找；`priority = high` 显示标记；
  回放提交后清掉回放块的 turn 标记，避免首个 live plan 被折进历史。
- 停止原因：`max_tokens`、`max_turn_requests`、`refusal` 在回合末尾追加一条 notice，
  按 turn 号去重（迟到更新插在两次结算之间也不会重复）。
- 其它：工具栏显示 usage 的 `cost`（小于 0.0001 时用科学计数，避免显示成 0.0000）；
  记录 `session_info_update.updatedAt`；音频 content 显示为 `[audio]`；`notice` 的块 id
  改为单调计数器（此前用 `#blocks`，裁剪后会重用）。

验证：1040 项单元/组件测试通过，0 失败，0 项 pending。

## 多 agent 兼容阶段 7（2026-11-13）

inline 安全与提问：

- **直接写入检测**：提交时记录源文件的 mtime、大小与内容 hash，回合结束后再比一次。
  原文件被 agent 直接改动（包括 agent 新建文件）时中止应用，并提供「从磁盘重新加载 /
  保留 buffer / 查看差异」三个选择。hash 兜住了同一秒内等长重写，mtime 只作补充。
- **模式保护**：`inline.guard_mode` 默认 `"ask"`。当前模式被 profile 判定为自动批准
  （Claude 的 acceptEdits/bypassPermissions/auto）时提示一次并继续；`"switch"` 会临时切到
  最安全的模式并在回合结束后切回；`"off"` 只依赖磁盘检测。切换时同时更新
  `current_mode` 与 configOption 的 `currentValue`，否则派生 controls 会读回旧值。
- **提问交给用户**：inline 策略不再回答 elicitation，也不再回答以权限包装的提问
  （`permissions.question` 是唯一判定点）。有待回答的问题时回合不会提前结束。
- **收窄 `allow_commands`**：只对 `execute` 生效；`delete`、`move` 与未知 kind 一律回
  `reject_once`，需要时用新的 `inline.allow_kinds` 显式放开。
- **transcript 噪音**：inline 的生成 prompt 折叠为一行摘要（`inline: <请求>`），展开后
  才显示完整说明；`user` 块新增 `display_text` 字段承载摘要。
- 保留同目录隐藏副本作为默认 `inline.copy_dir`（用户确认），state 目录仍可配置。
- 新增 `tests/integration_inline_safety.lua`：直接写入被检出并可用「从磁盘重新加载」恢复、
  `delete` 在 `allow_commands = true` 下仍被拒绝、inline 回合中的提问送达呈现器。

验证：1064 项单元/组件测试通过，0 失败，0 项 pending；inline 安全集成脚本 3 项通过。
已知：`tests/integration_inline.lua`（阶段 7 之前就存在）依赖交互式权限选择，在 headless
下会在权限提示处停顿，通过项数在 7–10 之间浮动，不作为门禁使用。

## 多 agent 兼容阶段 8（2026-11-13）

会话管理与上下文补全：

- **分页**：`Catalog:list` 跟随 `nextCursor` 翻到底（上限 100 页；cursor 重复或为空即停），
  cwd 作用域内没有结果时回退到不限目录，并从 `nil` 游标重新开始。任何一页失败都整体
  报错，不返回半截列表。
- **resume**：新增 `Sessions:resume` 与 `Client:resume_session`。`Sessions:load` /
  `restore` 先查 `loadSession`；不支持但有 `sessionCapabilities.resume` 时走 resume，
  只恢复 agent 端上下文并提示「history is not replayed」，两者都不支持才新建。
- **close**：`Sessions:close` 在切换会话时释放上一个会话，`close_all_on_exit` 在
  `VimLeavePre` 里同步 `vim.wait` 逐个关闭（进程马上就被终止，协程式发送会丢包），
  删除会话前也先 close。三处都要求 agent 声明 `sessionCapabilities.close` **且** client
  真正实现了 `close_session`，避免只声明能力的 double 触发空调用。
- **MCP**：`config.mcp_servers`（stdio/http/sse）经校验后交给
  `Client:mcp_servers()`；stdio 始终保留，http/sse 需 `mcpCapabilities` 声明，
  再传给 `session/new`、`session/load`、`session/resume`。
- **上下文降级**：agent 不支持 `promptCapabilities.image` 时，图片在读取字节前就降级为
  `resource_link`，不再于发送前直接拒绝整条消息。
- **cwd**：`resolve_cwd` 去掉末尾 `/`（根目录保留），避免同一目录被 agent 当成两个。

顺带修正一个真实缺陷：`capabilities.agent` 曾把「client 实现了 `load_session`」一律当作
支持，而真实 client 总是实现该方法，使显式声明 `loadSession: false` 的 agent 被误判；
现在只对无法上报能力的轻量 double 做这种推断。

mock 新增 `resumeonly` profile（可 resume、不可 load）、`session/resume` 与
`session/close` 处理、`ACP_MOCK_CLOSE_LOG`（逐行记录被关闭的会话 id），并让
`ACP_EMPTY_SCOPE_DIR` 的目录比较忽略末尾斜杠。

验证：1087 项单元/组件测试通过，0 失败，0 项 pending（新增 23 项，分布在
`spec_session_management`、`spec_session_lifecycle`、`spec_config`、`spec_image`）。
未在真实 agent 上手工验收 resume/close 与 MCP 下发。

切换离开仍在运行的会话不会发送 close：那只会打断用户打算留在后台的工作，等它结束
后（或退出编辑器时）才释放。

## 多 agent 兼容阶段 9（2026-11-13）

架构收尾，四条验收标准全部由 `tests/spec_architecture.lua`（14 项）守护。

- **事件分发表**：`app/events` 用 `handlers[name]` 代替 controller 里的 if 链，未知事件被忽略，
  服务或测试可以替换单个处理器。
- **inline 依赖注入**：`acp.inline.setup({ state, send, is_question })`。inline 不再 require
  controller，也不再直接 require `app.permissions`、`ui.picker`、`ui.diff`。
- **呈现器边界**：新增 `app/presenter`，picker、表单、权限详情、会话浏览器、图标与 diff 都从
  这里取。它按调用时 require，所以测试替换具体后端（如 `acp.ui.picker.select`）仍然生效。
- **状态真拆**：`app/stores` 把全局 `S` 拆成 `connection` / `session` / `view` 三张真实表，
  字段按语义命名（`session.current`、`connection.phase`），`config` 留在顶层。旧的扁平名是
  metatable 提供的兼容视图，`rawget` 读不到；`controller.stores()` 暴露三张表。controller、
  `app/*`、`tasks` 与全部测试改为显式 store 路径（685 处）。
- **health 解耦**：`config.remember()` / `config.effective()` 保存并读取最近一次有效配置，
  health 只在需要运行时事实时才访问 controller。

controller 从 1851 行降到 599 行。移出的职责：`app/bootstrap`（服务构造与接线，原 ~550 行
`setup`）、`app/turn`、`app/window`、`app/status`、`app/attachments`、`app/runtime_ops`、
`app/connection_flow`、`app/events`、`app/presenter`。

分层门禁：模块 require 图无环；`protocol/*` 与 `session/*` 不 require `acp.ui*`；`app/*` 只能
经 `app/presenter` 使用 picker/form/详情/会话浏览器/图标/diff（`app.connection` 的
`ui.work_scheduler` 例外，它属于调度而非呈现）。

验证：1101 项单元/组件测试通过，0 失败，0 项 pending；`tests/integration_inline_safety.lua`
3 项通过。行数与依赖约束由测试断言，不是一次性统计。

## 上下文块改为发送时构建（2026-11-13）

对照 `docs/compat-plan.md` 阶段 8 逐条核对时，发现 8.6 有两条实际未实现，另有一个更严重的
既有缺陷：

- **非 `embeddedContext` 的选区只发链接**：选中文本只留在 attachment 里，从不进入 prompt。
  不支持 `embeddedContext` 的 agent（pi 就是）只拿到 `file://...#L10:20`，还得自己去读文件；
  若文件有未保存修改，读到的还是磁盘旧内容。计划要求的是「链接 + 一段包含选中文本的 text 块」。
- **未保存 buffer 不检查 `embeddedContext`**：只要有修改就无条件发 `resource` 块，等于向
  未声明该能力的 agent 发送它没承诺处理的类型。
- **草稿恢复会静默丢附件**（核对时新发现）：`storage/drafts` 保存时会剥掉 `block` 字段以控制
  体积，而旧实现只在附加时构建 `block`，因此从草稿恢复的图片/文件附件在发送时直接消失。

根因是「能力检查发生在附加时」。现在 `context.block(att, config, opts)` 在发送时按
`promptCapabilities.embeddedContext` 决定形态：

| 附件 | 有 `embeddedContext` | 没有 |
|---|---|---|
| 未保存 buffer | `resource`（内嵌文本） | `resource_link` + `text` |
| Visual 选区 | `resource`（内嵌文本） | `resource_link` + `text` |
| 普通文件 | `resource_link` | `resource_link` |

`context.selection` 不再接受 `embedded` 参数，`app/attachments` 也不再在附加时查询能力——
附加与发送之间可能隔着重连、agent 切换或草稿恢复，那时的能力判断已经过期。

验证：1106 项测试通过，0 失败（新增 5 项，覆盖两种能力下未保存 buffer 与选区的块形态、
以及草稿恢复后附件仍被发送）。图片降级与 inline 安全集成（3 项）回归正常。
