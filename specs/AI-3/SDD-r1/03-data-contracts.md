# 03 Data Contracts

## 通用规则

`contractVersion = "ai-listener.contracts/1.0"`，UTF-8；ID 为不透明 UUID 字符串；持久化时间为 Int64 毫秒。墙钟仅用于列表展示 `createdAtUtc`，音频/字幕顺序一律用 session 相对单调时间。未知 optional 字段必须忽略并保留向前读取能力；未知 enum/缺失 required 字段必须隔离记录为 `unsupported`，不得猜测。1.x 只允许新增 optional 字段/enum 的安全 fallback；删除、改义、改单位或 required 变化必须升 2.0 并提供显式迁移。数据库 `schemaVersion` 与事件 contractVersion 分开迁移，迁移须事务化且保留可恢复备份。

## `C-01 Session`

Required：`contractVersion, sessionId, state, transcriptState, createdAtUtc, captureStartMonotonicNs, lastEventSequence, schemaVersion`。  
Optional：`endedAtUtc, terminationReason, committedAudioAssetId, lastErrorId`。

`state ∈ recording|interrupted|finalizing|ready|recovered|recoveryRequired|deleting|failed`；`transcriptState ∈ unavailable|active|degraded|finalized|partialOnly`。`ready/recovered` 必须有 committedAudioAssetId；模型失败只能改变 transcriptState/错误，不得将可用音频 Session 标 failed。

## `C-02 AudioAsset`

Required：`contractVersion, audioAssetId, sessionId, relativePath, container, codec, sampleRateHz, channelCount, durationMs, byteCount, sha256, commitState`。

`relativePath` 必须在应用资产根下且不可含 `..`；`commitState ∈ temporary|committed|quarantined|deleting`。MVP 只允许单声道；资产与 Session 一对一。SQLite 保存相对路径，重定位容器不破坏引用。

## `C-03 TranscriptSegment`

Required：`contractVersion, segmentId, sessionId, revisionOf, status, sequence, revision, startMs, endMs, text, createdMonotonicMs, engineId, engineModelVersion`。

- `status ∈ partial|finalized|retracted`；`0 ≤ startMs < endMs`，同一 Session 的 finalized 按 `(startMs, sequence)` 严格排序，`sequence` 唯一且递增。
- partial：仅内存/事件流；同一 `segmentId` 的更高 `revision` 替换较低 revision，可改 text/start/end；消费者忽略旧 revision。
- finalized：由当前 partial 生成新 segment 或将其终结；一旦 repository commit，不允许同 ID 更高 revision 覆写。后续修正必须产生新 segment，`revisionOf=<旧 finalized id>`，旧项追加 `retracted` 审计记录；读取视图选择修正链最高有效项。
- ASR 事件可乱序到达，但 Coordinator 按 `createdMonotonicMs` 缓冲并以 sequence 提交；重复 `(segmentId,revision)` 幂等去重。跨 session 数据必须拒绝。
- finalized 可以有间隙但不能时间重叠；冲突时不入库并产生 `TRANSCRIPT_ORDER_CONFLICT`。空白 text 不 finalized。

## `C-04 RecordingEvent`

Required：`contractVersion, eventId, sessionId, sequence, monotonicMs, kind, correlationId, payloadVersion`；optional `safeMetadata`。同 session sequence 严格递增；eventId 幂等。`kind` 至少覆盖 stateChanged、captureInterrupted、audioCommitted、transcriptDegraded、recoveryStarted/completed、deleteStarted/completed。payload 未知版本可跳过，不妨碍核心记录读取。

## `C-05 Error`

Required：`contractVersion, errorId, sessionId?, domain, code, occurredMonotonicMs, recoverable, userAction, correlationId`；optional `underlyingSafeCode`。`userAction ∈ none|openMicrophoneSettings|retryModel|continueWithoutTranscript|retrySave|retryPlayback|retryDelete`。message 由 code 本地映射，不持久化原始系统描述，避免路径/内容泄漏。

## `C-06 ASR port`

输入 `AudioFrame(sessionId, sequence, startMs, durationMs, formatId, pcmBufferRef)`；format 固定由 adapter 协商。输出为 TranscriptSegment event 或 Error。背压时 ASR adapter 必须发 `ASR_INPUT_GAP`，可降级/停止识别，不得阻塞 Writer；stop 后 `finish(deadline)` 只负责冲刷 ASR，超时不阻止音频 commit。
