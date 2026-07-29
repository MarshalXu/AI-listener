# Data Contracts

## 版本与兼容规则

所有持久化 JSON/事件含 `schemaVersion`，本修订为整数 `1`。同一 major 内新增字段必须 optional 或有默认值；不得改变既有字段语义、类型或枚举含义。未知字段必须忽略并保留读取能力；未知枚举值映射为 `unknown`，不得崩溃。删除/重命名必需字段、改变单位或隐私级别属于 breaking change，升 major 并经 Board 重新审批。时间戳使用 RFC 3339 UTC；持续时间使用非负整数毫秒；ID 使用小写 UUID 字符串。

## RecordingSession v1

| 字段 | 类型/约束 | 说明 |
|---|---|---|
| `schemaVersion` | `1` | 契约版本 |
| `sessionId` | UUID，必需 | 本地不透明 ID |
| `state` | RecordingState，必需 | 当前顶层状态 |
| `createdAt` | RFC3339，必需 | 创建墙钟，仅展示/排序 |
| `startedAt` | RFC3339? | 两路首 buffer 后设置 |
| `endedAt` | RFC3339? | 停止完成或失败 |
| `durationMs` | UInt64? | 单调时钟测得 |
| `tracks` | 0..2 AudioArtifact | 仅成功时必须恰为两项且 track 唯一 |
| `primaryError` | RecordingError? | failed 时必需 |
| `causes` | `[RecordingError]`，默认空 | 清理/次生错误 |
| `appBuild` | 非空字符串 | 可复现信息 |
| `osVersion` | 非空字符串 | 可复现信息 |

`RecordingState = idle | requestingPermission | recording | stopping | succeeded | failed | unknown`。`succeeded` 必须有 microphone 与 system 两个 final artifact；`failed` 不得被消费为可转写会话。

## AudioArtifact v1

| 字段 | 类型/约束 | 说明 |
|---|---|---|
| `artifactId` | UUID | 工件 ID |
| `sessionId` | UUID | 外键 |
| `track` | `microphone | system | unknown` | v1 成功工件不得 unknown |
| `relativePath` | 安全相对路径；不得含 `..`、不得绝对路径 | 容器内定位 |
| `container` | `caf` | v1 固定 |
| `codec` | `linearPCM` | v1 固定 |
| `sampleRateHz` | Float64，`> 0` | 实际格式 |
| `channelCount` | UInt32，`1...8` | 实际格式 |
| `bitDepth` | `32` | v1 Float PCM |
| `isInterleaved` | Bool | 实际格式 |
| `frameCount` | UInt64，`> 0` | 完整性 |
| `durationMs` | UInt64，`> 0` | 由帧数/格式计算 |
| `byteCount` | UInt64，`> header` | 文件大小 |
| `firstFrameHostTimeNs` | UInt64 | 会话单调时间基准 |
| `status` | `partial | final | abandoned | invalid | unknown` | 仅 final 可播放 |
| `createdAt` | RFC3339 | 创建时间 |

不保存绝对路径、设备名、应用/窗口标题或内容摘要。

## StateEvent v1

| 字段 | 类型/约束 |
|---|---|
| `schemaVersion` | `1` |
| `eventId` | UUID |
| `sessionId` | UUID?（idle 可空） |
| `sequence` | UInt64，session 内严格递增 |
| `occurredAt` | RFC3339 |
| `monotonicOffsetMs` | UInt64? |
| `name` | 稳定枚举/点分字符串 |
| `fromState` / `toState` | RecordingState? |
| `track` | Track? |
| `errorCode` | String?，来自错误码表 |
| `attributes` | `[String: Scalar]`，白名单、最多 20 项，每字符串 ≤128 字符 |

事件为诊断事实，不作为恢复状态的唯一真相；manifest 是持久化真相。禁止 attributes 写入路径、标题、设备名或任意用户文本。

## RecordingError v1

| 字段 | 类型/约束 |
|---|---|
| `schemaVersion` | `1` |
| `code` | 稳定错误码，必需 |
| `stage` | `permission | preflight | start | capture | stop | write | validate | playback | recovery | unknown` |
| `track` | Track? |
| `isRecoverable` | Bool |
| `recoveryAction` | `retry | openMicrophoneSettings | openScreenRecordingSettings | restartApp | freeDiskSpace | connectInput | showInFinder | none | unknown` |
| `userMessageKey` | 本地化 key，不含原始系统文本 |
| `underlyingDomain` | String?，白名单/脱敏 |
| `underlyingCode` | Int? |

最低错误码：`permission.microphoneDenied`、`permission.screenRecordingDenied`、`permission.restartRequired`、`input.microphoneUnavailable`、`input.systemAudioUnavailable`、`capture.startFailed`、`capture.firstBufferTimeout`、`capture.interrupted`、`capture.stopFailed`、`writer.openFailed`、`writer.appendFailed`、`writer.closeFailed`、`writer.commitFailed`、`artifact.invalid`、`playback.openFailed`、`playback.decodeFailed`、`recovery.abandonedPartial`、`internal.unknown`。

## FutureTranscriptionInput v1（仅边界，不实现）

| 字段 | 类型/约束 | 说明 |
|---|---|---|
| `schemaVersion` | `1` | 未来消费者协商 |
| `requestId` | UUID | 幂等键 |
| `sessionId` | UUID | 必须引用 `succeeded` session |
| `artifacts` | 恰好 2 个 ArtifactReference | microphone/system 各一 |
| `localeHint` | BCP-47? | 用户将来显式提供 |
| `consent` | `localOnly | externalProcessingApproved` | v1 当前里程碑仅允许 localOnly |

`ArtifactReference` 只含 `artifactId`、`track`、`container`、`codec`、格式、frameCount、durationMs 和受控本地读取句柄/相对路径。它不得含原始音频 bytes、上传 URL、供应商信息、摘要或行动项。当前里程碑禁止实例化外部请求；任何 `externalProcessingApproved` 流程均需新规格、隐私与 Board 审批。

## 数据校验与隐私分级

- 音频文件：敏感，本地限定，不进日志/测试快照/网络。
- relativePath：受限，仅持久化 manifest；日志禁止。
- sessionId、格式、计数、稳定错误码：低敏，可本地诊断。
- 权限状态：受限，仅记录枚举，不记录用户身份。
- 解码失败的原始系统消息：默认不持久化；只映射 domain/code。
