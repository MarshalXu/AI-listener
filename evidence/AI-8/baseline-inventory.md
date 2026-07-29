# AI-8 Baseline Inventory

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`  
Board confirmation：`e31989a5-76d5-4f7c-bfc8-8bef53bbf271`，2026-07-29T09:14:17.135Z accepted。

## 规格状态

Board 已接受完整 SDD-r3。AI-8 未修改规格；若后续需要改变范围、契约 major、质量门、权限、外部服务或持续成本，停止实现并发布新规格修订重新审批。

## 实现状态

现有基线包含：

- T-02：`SessionStore`、SQLite schema v2、v1→v2 migration/backup/rollback、契约 repository。
- T-03：仅麦克风 TCC provider、`AVAudioEngine` 单路 frame、`CaptureCoordinator` 状态机、SwiftUI 状态 UI。
- T-01：sherpa-onnx v1.13.2、14M 中文模型、公开短样本与三轮探针；只证明候选可运行，adapter 尚未锁定。

尚缺：

- T-01 完整固定语料质量、partial/final latency、许可证与 SBOM 门；
- T-04 CAF 原子落盘、recovery manifest、故障注入；
- T-05 有界 fan-out、实时 ASR、partial/finalized 流及 ASR 失败隔离；
- T-06 Session 列表/重开、音频播放、finalized 字幕 seek；
- T-07 Release `.app`、完整失败矩阵、隐私/日志/网络扫描、M5 Max Release 性能证据与真人验收清单。

## 验证状态

环境：

- macOS 26.5.2 build 25F84，arm64；
- Xcode 26.6 build 17F113；
- Swift 6.3.3；
- Package deployment target macOS 14。

可复现命令：

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

结果：Debug build 成功；Swift Testing 共 14 tests / 2 suites 全部通过：

- `SessionStoreTests`：9 tests；
- `CaptureCoordinatorTests`：5 tests（其中权限拒绝参数化覆盖 denied/restricted）。

首次默认 `swift test` 因运行环境不允许写 `~/.cache/clang` 失败；第二次仅重定向 cache 后又因 SwiftPM `sandbox_apply: Operation not permitted` 失败。使用明确的 scratch cache 与 `--disable-sandbox` 后通过。这是构建环境限制，不是产品验证通过证据。

未执行：真人麦克风 TCC、真实设备录音、Release build、app 启动、ASR、CAF 恢复、播放/seek、性能、许可证完整门。

## 风险与下一步

- T-01 adapter 未锁定，按 SDD 依赖不得进入 T-05。
- T-03 真人 TCC/UI/设备切换仍待 local-board 最终验收，但不阻塞自动化工程推进。
- 下一实现检查点：T-04，复用 T-02/T-03，不改写已通过组件。

## 2026-07-29 T-04 增量（heartbeat）

### 输入

- 已批准 SDD-r3 `D-04/D-11`、`C-01/C-02/C-07`；
- 既有 `SessionStore.commitReadySession`；
- 合成 16 kHz mono Float32 PCM（无真实用户音频）。

### 输出

- `Sources/AIListenerCore/AtomicAudioAssetWriter.swift`
  - 首帧前 recovery manifest；
  - CAF 临时文件；
  - file `fsync`、SHA-256、duration/size；
  - manifest `stablePendingCommit`；
  - 同目录 POSIX `rename`、directory `fsync`；
  - SQLite ready/AudioAsset 原子事务；
  - manifest `committed` 后清理。
- `Tests/AIListenerCoreTests/AtomicAudioAssetWriterTests.swift`
  - 正常提交后的 CAF 可重开；
  - manifest create、audio fsync、manifest phase、rename、directory fsync、
    DB commit、manifest cleanup 故障注入。

### 验收证据

命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
  "$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache"
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

原始结论：Build complete；Swift Testing `17 tests in 3 suites passed`。
新增正常路径验证 1600 frames / 100 ms CAF、64 hex SHA-256、Session 与 AudioAsset
各一行且 manifest 已清理。新增参数化故障路径证明 DB commit 前的失败不产生
ready/AudioAsset；DB commit 后 cleanup 失败保留 committed DB 与 manifest，供重启清理。

### 停止条件与剩余

本增量没有触发规格停止条件。T-04 尚未完成：仍缺启动时联合判定 reconciler、
hash mismatch/conflict quarantine、`recoveryRequired` DB 转换、D-12 幂等删除及其
完整重启夹具。因此本记录不声称 T-04 或 M-05/M-06 已通过。
