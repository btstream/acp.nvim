# ACP Agent 安装管理器实施计划

更新：2026-11-14。状态：阶段 1–5 **已实施**（Linux 上真实验证）；Windows/macOS 未验证。
验证细节见 `docs/status.md`「托管 Agent 安装」。

## 1. 目标

像 Mason 一样，让用户在 Neovim 内查看、安装、更新、卸载 ACP adapter，并将它们放在
`stdpath("data")` 下，无需 `npm install -g`，也不污染项目目录。

首版优先支持 Claude 与 pi，保留 OpenCode 和自定义 Agent 的现有使用方式。

### 1.1 用户体验

```vim
:Acp agents
:Acp install claude
:Acp install pi
:Acp agent claude
```

安装与切换是两个独立操作：安装完成**不会自动切换 Agent、打开会话或登录**。

### 1.2 不做的事情

- 不建设通用包管理器，不复刻 Mason 的完整生态。
- 不依赖 Mason，也不改写用户的 Mason 配置。
- 不自动安装 Node.js、npm 或操作系统依赖。
- 不自动下载或执行远程安装 shell 脚本。
- 不搬迁、删除或统一托管 Agent 的认证信息、历史会话与用户配置。
- 不接管用户已经安装在 PATH 上的程序。
- 不在启动 Neovim、打开面板、检查健康状态时静默联网。
- 首版不支持任意 npm 包名、Git URL、本地目录或远程 registry 清单。
- 首版不实现批量更新、版本列表浏览、自动升级或公开的版本回滚命令。

## 2. 当前代码与接入边界

| 当前入口 | 现状 | 需要的变化 |
|---|---|---|
| `lua/acp/config.lua` | 预设与用户配置递归合并 | 增加管理器配置，保存命令来源信息 |
| `lua/acp/app/connection.lua` | 将 `cfg.agents[cfg.agent]` 直接传给 client | 启动前统一解析托管或外部命令 |
| `lua/acp/protocol/client.lua` | 持有实际启动的 agent 配置 | 保存解析后的启动快照与安装版本身份 |
| `lua/acp/app/auth.lua` | 登录使用配置中的 command/args | 优先复用当前 client 的实际启动快照 |
| `plugin/acp.lua` | 手写 `:Acp` 子命令分发 | 增加管理命令与上下文补全 |
| `lua/acp/health.lua` | 检查配置命令是否可执行 | 展示实际解析来源、托管版本与依赖状态 |
| `lua/acp/app/presenter.lua` | 服务层访问 UI 的边界 | 增加管理界面与确认入口 |
| `lua/acp/app/stores.lua` | 连接、会话、视图分离 | 只保存必要的管理界面引用，不混入安装文件状态 |

原则：不重写 transport、JSON-RPC、会话事务、交互中心与 inline。
安装管理器使用独立异步任务，不把 npm 命令塞进会话 prompt task。

## 3. 首版支持清单与来源核实

### 3.1 内置清单

| ID | 候选来源 | 首版策略 |
|---|---|---|
| `claude` | `@agentclientprotocol/claude-agent-acp` | 核实后加入 npm 托管安装 |
| `pi` | [`georgeharker/pi-acp`](https://github.com/georgeharker/pi-acp)，npm 包 `@geohar/pi-acp` | 用户已指定该 fork，核实发布包后加入 npm 托管安装 |
| `opencode` | 当前外部命令 `opencode acp` | 只检测外部安装，暂不提供下载 |
| 自定义 ID | 用户的 `command` / `args` | 外部命令模式，不推断 npm 包名 |

**包名不是信任证明。** 正式实现安装前必须完成：

1. 核实 npm 包名、维护者、上游仓库与发布链接。
2. 确认 package 的 `bin`、Node engines、支持平台与架构。
3. 确认是否包含 native/optional dependencies、postinstall、额外下载行为。
4. 确认 adapter 是否还要求单独安装 Claude Code / pi CLI，以及如何发现它们。
5. 区分“adapter 安装成功”“底层 CLI 可用”“已认证且可以调用模型”。
6. 记录一次实际安装与 `initialize` 的版本信息。

pi 的目标 fork 已由用户确定：**只使用 `georgeharker/pi-acp` / `@geohar/pi-acp`**，不安装
无 scope 的 `pi-acp`，不在下载失败时回退到原版或其他 fork。
OpenCode 的托管安装作为后续独立任务，不阻塞 Claude/pi 首版。

#### pi fork 核实记录

2026-11-13 读取目标仓库 main 分支的
[`package.json`](https://github.com/georgeharker/pi-acp/blob/main/package.json) 与
[`README.md`](https://github.com/georgeharker/pi-acp/blob/main/README.md)：

- package 名：`@geohar/pi-acp`；源码中版本字段为 `0.4.0`。这不等于已验证 npm 当前发布版本，
  安装阶段仍须核对实际发布包、精确版本与 bin。
- bin：`pi-acp` → `dist/index.js`，ES module，可作为 `node <绝对入口>` 的候选启动方式。
- package engines 写 `node >=20`，README 要求 Node.js 22+；首版按更严格的 **Node.js 22+**
  检查，并在真实验收中确认。
- README 要求 `pi` CLI **v0.80.4+** 可用，包名为 `@earendil-works/pi-coding-agent`；
  adapter 会启动 `pi --mode rpc`，并没有把 pi CLI 声明为自己的 npm 依赖。
- 首版只托管 adapter，检测底层 pi CLI 并提示缺失，不偷偷进行全局安装。未来若要把 pi CLI
  一并装到 Neovim 数据目录，应单列运行时依赖安装任务并获得用户确认。
- README 提供 `piCommand` 设置；具体的 executable 发现与 Windows 行为仍需源码和实测确认。
- `embeddedContext` 在该 fork 的 README 中默认 **true**，可以配置为 false；不能沿用旧
  `svkozak/pi-acp` mock 的 false 默认值推断该 fork。兼容测试需覆盖两种设置。
- 该 fork 增加 resume/close、HTTP MCP 和子代理 plan 等行为；安装成功不等于旧 pi profile
  已完整覆盖这些功能，需单独核对能力握手与报文样本。
- MCP adapter、子代理及桥接扩展属于可选依赖，不因安装 ACP adapter 就自动安装到用户 pi。
- 安装管理器不能自动重写用户 `~/.pi`、项目 `.pi` 配置或设置 `PI_ACP_DATA_DIR` 来搬迁数据。

这些信息来自上游源码/文档，尚未执行真实 npm 安装或 Agent 握手。

### 3.2 Registry 数据结构

内置静态清单放入 `lua/acp/manager/registry.lua`，只包含元数据，不包含任意 shell 模板：

```lua
{
  id = "claude",
  title = "Claude ACP",
  profile = "claude",
  package = "@agentclientprotocol/claude-agent-acp",
  homepage = "...",             -- 实施前核实
  executable = "...",           -- 从已核实的 package.bin 约束得出
  platforms = { "linux", "macos", "windows" }, -- 核实后填写
  prerequisites = {},           -- Node/npm 以外的必要依赖
  installable = true,
}
```

协议 profile 仍由 `acp.agents` 管理；安装元数据与模式、提问、终端输出等协议知识分离。
第一版 Registry 随插件发布，不从网络动态执行或加载 Lua。

## 4. 目录与安装记录

默认根目录：`stdpath("data") .. "/acp/agents"`。

```text
stdpath("data")/acp/agents/
├── claude/
│   ├── current.json
│   └── releases/
│       ├── <install-id-A>/
│       │   ├── package.json
│       │   ├── package-lock.json
│       │   ├── receipt.json
│       │   └── node_modules/
│       └── <install-id-B>/
├── pi/
│   └── ...
└── .locks/
    └── <agent-id>/
```

### 4.1 为什么不使用一个全局 registry.json

全局 JSON 的读改写容易让两个 Neovim 进程互相覆盖。改为**每个 Agent 独立指针和记录**：
Claude 更新与 pi 更新可并行，同一个 Agent 必须串行。
管理界面通过读取各 ID 的记录汇总状态。

### 4.2 不移动装好的 node_modules

部分 npm 依赖、安装脚本或 wrapper 可能记录绝对路径。安装一开始就在唯一的
`releases/<install-id>` 目录进行，该目录在安装过程中不被 `current.json` 引用。
验证完成后，只原子替换 `current.json`；不依赖将 node_modules 从 staging 整体搬家。

### 4.3 安装记录内容

```json
{
  "schemaVersion": 1,
  "agentId": "claude",
  "installId": "unique-id",
  "package": "@agentclientprotocol/claude-agent-acp",
  "version": "精确版本号",
  "entrypoint": "node_modules/包目录/已核实入口.js",
  "runtime": "node",
  "installedAt": "UTC 时间",
  "platform": "linux",
  "arch": "x64"
}
```

- 指针只保存 install ID，不接受记录中任意绝对命令路径。
- entrypoint 必须位于对应 release 目录，检查 `..`、绝对路径和符号链接越界。
- receipt 与 package-lock 不保存 API key、认证环境变量或 npm token。
- Node/npm 的诊断版本可以记录，但 Node 路径在运行时重新检查，不假定永远有效。
- JSON 损坏、版本不认识、入口缺失时标记 `broken`，不可当作“已安装且可运行”。
- 数据目录不是秘密存储，但安装记录与日志仍需限制访问并避免凭据泄漏。

## 5. 配置方案与向后兼容

下面是**拟新增**配置，不是当前 API：

```lua
require("acp").setup({
  agent = "claude",
  manager = {
    root = vim.fn.stdpath("data") .. "/acp/agents",
    npm = "npm",                   -- 可设绝对路径
    node = "node",                 -- 不支持 shell 命令字符串或隐式参数
    install_timeout = 300000,       -- 毫秒，首版要求正数
    max_log_bytes = 1024 * 1024,    -- 每项安装日志预算
  },
  agents = {
    claude = { source = "auto" },   -- "auto" | "managed" | "external"
    pi = { source = "auto" },
  },
})
```

### 5.1 source 语义

| 配置 | 启动来源 |
|---|---|
| `source = "external"` | 原 command/args，只走 PATH 或用户绝对路径 |
| `source = "managed"` | 只运行托管安装；没有或损坏时明确报错，不回落 PATH/npx |
| `source = "auto"` 且显式配置 command 或 args | 视为用户自定义命令，使用 external |
| `source = "auto"` 且没有显式命令覆盖 | 健康的托管安装优先；未安装时保留原来的外部预设 |

- 托管安装存在但损坏时，auto 报错并提供修复提示，不悄悄切换成另一个版本。
- pi 的新默认外部预设应改为 `npx -y @geohar/pi-acp`，与用户指定 fork 一致；显式设置的旧
  command/args 仍按 provenance 保留，不静默改写。此预设迁移在实施阶段 3 完成，本计划编辑
  不修改现有运行配置。auto 下无托管 pi 时该 npx 回退可能联网，必须在 UI/health 明示。
  管理器本身不会自动发起安装；想严格禁止 npx 回退时使用 `source = "managed"`。
- 只覆写 `env` 或 `profile` 不算覆写启动命令。
- 显式 `source = "managed"` 与显式 command/args 同时出现时拒绝配置，避免忽略用户输入。
- `env` 继续作为 Agent 的运行环境，**不自动传给 npm 安装进程**。
- 更新版本由命令参数指定，首版不增加与 manifest 竞争的配置版本字段。
- 修改 root 后不自动迁移旧安装，不删除旧目录。

### 5.2 命令来源不能通过值比较推断

当前 `config.merge()` 会把默认 command/args 填进去，因此合并后无法辨认用户是否显式设置。
也不能用“等于默认 command 就算没改”判断：用户可能就是明确指定了相同字符串。

实施时需在**原始 setup 输入**上收集每个 Agent 的来源标记，独立于用户可序列化配置保存：

```text
launch_origin[agent_id] = { command_explicit, args_explicit }
```

接线要求：

- `acp.setup(opts)`、直接 `controller.setup(opts)` 都能采集。
- 内置 agent 切换当前会 deepcopy 合并配置再 setup；必须显式携带原 provenance，不能把
  所有默认字段误标成用户覆盖。
- 用户主动重新调用 setup 时重新计算来源，不沿用上一次的隐含标记。
- 不把内部来源标记放入用户 env、Agent RPC 或日志配置中。

## 6. 统一命令解析与登录

### 6.1 LaunchSpec

新增纯解析入口：

```lua
Resolver.resolve(config, agent_id, launch_origin) --> spec | error
-- spec:
{
  command = "绝对路径或外部命令",
  args = {},
  env = {},
  profile = "claude",
  source = "managed",             -- 或 external
  install_id = "...",             -- managed 才有
  version = "...",                -- managed 才有
}
```

本地解析不联网，不修改配置，不执行 Agent。
托管 npm 包在核实是 JS bin 时使用 `node <绝对入口.js> ...`，避免依赖全局 PATH、
`npx` 或在 Windows 上执行 `.cmd` 字符串。
不是 JS 入口的包必须有明确的 argv 构造规则，首版不猜测 wrapper。

### 6.2 对话与认证使用同一快照

1. Connection 创建 client 前解析一次 LaunchSpec。
2. client 保存该快照，启动时直接使用。
3. Auth 的 terminal 登录取当前 client 的启动快照，在它的 args/env 上追加登录 descriptor
   的 args/env，继续忽略 descriptor 自带 command。
4. 登录完成的强制重启保留相同安装版本的生命周期保护；不能在登录中途切换 release。
5. 没有活动 client 时的预检查可解析最新指针，但不自动执行登录。

必须覆盖：manager 安装版本和 PATH 版本不同、安装路径含空格、env 覆盖、登录后重连、
外部自定义 wrapper 命令不被改写。

## 7. 安装、更新、卸载事务

### 7.1 状态机

```text
idle → checking → waiting_confirmation → installing → verifying → committing → succeeded
                    └取消                 └失败/取消         └失败
```

界面展示的持久状态与操作状态分开：

- 持久状态：`not_installed` / `installed` / `broken`。
- 运行来源：`managed` / `external` / `legacy_npx` / `unavailable`。
- 操作状态：上面的状态机；同一 Agent 同时只能有一个操作。

### 7.2 install / update 共用流程

1. 检查 Registry、平台、Node/npm、root 可写及配置是否合法。
2. 获取该 Agent 的跨进程锁，再复查安装记录和占用状态。
3. 用户确认来源、版本请求、安装位置和风险；拒绝则释放锁，不创建 package 安装。
4. 解析请求版本为**精确版本**。首版只接受 `latest` 或精确发布版本，不接受 npm range、
   Git URL、本地路径；包名只来自 Registry。
5. 使用唯一 install ID 在最终 release 路径写入最小 package.json，再运行本地 npm install：
   不使用 `-g`，不写项目的 package.json，不使用 shell 拼接。
6. 保留 package-lock，依赖完整性由 npm 按 lock/integrity 检查；这不是额外的发布者身份认证。
7. 校验实际 package 名、精确版本、bin、入口路径和必要文件，再写 receipt。
8. 提交前再检查当前版本是否被连接/登录占用；持锁更新同目录临时指针，原子替换 current.json。
9. 刷新状态并释放锁；安装不自动启动 Agent。

更新失败或取消时，旧 current.json 和旧 release 保持不变。新建但未激活的 release 可以清理，
只能清理本次操作拥有的路径。
相同版本的普通 install 为 no-op；对 broken 版本可重新执行 install，在新 install ID 中修复。

### 7.3 npm 与安装脚本的安全边界

- 明示：第三方 npm 包及其 lifecycle scripts 可按当前用户权限执行代码，不是沙箱。
- 是否可使用 `--ignore-scripts` 必须按 adapter 验证；不默认宣称禁用脚本后所有包仍可运行。
- 不额外继承 `agents.<id>.env`；npm 仍可能读取用户 npmrc、代理、环境与缓存。
  在确认提示里说明这点，不擅自改写用户 npm 配置。
- 版本检查与安装命令都走受限 argv；禁止 ID、版本、路径成为 shell 片段。
- 日志脱敏后再落盘，输出按字节预算截断；不把完整环境打印到管理窗口。
- `latest` 仅由用户主动 install/update 时查询，不周期性探测更新。

### 7.4 uninstall

1. 确认仅移除当前 ID 的托管副本，不处理 PATH 程序和账号信息。
2. 获取锁并验证 root、目标目录与 receipt 的归属。
3. 活动连接、登录终端或其他进程 lease 存在时拒绝，先让用户主动断开/关闭登录。
4. 先原子解除当前指针，再删除已确认属于管理器的 release。
5. 部分清理失败时报告残留路径，不恢复成“健康已安装”的假状态。

不允许通过未知 ID、篡改 manifest、`..` 或符号链接逃逸来递归删除 root 外的路径。
root 不能是 `/`、用户 home、项目根或仅靠字符串前缀判断的任意目录；配置可指向专用目录，
但所有删除都需再次校验规范化路径及管理器 marker。

### 7.5 进程占用与多 Neovim 实例

仅检查当前编辑器的 client 不够，第二个 Neovim 可能也在运行同一 release。

- 每个 Agent 使用跨进程原子锁（例如原子 mkdir），记录 PID、实例 ID、时间及操作 ID。
- 启动托管 client、启动登录和 install/update/uninstall 的提交检查共用这一把锁。
- 启动前写入 release lease，启动失败移除；process 退出释放，对登录终端也同样处理。
- 旧版本占用不被当前指针切换掩盖；lease 记录精确 install ID。
- 首版保守地拒绝更新/卸载被占用的 Agent，不自动杀进程、不静默断开。
- PID 复用、系统崩溃和 stale lock 不能仅凭时间自动认定安全：保留恢复诊断，用户确认后才
  清除无法证明存活的锁；实现前确定各支持平台的活性检查能力。
- release 的垃圾回收只针对明确无 lease 的旧版本，不能在每次启动时广泛递归删除。

### 7.6 取消与退出

- `q` 关闭管理界面不等于取消安装，后台任务继续并发送完成通知。
- 显式取消操作需终止所拥有的 npm 任务；子进程树的清理由平台实现决定并测试。
- Neovim 退出时取消本实例任务，尽力释放锁；如果无法确认子进程已退出，不能提前释放锁
  让下一次安装与旧进程竞争。
- 安装超时是失败终态，不触发自动重试或自动删除旧版本。
- npm 后代进程清理不能在 Windows/Unix 上一概声称由 `jobstop` 保证；必须有平台实测。

## 8. 命令与 Lua API

以下命令拟新增，原有 `:Acp agent [name]` 保持切换语义：

| 命令 | 行为 |
|---|---|
| `:Acp agents` | 打开安装管理器，不启动模型、不联网 |
| `:Acp install <id> [version]` | 安装；默认 latest，第一次必须确认 |
| `:Acp update <id> [version]` | 更新已安装副本；未安装则提示使用 install |
| `:Acp uninstall <id>` | 确认后移除托管副本 |

首版取消与查看日志通过管理窗口操作，不增加一组模糊的 `:Acp stop` 重载语义。
`:Acp stop` 继续只取消模型回合。

Lua API 拟采用 opts 表，不接受一个任意 shell 命令字符串：

```lua
require("acp").manage_agents()
require("acp").install_agent("claude", { version = "latest" })
require("acp").update_agent("claude", { version = "精确版本" })
require("acp").uninstall_agent("pi")
```

公共 API 同样走确认与占用保护，首版不提供默认跳过确认的参数。
install 不应通过 `ensure()` 隐式创建 chat/input 或断开当前 Agent。

### 8.1 命令补全

- 第一个参数补全既有和新增子命令。
- install 只补全可安装的 Registry ID；update/uninstall 只补全托管记录存在的 ID。
- 不从 Agent ID 自动推导 npm 包名。
- 版本不做联网补全，用户可输入精确版本。
- 使用 `fargs` 解析简单参数数量，保持 inline/image 等现有命令的 rest/range 行为不变。

## 9. 管理界面

独立浮窗，filetype 为 `acp_agents`，不占用 `acp_chat` / `acp_input`，不用重建 panel。

```text
ACP Agents

Claude ACP   managed   已安装   <version>
pi ACP       external  未托管   npx -y @geohar/pi-acp（可能联网）
OpenCode     external  PATH     /.../opencode

当前项：Claude ACP
安装包：@agentclientprotocol/claude-agent-acp
位置：.../acp/agents/claude
状态：空闲

i 安装   u 更新   d 卸载   Enter 使用
l 日志   c 取消任务   r 刷新本地状态   q 关闭
```

- 已安装版本只读 receipt，不执行未知的 `--version`（有的 adapter 会启动协议进程）。
- external 显示实际 PATH 路径，无法安全探测版本时显示“未知”，不伪造版本。
- Enter 复用现有 Agent 切换入口及其排队消息/运行回合提示。
- 不把“Installed”“Ready”“Authenticated”混为一谈。
- 安装输出节流刷新，不为每一行输出做完整重绘；日志必须有上限。
- 所有异步回调检查窗口、操作 ID 和配置代际，旧结果不能写入新窗口或重配置后的 root。
- 关闭/重开窗口只订阅任务状态，不重复启动下载。
- 无图标模式、窄屏、主题刷新、退出与 buffer wipe 都有测试。

## 10. 模块方案

```text
plugin/acp.lua + acp/init.lua
  └─ app/agent_manager.lua          用户动作编排与确认、配置代际
       ├─ manager/registry.lua     本地包元数据
       ├─ manager/state.lua        操作状态、订阅、单次结算
       ├─ manager/store.lua        receipt/current 指针、受限文件操作
       ├─ manager/lock.lua         跨进程锁与运行 lease
       ├─ manager/npm.lua          npm argv、依赖检查、版本解析
       ├─ manager/install.lua      install/update/uninstall 事务
       └─ app/presenter.lua
            └─ ui/agent_manager.lua

app/connection.lua + app/auth.lua + health.lua
  └─ manager/resolve.lua            同一个 LaunchSpec 解析器
       ├─ manager/registry.lua
       └─ manager/store.lua
```

这些模块是职责划分，不是必须一次性建立全部空文件；只有在实现有明确调用方时才建模块。

约束：

- manager 底层不 require controller、ui 或 session；依赖注入进程 runner、时钟与通知。
- resolver 不调用 npm、不创建安装目录。
- UI 不直接运行安装命令或删除文件。
- controller 继续是薄入口，不因安装管理重新膨胀。
- installer 的锁、日志和状态归 manager 所有，不塞回全局 controller store。
- 连接 lease 的释放跟真实 process/login 终态绑定，而不是简单跟“隐藏面板”绑定。

## 11. 测试策略

### 11.1 单元测试（默认离线）

- Registry ID/package/bin 白名单、未知平台与未知 ID。
- 配置 provenance：显式默认同值、仅 env 覆盖、只改 args、Agent 切换 deepcopy、再次 setup。
- resolver 三种 source、managed 损坏、PATH 失效、旧 npx 回退提示。
- Node/npm argv、路径含空格/中文、恶意 version、非 JS executable 拒绝。
- manifest 损坏、未知 schema、入口越界、符号链接、marker 缺失。
- 指针提交原子性、更新失败旧版本可用、无全局文件丢写。
- 锁竞争、陈旧锁、lease 生命周期、第二个实例占用。
- 任务成功/失败/取消/超时只结算一次，迟到回调不能重新提交指针。
- 输出超限、凭据脱敏、UI 关闭后安装继续。

### 11.2 假 npm 进程集成

增加本地 fixture，模拟 `npm view` / `npm install`，生成最小 package/bin/lock：

- 正常安装；命令失败；下载中超时；验证失败；取消；更新失败。
- 包名或版本与请求不符；bin 缺失；入口指向目录外。
- 大量 stdout/stderr，确认不卡 UI 且日志有界。
- 同 ID 两个进程竞争，只有一个获锁；不同 ID 独立安装。
- 安装目录含空格；重配置 root 后迟到结果只能清理自己原来的目录。

fixtures 放在专用测试数据目录，禁止测试触碰用户真实 npm 或真实数据目录。
默认测试不联网、不安装全局包、不读用户认证信息。

### 11.3 client/auth 接线测试

- managed adapter 成为实际 ACP 子进程，initialize/new/prompt 仍走现有协议栈。
- PATH 上放另一版本，确认没有被错误选中。
- 登录 command/args 取当前 client 的快照，正确追加 descriptor args/env。
- 登录期间 update/uninstall 被拒绝，失败登录和断线都释放正确 lease。
- 自定义 wrapper、旧 OpenCode 配置、旧 npx pi 行为不回退。
- install 命令不创建 chat/input、不调用模型、不改变当前 Agent。

### 11.4 真实安装验收（显式联网、人工执行）

| 平台 | 首版要求 |
|---|---|
| Linux | Claude/pi 的实际安装、启动、登录、更新与卸载完整验证 |
| macOS | 路径、npm/node 探测、启动与取消验证 |
| Windows | JS bin 的 node 启动、路径转义、进程树清理、指针替换与文件占用验证 |

未验证的平台标注 experimental，不把 mock 的通过算作真实支持。
真实测试使用临时项目，不请求修改用户仓库。
握手与模型请求分开：安装验证默认不执行 prompt；真实对话会消耗服务额度，由用户主动触发。

## 12. 分阶段实施与验收

> **实施结果**：阶段 0–5 已完成，1187 项测试通过。真实安装与握手在 Linux 上验证；
> 阶段 5 的跨平台与真实模型对话部分仍然未做，见各阶段验收。

每阶段先写失败测试，再补实现；独立提交，不合并成一次大重构。

### 阶段 0：来源核实与设计冻结

- 核实 Claude/pi 包、bin、底层 CLI、平台、安装脚本与版本要求。
- 决定第一版实际支持平台，不把未经验证的包标成 installable。
- 固定 source 语义、provenance 保存方式、锁与 lease 的平台策略。
- 建立假 npm fixture 的报文与失败场景。

**验收**：包信息有可追溯证据，安装不会猜来源；剩余不确定项明确阻塞对应 adapter。

### 阶段 1：Registry、store 与锁

- 实现记录读取、路径归属校验、精确 install ID 与每 ID 指针。
- 实现每 Agent 互斥锁与基础 lease。
- 测试不合法路径、符号链接、损坏记录、多进程竞争。

**验收**：离线读写正确，不会覆盖其他 ID，不会删除 root 外的文件。

### 阶段 2：npm 安装事务与命令

- 实现依赖检查、精确版本解析、install/update/uninstall、取消、超时、日志预算。
- 新命令先以已有 picker/通知呈现确认，不等待专用管理窗口。
- 所有破坏性动作只作用于管理器目录。

**验收**：假 npm 端到端全过；更新失败/取消后旧版本保持可用；安装动作与模型连接独立。

### 阶段 3：运行时统一解析

- 增加 source 配置与命令来源 provenance。
- Connection/Auth/Health 共用 resolver，建立 release lease。
- Agent 切换和 terminal 登录保持原配置来源及实际版本。

**验收（M1：可用安装后端）**：真实本地 adapter 可启动，不需全局 npm 安装；PATH 上不同
版本不被误用，自定义配置优先级明确，现有 OpenCode 测试全绿。

### 阶段 4：管理界面

- 实现 `:Acp agents`、状态订阅、安装/更新/卸载、日志、取消、使用。
- 完成命令补全与 health 的实际启动来源展示。
- 窗口关闭、重配置和迟到操作有完整身份保护。

**验收（M2：Mason 风格操作）**：不离开 Neovim 完成安装与选择；界面不触发自动下载，
不会抢占聊天窗口，任务进度可见且日志有界。

### 阶段 5：真实验证、文档与发布

- 按平台清单实测 Claude/pi，记录 npm 包版本、adapter 版本、Node/npm、OS。
- 更新 README、`:help acp.nvim`、architecture、status。
- 写迁移说明：旧 command/args 仍有效；auto/managed/external 的选择；认证目录不变。
- 记录支持/实验性平台与已知限制。

**验收（M3：可发布）**：全量既有测试、安装测试、格式与 diff 检查通过；完成的平台有真实
记录；没有用“安装成功”冒充“已认证并可调用模型”。

## 13. 风险与应对

| 风险 | 应对 |
|---|---|
| 包名对应错误 fork 或被接管 | Registry 先核实来源；显示包/版本；不接收任意包名 |
| npm scripts 执行任意代码 | 安装前说明风险；不宣称沙箱；最小化环境传播 |
| 旧配置被托管安装覆盖 | 显式命令 provenance + source 规则 + deepcopy 切换回归 |
| 登录与对话使用不同版本 | 使用 client 的 LaunchSpec 快照与精确 release lease |
| 多 Neovim 同时安装/使用 | 每 ID 跨进程锁，启动与提交共用互斥，lease 保护 |
| 取消后 npm 子进程继续写目录 | 平台进程树终止验证；不能确认退出就不释放安全保护 |
| node_modules 移动后失效 | 在最终 release 路径安装，只切换小指针 |
| 清理误删用户数据 | 专用 root、marker、路径规范化与 symlink 越界检查 |
| 自动回退运行了另一个版本 | managed 坏掉明确失败；auto 的旧 npx 行为显式提示 |
| 上游模型服务不可用 | 安装/握手/认证/模型调用分开报告 |

## 14. 待确认与默认建议

以下是本计划的**建议默认值**，尚未代表用户已逐项批准：

已确认的来源选择：pi 使用 `https://github.com/georgeharker/pi-acp`，对应 npm 包
`@geohar/pi-acp`。以下其他选择仍是建议。

1. 首版只托管 Claude/pi adapter，OpenCode 保留外部安装。
2. 使用专用 `stdpath("data")/acp/agents`；Node/npm 由用户安装。
3. 安装必须确认；打开面板不自动安装；不做静默更新。
4. 默认 source=auto，但显式 command/args 永远保留优先权；严格托管可选 managed。
5. 被会话或登录占用时拒绝更新/卸载，不自动断开连接。
6. 首版只支持内置 Registry，不开放任意包来源或自定义安装脚本。
7. 先交付后端和连接接线，再做管理窗口；每阶段独立测试与提交。

预计工作量：来源核实与后端/锁约 2–3 天，运行时接线约 1–2 天，UI/文档约 1–2 天；
跨平台进程清理与真实认证问题可能额外增加时间。此为工作量估算，不是交付承诺。
