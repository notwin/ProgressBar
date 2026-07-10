# ProgressBar 本地 Agent 任务接入设计

- 日期：2026-07-10
- 状态：设计已确认，等待书面规格复核
- 范围：本地 Claude Code 与 Codex 的项目、会话、Goal、Plan、Todo 只读镜像，以及手动接管为 ProgressBar 普通任务

## 1. 背景与目标

ProgressBar 当前把用户主动维护的分区、任务和进展日志保存在 `data.json`，优先通过 iCloud Drive 在多台 Mac 之间同步，并保留本地备份。应用另有 Node.js MCP server，直接读写同一份用户数据。

本功能增加一个本机「Agent」视图，汇总 Claude Code 和 Codex 正在执行的工作。Agent 运行数据具有临时、本机相关、格式可能随客户端版本变化等特点，不值得进入 iCloud；只有用户明确“接管”的任务才成为长期用户数据。

目标：

1. 按“项目 → 会话 → 子任务”展示本机未完成的 Claude Code 与 Codex 工作。
2. Agent 数据只读，不反写 `~/.claude` 或 `~/.codex`。
3. 用户可把某个 Agent 子任务接管为普通 ProgressBar 任务。
4. Agent 索引失败或损坏不能影响现有 `data.json`、iCloud、日历或 MCP 功能。
5. 保持现有用户数据模型与 iCloud 同步方式不变。

## 2. 非目标

- 不把 Agent 会话、Plan、Todo 或绝对项目路径同步到 iCloud。
- 不在 ProgressBar 中暂停、完成或重排 Claude Code / Codex 内部任务。
- 不同步完整聊天记录、工具调用、终端输出或模型推理内容。
- 不从普通对话文本推测任务；没有结构化数据时宁可少显示。
- 不在本阶段迁移现有 `data.json` 到 SQLite。
- 不增加账号系统、CloudKit、Supabase 或其他远端后端。

## 3. 已验证的数据源

### 3.1 Claude Code

本机 Claude Code `2.1.206` 把结构化任务写在：

```text
~/.claude/tasks/<session-id>/<task-id>.json
```

已验证字段包括：

- `id`
- `subject`
- `description`
- `activeForm`
- `status`
- `blocks`
- `blockedBy`

状态包括 `pending`、`in_progress`、`completed`。会话与项目的关联可通过 `~/.claude/projects/**/<session-id>.jsonl` 定位。

该目录属于 Claude Code 的本地实现格式，不视为稳定公开 API。连接器必须做 schema 检查、版本隔离和 fail-closed 处理。

### 3.2 Codex

本机 Codex 为 `codex-cli 0.144.1`。官方 `codex app-server` 提供：

- `thread/list`：分页读取本地会话。
- `thread/read`：读取指定会话；需要时包含 turns。
- `thread/goal/get`：读取线程 Goal。
- `turn/plan/updated`：结构化 Plan 更新，步骤含 `step` 与 `pending / inProgress / completed` 状态。

Goal 状态包括 `active`、`paused`、`blocked`、`usageLimited`、`budgetLimited`、`complete`。

历史会话不保证包含可恢复的结构化 Plan。若 `app-server` 只能返回会话或 Goal，界面只显示这些可靠数据，不解析助手自然语言或工具参数来补齐 Plan。

## 4. 总体架构

```text
~/.claude/tasks + ~/.claude/projects
                  ↓
          ClaudeTaskConnector
                  ↓
             AgentStore
                  ↑
           CodexConnector
                  ↑
          codex app-server

AgentStore → agent-index.sqlite → AgentView
                                  ↓ 手动接管
                            AppState / data.json
                                  ↓
                                iCloud
```

数据边界：

- `data.json`：用户数据，继续 iCloud 同步。
- `agent-index.sqlite`：本机可重建缓存，不进入 iCloud。
- `AgentView`：虚拟分区，不插入 `AppData.sections`。
- 接管后生成普通 `TaskItem`；之后与来源完全解耦。

## 5. 组件设计

### 5.1 AgentConnector

两个来源实现统一只读协议：

```swift
protocol AgentConnector {
    var source: AgentSource { get }
    func scan() async throws -> AgentSnapshot
}
```

`AgentSnapshot` 包含项目、会话、任务项、依赖关系、来源更新时间和连接器版本。连接器只负责读取与规范化，不直接操作 UI 或用户任务。

### 5.2 ClaudeTaskConnector

职责：

1. 扫描 `~/.claude/tasks` 下发生变化的 JSON 文件。
2. 校验已知字段类型；单文件损坏时跳过，不中止整轮扫描。
3. 用 session id 定位对应 project transcript，从路径或 transcript 元数据获得项目路径和会话标题。
4. 导入 `blocks` 与 `blockedBy`，供详情视图展示。
5. 不把 transcript 正文保存到 SQLite。

为避免每 10 秒重读所有大型 JSONL，`agent_scan_state` 保存文件大小、修改时间和已知 session 映射。只有新 session 或映射失效时才重新定位 transcript。

### 5.3 CodexConnector

职责：

1. 解析 `codex` 可执行文件。优先使用用户设置路径，其次检查 GUI 应用常见位置，包括 `/opt/homebrew/bin`、`/usr/local/bin` 与 `~/.local/bin`。
2. 以 `stdio` 启动独立 `codex app-server`，完成 `initialize / initialized` 握手。
3. 分页调用 `thread/list`，优先处理非归档、近期更新的会话。
4. 对候选会话读取 Goal；有可靠结构化 Plan 时同步步骤。
5. 连接失败时结束子进程，记录来源错误并保留上次成功缓存。

连接器不直接读取或修改 Codex 认证材料。ProgressBar 不保存 token，也不调用会产生模型用量的 `turn/start`。

### 5.4 AgentStore

文件位置：

```text
~/Library/Application Support/ProgressBar/agent-index.sqlite
```

使用系统 SQLite，并通过单一 actor 串行执行迁移、查询与写入。数据库开启 foreign keys；写入使用事务。它是派生缓存，损坏时可备份并重建。

建议表：

#### `agent_projects`

- `id`：本地 UUID
- `source`：`claude` 或 `codex`
- `source_project_key`：来源侧稳定键或规范化路径
- `display_name`
- `cwd`：仅本地保存
- `last_seen_at`
- 唯一约束：`source + source_project_key`

#### `agent_sessions`

- `id`：本地 UUID
- `project_id`
- `source_session_id`
- `title`
- `status`
- `source_updated_at`
- `last_seen_at`
- 唯一约束：`source + source_session_id`

#### `agent_items`

- `id`：本地 UUID
- `session_id`
- `source_item_id`
- `kind`：`goal / plan_step / todo`
- `title`
- `description`
- `status`
- `sort_order`
- `source_updated_at`
- `last_seen_at`
- `completed_at`
- 唯一约束：`source + source_session_id + source_item_id`

#### `agent_item_links`

- `item_id`
- `related_source_item_id`
- `relation`：`blocks / blocked_by`
- 唯一约束：`item_id + related_source_item_id + relation`

#### `agent_adoptions`

- `source`
- `source_session_id`
- `source_item_id`
- `progressbar_task_id`
- `target_section_id`
- `state`：`pending / completed / failed`
- `adopted_at`
- 唯一约束：`source + source_session_id + source_item_id`

#### `agent_scan_state`

- `source`
- `connector_version`
- `last_scan_at`
- `last_success_at`
- `last_error`
- `cursor_data`

每次成功扫描在一个事务中 upsert snapshot、更新 `last_seen_at` 和 scan state。失败扫描不能把旧数据标记为消失。

## 6. 状态规范化与可见性

统一状态：`pending / in_progress / blocked / done`。

| 来源状态 | 统一状态 |
| --- | --- |
| Claude `pending` | `pending` |
| Claude `in_progress` | `in_progress` |
| Claude `completed` | `done` |
| Codex Plan `pending` | `pending` |
| Codex Plan `inProgress` | `in_progress` |
| Codex Plan `completed` | `done` |
| Codex Goal `active` | `in_progress` |
| Codex Goal `paused / blocked / usageLimited / budgetLimited` | `blocked` |
| Codex Goal `complete` | `done` |

主 Agent 分区只显示存在未完成 item 的会话。全部完成的会话进入 Agent 历史，保留 30 天后清理。`agent_adoptions` 不随历史清理删除，以阻止无意重复接管。

## 7. 刷新策略

- App 启动后异步扫描一次，不阻塞主窗口。
- Agent 分区可见时每 10 秒增量扫描。
- Claude 任务目录变化后 debounce 1 秒再扫描。
- 用户可手动刷新。
- 同一来源同一时间只允许一轮扫描；新触发合并到下一轮。
- App 退到后台时停止 10 秒轮询，保留低频文件变化触发。
- 每个来源独立显示 `last_success_at` 和错误状态。

## 8. UI 设计

采用已确认的 A 方案：层级折叠列表。

- `Agent` 是固定虚拟标签，位于普通分区之后、添加按钮之前。
- 标签数字为当前未完成 Agent item 数。
- 页面标题显示项目、会话和未完成 item 数量。
- 顶部提供刷新按钮和 Agent 历史入口。
- 项目按最近更新时间排序；项目下展开会话，会话下展开任务项。
- 会话显示 Claude/Codex badge、标题和更新时间。
- item 显示状态、标题和“接管”按钮；展开后显示描述与依赖关系。
- 来源暂不可用时在页面顶部显示非阻塞提示，并继续显示缓存数据。
- 已接管 item 显示“已接管”，可定位到目标普通任务。

Agent 分区不提供新增、编辑、改状态或删除来源 item 的控件。

## 9. 接管流程与一致性

1. 用户点击 item 的“接管”。
2. 弹出面板，标题可编辑；目标分区默认为上次访问的普通分区，用户可以改选。
3. 根据统一状态创建普通任务，deadline 为空。
4. 新任务增加第一条日志：`从 <来源> 会话「<会话标题>」接管`。
5. 接管完成后，来源 item 与用户任务彻底解耦。

由于 SQLite 与 `data.json` 无法共享事务，接管采用可恢复的两阶段流程：

1. 预先生成 `progressbar_task_id`，在 SQLite 插入 `pending` adoption。
2. 用该固定 ID 创建普通 `TaskItem` 并执行现有原子 JSON 保存。
3. JSON 保存成功后把 adoption 标记为 `completed`。
4. 重试时先按固定 task ID 检查 `data.json`：已存在则只补全 mapping，不存在才创建。

这保证进程在任一步骤退出后可恢复，且重复点击不会生成两个普通任务。若用户后来删除目标任务，mapping 仍保留，界面显示“已接管任务已删除”；只有显式“重新接管”才创建新任务。

接管不修改 `TaskItem` schema，避免给现有 iCloud 数据增加迁移负担。

## 10. 错误处理与安全

- 单个 Claude JSON 损坏：记录文件级错误并跳过。
- Claude schema 不匹配：该来源标记为不兼容，保留旧缓存。
- Codex CLI 不存在：显示设置入口，Claude 连接器继续工作。
- app-server 超时或退出：终止子进程，保留旧缓存，按退避策略重试。
- SQLite migration 失败：不打开 Agent 分区，保留数据库供诊断。
- SQLite 文件损坏：复制为带时间戳的 `.corrupt` 备份，再建立空索引并重新扫描。
- 扫描永远是只读操作，不执行来源文件中的命令或伪装指令。
- 绝对路径、错误详情和 Agent 描述只存在本机 SQLite，不写入 iCloud。
- 日志与 UI 不输出认证材料或完整 transcript。

## 11. 测试设计

### 单元测试

- Claude 已知 schema、缺失可选字段、未知状态和损坏 JSON。
- Codex app-server response 与 notification 解码。
- 两个来源的状态规范化。
- SQLite schema migration、foreign keys、唯一约束和幂等 upsert。
- 历史 30 天清理与 adoption 保留。
- 两阶段接管的正常、崩溃恢复和重复点击路径。

### 集成测试

- 用临时目录模拟 `~/.claude/tasks` 与 project transcript。
- 用假 stdio app-server 返回分页 threads、Goal、Plan 和错误。
- 同时扫描两个来源，验证一个失败不影响另一个。
- 来源任务完成、消失或重新出现时验证历史行为。
- Agent SQLite 删除后可从来源重建。

### 回归验证

- `swift test`
- 使用与 `Scripts/build.sh` 一致的真实 `swiftc` 编译，并链接 SQLite。
- `npm run build --prefix mcp-server`
- 12 个 locale 的 `.strings` 语法与 key 集合校验。
- 现有任务 CRUD、归档、日志、日历同步、Quick Input、MCP server 与 iCloud JSON 路径不变。
- 最终工作树检查，确认未提交 Agent 缓存、fixture 生成物或视觉伴侣文件。

## 12. 验收标准

1. Agent 分区能显示本机 Claude Code 与 Codex 的项目、会话和可靠结构化未完成任务。
2. 关闭任一来源或制造单项损坏时，应用不崩溃，另一来源和旧缓存仍可用。
3. Agent 数据只存在 `agent-index.sqlite`，没有写入 iCloud。
4. 接管一次只生成一个普通任务，并进入现有 `data.json` / iCloud 流程。
5. Agent 来源后续变化不修改已接管任务。
6. 删除 `agent-index.sqlite` 后能安全重建，不影响用户数据。
7. 现有 Swift app、MCP 构建、本地化和关键用户流程全部通过回归验证。

## 13. 实施边界

实施计划应拆成以下阶段，每阶段可独立验证和回退：

1. Agent domain model、SQLite store 与 migration。
2. Claude connector 与 fixtures。
3. Codex app-server client 与 connector。
4. Agent 虚拟分区及层级列表 UI。
5. 两阶段接管与普通任务定位。
6. 错误状态、历史清理、设置与全量回归。

任何阶段都不得把 Agent SQLite 放入 iCloud，也不得用直接读取 Codex SQLite 代替已确认的 app-server 主路径。
