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

## 2026-07-30 adapter boundary / recovery checkpoint

### 规格状态

Board disposition 已解除 T-05 的阶段性 T-01 gate blocker；完整 60 分钟、三轮
Release 与母语评审债务仍由 T-07 追踪，当前未宣称通过。本 checkpoint 未修改
该 disposition，也未把共享 worktree 中尚未提交的规格文件混入 AI-16 commit。

### 实现状态

已核对锁定 sherpa runtime 含：

- `libsherpa-onnx-c-api.dylib`；
- `libonnxruntime.1.24.4.dylib`；
- v1.13.2 C API header；
- 14M 中文 streaming 模型的 encoder/decoder/joiner/tokens。

接入边界收敛为窄 C shim + bundle-relative `dlopen`，避免把开发机
`evidence/AI-4/...` 绝对路径写入 SwiftPM 或 Release binary。Swift adapter 只实现
`LocalStreamingASREngine` 所需的 accept/finish/result/endpoint 生命周期；运行库
缺失、符号缺失、模型初始化失败均转为 ASR branch failure，不影响 writer。

### 验证状态

执行：

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swift-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-test" \
  --filter StreamingASRTests

CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-release" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swift-release" \
swift build --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/release-build" -c release

rg -n 'URLSession|https?://|WebSocket|grpc|api[_-]?key' Sources Package.swift
git diff --check
```

2026-07-30 原始观察：

- `StreamingASRTests` 9/9 通过，1 suite，0.192 秒；
- Release build 成功，5.31 秒；
- 产品 source/package 静态无网扫描无命中；
- `git diff --check` 通过。

首次测试未设置 module cache 时因托管 sandbox 拒绝写入
`~/.cache/clang/ModuleCache` 而失败；切换到 run-owned cache 后通过。这是已恢复
的执行环境失败，不是产品失败。

### 风险与下一步

尚未验证且不得宣称完成：真实 sherpa C adapter、公开 WAV 的 partial/final
输出、dylib/model app bundle、长时 Release RSS/RTF、运行时无网络捕获。下一
continuation 直接实现 C shim + Swift adapter，用 AI-4 模型归档内公开 WAV 做
streaming integration test，再验证 bundle/rpath。Paperclip API 本 heartbeat
返回 `127.0.0.1:3100 connection refused`，因此 checkpoint 先固化在仓库；下次
API 可用时回填 issue comment。该服务不可达不阻断本地实现。

## 2026-07-30 sherpa streaming adapter increment

### 规格状态

输入仍为批准的 SDD-r3 与 AI-4 锁定 sherpa-onnx v1.13.2/14M 中文模型；未改
产品范围、系统权限或云边界。T-07 承接的 60 分钟三轮 Release 性能与母语评审
债务仍未完成，本增量不宣称替代该 gate。

### 实现状态

输出：

- `CSherpaShim` 通过 `dlopen`/`dlsym` 加载 bundle-relative runtime，不在
  executable 直接链接 sherpa symbols；
- `SherpaStreamingASREngine` 实现 `LocalStreamingASREngine`，固定 CPU、
  16 kHz、greedy search 与 endpoint，产出 revisioned partial 和 finalized；
- runtime/model/symbol/stream 失败成为 typed ASR error，继续沿既有
  `BoundedASRQueue` 隔离，不反压或停止 writer；
- adapter 没有网络 API、云 fallback 或新增 entitlement。

停止条件：缺任一锁定文件、ABI symbol 或模型初始化失败即停止 ASR 分支并返回
错误；不得尝试网络下载或云识别。

### 验证状态

输入为 AI-4 模型包公开 `test_wavs/0.wav`，并明确移除
`DYLD_LIBRARY_PATH`，验证不是开发 shell 注入路径才能运行。

```sh
env -u DYLD_LIBRARY_PATH \
  CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swift" \
  swift test --disable-sandbox \
    --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/build-noenv" \
    --filter StreamingASRTests

CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-release" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swift-release" \
  swift build --disable-sandbox \
    --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/release" -c release

rg -n 'URLSession|https?://|WebSocket|grpc|api[_-]?key' Sources Package.swift
git diff --check
```

原始结果：`StreamingASRTests` 11/11、1 suite、0.359 秒通过；其中真实公开 WAV
解码 0.238 秒并产生非空事件与 finalized。Release build 成功（5.86 秒）。
产品 source/package 无网络 token 命中；`git diff --check` 通过。上述验证证明
adapter 最小真实闭环，不证明长时 Release RSS/RTF 或最终 app bundle 已完成。

### 风险与下一步

真实剩余：将两个 runtime dylib 与四个模型文件复制进 Release `.app`，验证
codesign/rpath/从 bundle 启动；随后用公开或合成 60 分钟流执行 Release
RSS/RTF、队列/文件 duration 对账与运行时无连接取证。该工作仍属 AI-16 live
continuation，不需要 Board 普通工程决策；只有许可证不兼容、新权限、云/私人
数据或门槛/范围变化才升级。

## 2026-07-30 successful-run handoff verification

### 规格状态

继续按批准的 SDD-r3（aggregate
`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`）
实施；无范围、权限或云边界变化。T-07 承接的 60 分钟三轮 Release 性能与母语
评审债务仍未完成，本次复核不将其表述为通过。

### 实现状态

AI-16 独立实现链为 `2139c29`、`257b451`、`f1f0dea`、`580a07f`；本次未修改
产品代码。共享 worktree 中两份 SDD disposition 修改与 `evidence/AI-12/` 残留
不属于 AI-16，未混入本次 handoff。

### 验证状态

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swift" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/test" \
  --filter StreamingASRTests

CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-release" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swift-release" \
swift build --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/release" -c release

rg -n 'URLSession|https?://|WebSocket|grpc|api[_-]?key' Sources Package.swift
git diff --check
```

2026-07-30 原始观察：`StreamingASRTests` 11/11、1 suite、0.449 秒通过；
公开 WAV 真实 sherpa 解码 0.262 秒；Release build 成功（5.73 秒）；产品
source/package 静态无网扫描无命中；`git diff --check` 通过。静态扫描不替代
运行时网络捕获。

### 风险与下一步

尚未验证：两个 runtime dylib 与四个模型文件进入 Release `.app` 后的
bundle-relative 启动/codesign；公开或合成 60 分钟 Release RSS/RTF、队列/音频
duration 对账与运行时无连接取证。live continuation owner 为 Founding macOS
Engineer；下一 heartbeat 先实现可复现 app bundle resource packaging 与 bundle
启动测试，再执行长时 Release harness/取证。无一等 blocker，AI-16 应保持
`in_progress`，不得标为 done 或 in_review。

本次尝试通过 Paperclip API 回填 comment/status 时，
`127.0.0.1:3100` 返回 connection refused；仓库 checkpoint 是本次 durable
handoff，API 恢复后应补写同内容。服务不可达不阻断本地实现。
