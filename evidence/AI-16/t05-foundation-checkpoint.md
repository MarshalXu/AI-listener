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
  replace、duplicate `(segmentId,revision)` ignore、finalized strict sequence 和
  SQLite commit；
- 4 个定向测试。

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

- 定向测试 4/4 通过，0.120 秒；
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
