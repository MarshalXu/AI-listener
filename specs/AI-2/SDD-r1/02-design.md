# Design

## 组件边界

| 组件 | 职责 | 不负责 |
|---|---|---|
| `RecordingView` | 呈现用途、权限、状态、双路指示、停止、结果与播放控制 | 直接访问采集 API 或写文件 |
| `RecordingCoordinator` | 唯一状态机所有者；串行处理 intent/event；编排权限、采集、落盘、播放 | 保存音频帧 |
| `PermissionGateway` | 查询/请求麦克风权限；查询 Screen Recording 授权；提供系统设置恢复路径 | 自动修改系统设置、循环请求 |
| `MicrophoneCapture` | 通过 AVFoundation 产出麦克风 PCM buffer 与格式/时间信息 | 系统音频、文件生命周期 |
| `SystemAudioCapture` | 通过 ScreenCaptureKit、排除本应用音频，产出系统 PCM buffer 与格式/时间信息 | 屏幕视频持久化、窗口标题采集 |
| `SessionFileStore` | 创建会话目录、管理两路临时文件、追加、关闭、完整性检查、原子提交、清理 | 上传、长期归档策略 |
| `LocalPlayback` | 播放用户选中的已提交本地轨道，报告完成/失败 | 网络播放、混音 |
| `Diagnostics` | 结构化、脱敏的状态/错误/计数事件 | 音频 buffer、完整路径、窗口/应用标题 |
| `Clock`/`IDGenerator` | 可注入时间与 ID，便于确定性测试 | 业务状态 |

所有状态突变在单一串行执行域内发生。采集回调不得直接修改 UI 状态；它们只向协调器/文件存储发送带轨道和时间戳的事件。实现应采用 Swift concurrency 或等价串行机制，但具体类型留给获批后的实现任务。

## 状态机

### 状态语义

- `idle`：无活跃采集；可发起开始。
- `requestingPermission`：展示用途、查询或请求权限、检查两路可用性并准备资源；不可重复开始。
- `recording`：两路都已成功启动并已各自观察到首个有效 buffer。
- `stopping`：拒绝新开始；按顺序停止输入、排空写入、关闭、检查并提交文件。
- `succeeded`：当前会话两份已提交文件可供逐一播放；可回到 `idle` 开始新会话。
- `failed`：会话未满足成功不变量；呈现错误与恢复动作；无采集资源继续运行。

### 转移表

| 当前 | 事件/守卫 | 动作 | 下一状态 |
|---|---|---|---|
| `idle`/`succeeded`/`failed` | `startTapped` | 创建 session；显示用途；开始权限流程 | `requestingPermission` |
| `requestingPermission` | 用户取消 | 释放准备资源 | `idle` |
| `requestingPermission` | 任一权限 denied/restricted | 不启动采集；记录稳定错误 | `failed` |
| `requestingPermission` | 权限均允许但任一路预检不可用 | 不启动或回滚已准备资源 | `failed` |
| `requestingPermission` | 两路启动且均收到首 buffer | 设 `startedAt`；开始计时 | `recording` |
| `requestingPermission` | 启动/首 buffer 超时或写入初始化失败 | 原子回滚两路与临时文件 | `failed` |
| `recording` | `stopTapped` | 冻结停止意图；停止两输入并排空 | `stopping` |
| `recording` | 运行期采集/写入失败 | 发起失败停止并保存首要错误 | `stopping` |
| `stopping` | 两路停止、关闭、校验和提交均成功，且无先前错误 | 生成两个 `AudioArtifact` | `succeeded` |
| `stopping` | 停止/排空/关闭/校验/提交任一步失败，或已有运行期错误 | 清理活跃资源；标记失败工件 | `failed` |
| 任意非 `stopping` | 应用终止/取消 | best-effort 释放；临时文件不提交 | 下次启动恢复 |

无效事件（如 `recording` 时再次 start）被忽略并记录计数，不改变状态。`stopTapped` 幂等：首次触发停止，重复点击无副作用。失败后允许用户按建议修复并重试，新尝试必须创建新 session。

## 权限流程

### 麦克风

1. 用户点击开始后先展示用途与本地保存说明。
2. `authorized`：继续。
3. `notDetermined`：仅在用户确认后调用系统请求；等待结果。
4. `denied/restricted`：进入 `failed(permission.microphoneDenied)`；提供 System Settings → Privacy & Security → Microphone 路径。
5. 返回应用后只在用户点击“重新检查”或再次开始时查询；不自动反复弹窗。

### Screen Recording / 系统音频

1. 在同一用途说明中解释系统音频采集依赖 Screen Recording 权限，即使不保存视频。
2. 使用系统预检 API 查询授权；未授权时，仅在用户确认后触发系统请求。
3. 未授予或系统要求重启应用：进入 `failed(permission.screenRecordingDenied|RestartRequired)`，提供 System Settings 路径与重新检查/重启说明。
4. 禁止以私有 API 绕过；禁止假定请求返回即已生效。

权限检查顺序不应制造多余弹窗；建议先展示统一说明，再依次处理 microphone 和 Screen Recording。两项均通过前不得启动任何一路。权限撤销在运行中被视为采集失败，执行失败停止。

## 双路采集与启动原子性

1. 创建会话目录和两个 `.partial` 目标，校验可写空间。
2. 配置麦克风 AVFoundation capture 与 ScreenCaptureKit stream；后者只请求音频、不持久化视频，并排除当前应用音频以减少播放回采。
3. 捕获并保存每路实际 `AudioFormat`；格式不匹配不实时重采样。
4. 启动两路；只有两路均在启动超时内收到首个可写 buffer，才进入 `recording`。
5. 任一路失败则停止另一路、关闭 writer，并按失败策略处理 partial；不降级为单路。
6. 每个 buffer 记录相对会话单调时钟的首帧时间与 frameCount；不得使用墙钟推导对齐。

## 数据生命周期

`intent → permission metadata → session directory → two partial files → append buffers → stop/drain → close → validate → atomic rename to final → playback/read → explicit user deletion or OS/container lifecycle`

- 会话路径由应用容器 Application Support 下的固定相对目录和 UUID 构成；UI 可通过受控“显示位置”展示。
- `.partial` 不作为成功工件，不可进入播放列表。
- 最低完整性检查：文件存在、大小大于容器头、可读取音频属性、frameCount > 0。
- 成功后仅保留两份 final CAF 与小型 manifest；默认不自动上传、不自动删除。
- 用户删除功能不属于本尖刺；测试数据清理通过受控测试夹具。正式保留/删除 UX 需后续规格。
- 下次启动扫描孤立 partial：仅标记 `abandoned` 并提供安全清理；不得自动把它提升为成功工件。

## 停止、写入与播放

停止顺序：状态切为 `stopping` → 禁止新 buffer 接受边界 → 请求两采集源停止 → 等待已接收 buffer 串行落盘 → 关闭两 writer → 校验 → 两文件逐个原子改名 → 写 manifest。若第二次改名失败，第一份也不得让会话变成 succeeded；manifest 标记失败并保留诊断。

播放只接受 `succeeded` 会话中的 final artifact。播放失败不破坏录音成果：会话录音状态仍为 `succeeded`，另行呈现 `playback.failed` 操作错误与重试/显示位置建议。状态事件可记录 playback 子状态，但顶层录音状态不倒退为 `failed`。

## 失败恢复

| 失败 | 顶层结果 | 恢复 |
|---|---|---|
| 权限拒绝 | `failed` | 打开设置、用户显式重新检查 |
| 任一路缺失/占用 | `failed` | 连接/释放设备后新 session 重试 |
| 启动或首 buffer 超时 | `failed` | 原子回滚；新 session 重试 |
| 运行期一路断开 | `failed`（经 `stopping`） | 保留失败 manifest；修复输入后重试 |
| 停止超时/失败 | `failed` | 强制释放 best-effort；下次启动识别 partial |
| 写入/磁盘失败 | `failed` | 停止双路；释放空间后重试 |
| 播放失败 | 录音仍 `succeeded` | 重试另一轨、显示位置；记录 playback error |

首要错误（最早导致会话失败者）不得被清理阶段错误覆盖；后续错误放入 `causes`。

## 可观测性

结构化事件：`state.transition`、`permission.checked`、`capture.firstBuffer`、`capture.bufferStats`、`writer.opened/closed`、`artifact.committed`、`playback.started/completed/failed`、`session.failed`。字段遵循 Data Contracts。

允许：session UUID、轨道枚举、状态、稳定错误码、OS/app build、采样率/声道数、frameCount、持续时间、字节数、阶段耗时。禁止：音频内容、完整路径、用户/设备名称、窗口标题、应用列表、文件名自由文本、密钥。尖刺默认仅本地 Unified Logging，敏感字段 privacy 标记；无远端遥测。

## 关键不变量

1. `recording` 意味着两路已各收到首 buffer。
2. `succeeded` 意味着两份 final artifact 均通过检查。
3. 任一时刻最多一个 active session。
4. 失败后无活跃 capture/writer。
5. partial 永不被播放或报告为成功。
6. 未经用户意图与系统授权不启动采集。
7. 音频及敏感元数据不出本机。
