# 运行时架构与所有权

更新：2026-11-10。本文描述当前实现，不是待实施计划。

## 模块边界

```text
transport/process + framing
  └─ 有界、有序、按时间片分发完整协议行
       └─ protocol/client + jsonrpc
            ├─ RPC 匹配、超时、初始化与权限协议
            └─ controller：装配、选择与跨模块协调
                 ├─ app/connection：client 创建、启动、断连与重连
                 ├─ app/sessions：创建、加载、恢复、删除与会话浏览
                 ├─ app/catalog：会话列表、标题与 cwd 缓存
                 ├─ app/prompts：发送校验、本地队列与回合结算
                 ├─ app/permissions：权限策略与交互
                 ├─ app/options：模型、模式与配置选择
                 ├─ tasks：任务代际、身份校验与取消
                 ├─ session/runtime：会话、重放事务、outbox、LRU
                 │    └─ session/state + reducer：本地投影及变更版本
                 ├─ ui/panel + chrome：视图、窗口事件、winbar 与动画
                 ├─ ui/chat + transcript + buffer_renderer
                 │    └─ ui/blocks + text：转录内容与排版
                 └─ ui/input + storage/drafts：编辑草稿及持久化
```

Controller 只保留公开入口、会话选择、服务装配和跨模块协调。业务流程由
`app/*` 承担；展示计算与编辑器交互由 `ui/*` 承担。

- `app/*` 不反向依赖 `acp.controller`，也不直接操作 Chat/Input；激活会话通过回调交给控制器。
- `ui/transcript` 只做 block → 行/元数据/位置映射；`ui/buffer_renderer` 只做 buffer 差异写入、高亮与背景 extmark。
- transport 接收与分发表共享 `dispatch_budget_ms`；到期后不再同步派发剩余输入元素，
  改由下一次调度消费。单条 JSON 解码和替换语义的工具更新不可抢占。
- 超过 `spill_bytes` 时，最早的完整 JSON 行异步写入 `stdpath("run")` 下的临时文件。
  磁盘前缀优先于内存后缀；当前文本分片又优先于后续所有消息。`max_pending_bytes`
  估算不完整消息、内存队列、尚未完成的分片、在途写入及已读缓冲的开销，默认 64 MiB。
  工作集阈值不是硬内存上限；正在接收的回调、JSON 对象和临时复制仍有额外开销。
- 创建/写入失败回退内存，部分写入的尾部不计为已提交记录；读取失败则明确报错并断连，
  不在缺失消息的连接上继续执行。排空、停止和退出关闭/删除文件；在途 I/O 回调完成前
  不复用文件描述符。启动时清理 24 小时以上的残留。`max_pending_bytes = 0` 只关闭积压上限。
- 大型追加文本使用惰性派发器，直接消费已解码片段，不重编码或重新分片；工具内容数组、
  diff 和 rawOutput 保持原子替换，避免累计前缀的二次方复制。
- `ui/chat` 监听窗口和编辑器 resize，宽度变化经 100ms 防抖后重排；`ui/viewport` 用
  block/行偏移锚点保留阅读位置。布局刷新不产生新消息标记，流式更新不等待 resize。
- 跟随输出在提交完成后对齐超过一屏的尾部，保留消息原有尾部空行。短转录从顶部正常显示，
  不添加显示占位或 buffer 空行；EOF 钳制区分自然剩余空间与下滚产生的额外空白。
  聊天窗口启用局部 smoothscroll，显式补齐非当前窗口的换行 skipcol；WinScrolled 与重绘后
  的合并检查钳制 EOF 过滚，保留阅读光标，不影响输入区焦点和模式。宽度重排期间不把滚动事件
  误判成用户离开跟随；会话切换/销毁使旧定位请求失效。
- 可选 `ui/decoration` 只在视口及 overscan 区域调度代码/diff 语法装饰。布局保留完整文本、
  conceal 和结构高亮；装饰描述共享源片段，缩进时投影 byte offset。语法有独立 namespace，
  滚动时清理旧视口；共享 CodeHL 的 64 项/2 MiB 缓存，不把解析结果挂回所有历史块。
- 可选 `ui/history_page` 只分页保留 Session 中较早的 block 范围；最新 block 始终物化，
  新输出无需手动加载即可追加。往回加载扩展旧侧，回到底部时再收回预算。Chat 通过 coroutine 按块分批
  构建临时布局，完成后提交（大型提交分片）；会话身份、版本、宽度、主题和视图代次不符时丢弃。
  普通非分页渲染继续使用原有增量路径，避免每次尾部追加都重建全文。
- 分页加载/回收不修改模型；可见块受保护，Visual/Select 期间暂停物化修改。回收清理对应
  block 的 Markdown/diff 缓存。源文本 byte offset 和同源行内偏移用于恢复重排阅读位置，
  无源位置的卡片/结构行保留 block + 渲染行偏移回退。显式全文导出不受页面范围限制。
- `ui/work_scheduler` 统一调度接收尾部、分页排版、语法装饰与大型提交：每个队列每轮最多
  一个时间片，未获执行的类别提升优先级以避免饥饿，协议续跑不越过前序任务。片长用实际耗时衡量；单个任务失败被隔离，
  不会卡住队列。`ui/render_metrics` 提供延迟桶与最近慢任务记录（不含正文）。
- 超过 `ui.render.commit_rows` 的提交通过 `buffer_renderer.write_chunked` 按行写入并让出；
  文本写入被 textlock 拒绝时在下一片重试。分片提交期间内容更新会作废旧任务并标记完整重排，
  避免增量写入基于半份布局。
- `ui/chrome` 拥有 spinner 计时器与重绘合并；`ui/panel` 拥有窗口与窗口事件。
  动画使用可检查存活的 libuv handle，原始 tick 合并，scheduled 上下文更新；停止/关闭的
  handle 在下一次状态或窗口/焦点同步时重建，不额外轮询。
- 动画按当前连接、会话状态及输入窗口可见性同步，隐藏后重开会恢复，后台生成不启动
  隐藏窗口的 timer。销毁 chrome/panel 会释放资源并使其已排队的 UI 回调失效。
- 快捷键与补全在创建 buffer 时绑定一次，窗口重开或缺失视图恢复不重新绑定。
- `completion` 按 buffer 保存会话 getter 与配置，统一识别 `/` 和 `@`，输出 UTF-8 byte
  范围的纯文本编辑。blink/cmp 是可选薄适配器，原生 completefunc 也复用异步请求；显式配置
  source，不修改补全框架的全局选项。请求检查 buffer/tick、会话/cwd、光标及绑定身份并可取消。
- `completion/files` 按项目/发现选项缓存完整路径索引：异步 rg/fd/git 的 NUL 字节流按批处理，
  退出等待所有输出解析完成；无工具时异步遍历目录（不解释 ignore 文件）。LRU、TTL、预算与
  最后订阅者取消限制资源；超限/错误不发布部分索引。匹配前不截断候选，框架自行排序。
- `completion/mentions` 同时供补全与 context 提交解析使用；特殊路径用 JSON 引号转义，支持
  无扩展名、UTF-8、空格和引号。picker 复用索引，通过 vim.ui.select/fzf-lua/Snacks/Telescope
  插入引用，不打开文件、不发请求；只在选中后校验原输入身份并应用编辑。
- `context/image` 只做容器嗅探与内容寻址存储：附件带 path/mime/bytes/sha，不带 base64。
  `context/init.to_prompt` 在发送时按 `inline` 决定 `image` 或 `resource_link` 块，读取失败
  返回错误而不是省略该附件。`context/clipboard` 异步跑平台工具，返回“有图/无图/后端失败”
  三态，避免空的 Wayland 剪贴板回落到 X11 的旧截图，并用 `vim.system` 超时兜住挂起的工具。
- `ui/paste_image` 覆盖 `vim.paste`，仅在光标位于输入区且粘贴内容是单个存在的图像路径时
  接管，其余一律交还原处理器；`app/prompts` 依据 `promptCapabilities.image` 拒绝内嵌图像。
- 断连取消任务后重置 Catalog 的查询合并状态，但保留元信息缓存；重新 setup 则清空
  标题及 cwd 缓存，避免混用不同 Agent/项目的数据。
- `session/runtime` 仍是重放事务、outbox 与 LRU 的唯一实现者，`app/sessions` 只负责编排。

`state()` 是诊断接口，返回值应视为只读，不应绕过运行时修改内部表。诊断视图中的
`titles`、`session_cwds` 与 `pending_permissions` 仍指向控制器持有的表，服务通过 getter
读取，避免测试或集成写入后与服务内部副本分叉。

## 必须保持的不变量

### 会话运行时不等于当前界面

- `S.session` 仅决定当前展示哪个会话，不决定后台任务是否可以结束或继续队列。
- outbox 是稳定对象；历史投影可以替换，但消息数组、字节计数和发送预留共享同一对象。
- 出队消息先预留，接受后确认；本地发送拒绝则恢复。重入的连接/窗口操作不能制造短暂
  的“空队列”来绕过配置保护，也不能重复发送同一预留消息。
- 同一回合只有其 scoped prompt task 负责结算与推进队列，兼容事件不能再次结算它。

### 加载是事务，不是先清空再修补

- Agent 重放通知写入 `runtime.replays[id]` 中的暂存投影，不覆盖可见的旧历史。
- 成功才 commit；失败、取消、删除或断连时 rollback。待发送消息不属于重放内容。
- 选择意图有单独的递增版本。旧加载可完成缓存提交，但不能抢走较新用户操作的选择。
- 运行中缓存会话只切换视图；断连后必须重新 load，才能继续其未发送队列。

### 异步任务必须有明确的所有者和终态

每个任务绑定控制器代际、client 对象及其代际、可选的 session 对象和操作 key/id。
控制器的会话级客户端异步请求经过 `Task:call()`，在挂起前后校验身份；初始化由 Client
自身管理等待者与取消。

- 任务仅进入 `succeeded`、`failed` 或 `cancelled` 中的一种终态。
- 重配置/断连取消旧 scope；删除会话取消该会话的 prompt、重放和设置操作。
- 局部错误回调覆盖挂起后的异常；finalizer 只执行一次，且不能解开新任务持有的锁。
- 取消清理 RPC pending、定时器与可选 await cleanup；迟到响应不恢复已取消协程。
- 初始化的并发调用共享真实完成结果，不能因为“已经在初始化”就提前返回成功。
- RPC 写入失败立即结算；部分写入后失败必须关闭传输，不能把后续请求接到残缺 JSON 后。

### 草稿身份必须显式传递

输入框保存自己的 `{cwd, session_id}`，回调不能读取“当前会话”来猜所有者。内存草稿槽也
包含项目身份。发送被接受后只清理其来源草稿，不能清空发送期间新选中的输入框。

### 语义修改有模型入口

Controller/UI 的折叠、取消、配置修改经 `Session:toggle()`、`cancel_turn()`、
`configure()`、`set_option()` 等入口；通知归约由 runtime 路由到 reducer。
增量渲染依赖 revision：新增模型修改不能绕过 `touch()`。

Session 是受预算约束的本地投影，不是 Agent 的权威历史。渲染仍使用 block 上的私有
Markdown 缓存，本实现不宣称模型完全不可变，也不是 event-sourcing 系统。

## 调度与失败边界

普通通知直接在传输的主循环分发批次中归约；不再逐条转投第二个无预算队列。权限 UI
单独调度并检查身份。exit 延后一轮，以便先执行已经结算的 RPC continuation。

单条 JSON 解码、单块排版和单个 continuation 不可抢占；时间片不是所有代码的硬实时
上限。涉及网络文件系统的退出 flush 也可能等待。

重新 setup 默认拒绝丢弃非空 outbox；调用者可通过第二参数
`{discard_queued = true}` 明确同意重置。队列只在内存保存，不保证重启恢复。
已发请求断线后可能已在 Agent 执行，因此不自动重发；本地任务的单次结算不等于远端
工具 exactly-once 执行。共享草稿文件的多进程写入仍无跨进程事务锁。

## 验证

`tests/spec_lifecycle.lua` 使用可控异步回调测试迟到响应、重入、事务回滚、后台队列、
旧选择器、取消清理、初始化等待者和失败写入。完整协议/界面/重连测试使用 mock Agent；
真实 Agent 的认证、工具副作用和终端交互仍需另行验证。
