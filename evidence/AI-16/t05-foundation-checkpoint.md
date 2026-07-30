# AI-16 / T-05 foundation checkpoint

Date: 2026-07-29  
Specification: AI-3 SDD-r3  
Aggregate SHA-256: `7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

无规格变化。本增量按 C-03/C-06、D-05/D-10 实现本地 ASR port、有界
ASR branch 和 transcript event coordinator。writer 必须先 append，再调用
ASR `offer`；ASR 满载采用 drop-newest 并合并报告 `ASR_INPUT_GAP`。

## 实现状态

输入：

- AI-5 `SessionStore` 及 transcript transaction；
- AI-6 单麦克风 capture contract；
- T-04 `AtomicAudioAssetWriter`；
- T-01 锁定工件位于 AI-4 evidence（本 checkpoint 尚未链接 dylib）。

输出：

- `LocalStreamingASREngine`：只允许本地实现的 streaming engine boundary；
- `BoundedASRQueue`：固定 capacity、独立 worker、capture-path 非阻塞 offer、
  drop-newest gap、engine/finish failure degradation、deadline finish 和 metrics；
- `TranscriptEventCoordinator`：cross-session reject、partial higher-revision
  replace、duplicate `(segmentId,revision)` ignore、乱序 finalized 缓冲后按
  sequence SQLite commit、重叠拒绝并发 `TRANSCRIPT_ORDER_CONFLICT`；
- 6 个定向测试。

本 checkpoint **尚未**实现 sherpa C API adapter、PCM format conversion、产品
coordinator 的 writer-first 接线或滚动字幕 UI，因此不得表述为 T-05 完成。

## 验证状态

执行：

```sh
swift test --filter StreamingASRTests
swift test
swift build -c release
```

原始观察：

- 2026-07-29 最新定向测试 6/6 通过，0.147 秒；
- 全量测试 30/30 通过，4 suites，0.087 秒；
- Release build 通过，5.18 秒；
- 队列测试测得 producer 100 次 offer 小于 0.1 秒，maximum depth 不超过 2，
  accepted 等于 processed，且观察到 `ASR_INPUT_GAP`；
- engine failure 测试观察到 degraded 和 `ASR_ENGINE_FAILED`。

无云调用边界：

```sh
rg -n 'URLSession|https?://|WebSocket|grpc|cloud|api[_-]?key' \
  Sources Package.swift
```

产品 source/package 无网络 client 或 ASR endpoint；注释中的 “cloud” 只用于
声明本地 engine port 禁止网络。该静态检查不代替最终运行时网络捕获。

## 风险与下一步

- 接入锁定 sherpa-onnx v1.13.2 C API 和模型，验证 dylib/app bundle rpath；
- 将麦克风 PCM 转换为 16 kHz mono Float32，并以 writer-first 顺序接入 fan-out；
- 将 diagnostics 事务化为 safe Error/RecordingEvent，并在 UI 展示
  partial/finalized；
- 执行合成 60 分钟 Release stress、writer frame-duration 对账、ASR
  failure 后音频 commit、peak RSS/RTF 和运行时无网络捕获。

停止条件仍为：许可证不兼容、需云/私人音频/新增权限、需破坏批准契约，或 ASR
背压影响 writer。当前未触发这些停止条件。

## 2026-07-29 continuation

输入：C-03 明确允许 ASR 事件乱序到达，并要求 Coordinator 缓冲后按 sequence
提交；finalized 时间不可重叠。

输出：`TranscriptEventCoordinator` 新增 pending-final buffer。sequence 1 可先于
sequence 0 到达而不报错；0 到达后在同一 actor 隔离域内依次提交 0、1。SQLite
拒绝重叠后，Coordinator 产生安全诊断码 `TRANSCRIPT_ORDER_CONFLICT`，冲突项不
入库。

验收证据：

```text
swift test --filter StreamingASRTests
Test run with 6 tests in 1 suite passed after 0.147 seconds.
```

停止条件：如果缺失 sequence 永不抵达，pending final 只保留至本次 Session
Coordinator 生命周期结束，不猜测缺失文本；finish/deadline 的最终降级与产品
状态接线仍属于后续 T-05 工作。

## 2026-07-30 writer-first fan-out checkpoint

输入：Board 写入 SDD-r3 的 2026-07-30 disposition，允许 sherpa-onnx 候选以
阶段性 T-01 gate 进入 T-05；另复用 AI-6 `AudioFrame`、AI-15
`AtomicAudioAssetWriter.write` 和本文件前述 `BoundedASRQueue`。

输出：

- `ASRFrameConverter` 将 capture buffer 复制/转换为 ASR branch 自有的
  16 kHz mono Float32 samples，并由 capture monotonic clock 计算时间；
- `WriterFirstAudioFanout` 同步先 writer，成功后才 conversion 和非阻塞 ASR
  offer；writer failure 原样上抛且 ASR `acceptedFrames=0`；
- ASR conversion/queue/engine failure 只产生 diagnostic/degraded，不反向阻塞
  或终止后续 writer 调用。

验收证据：

```text
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache" \
SWIFTPM_CUSTOM_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/swift-cache" \
swift test --filter StreamingASRTests

StreamingASRTests: 9 tests passed, 0 failed, 2026-07-30
```

新增三项合成 buffer 测试分别证明 48 kHz stereo → 16 kHz mono、writer
failure 时不进入 ASR，以及注入 engine failure 后 writer 仍收到第二帧。首次托管
沙箱内执行因 SwiftPM 内部 `sandbox-exec` 被拒绝；获批在系统沙箱外使用
run-owned cache 后通过。这是执行环境限制，不是产品失败。

停止条件与剩余：此 checkpoint 未接 sherpa C API/dylib、未跑真实模型、长时
Release 或运行时网络捕获，因此不得宣称 T-05 完成。下一 continuation 是
sherpa v1.13.2 adapter、模型 bundle/rpath 和公开/合成音频 streaming 验证；
随后执行长时 Release 与无云取证。如需云/私人音频/新增权限、许可证豁免或破坏
批准契约，停止并升级 Board。
