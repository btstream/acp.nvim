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
- `ui/chrome` 拥有 spinner 计时器与重绘合并；`ui/panel` 拥有窗口与窗口事件。
- 动画按当前连接、会话状态及输入窗口可见性同步，隐藏后重开会恢复，后台生成不启动
  隐藏窗口的 timer。销毁 chrome/panel 会释放资源并使其已排队的 UI 回调失效。
- 快捷键与补全在创建 buffer 时绑定一次，窗口重开或缺失视图恢复不重新绑定。
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
