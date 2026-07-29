# AI-9 T-04 Recovery / Deletion Verification

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

本增量未修改规格。输入为 SDD-r3 的 `D-04/D-11/D-12`、`C-01/C-02/C-04/C-05/C-07`
以及 AI-8 已验证的 T-02/T-03 基线。

停止条件：若需要删除无法证明归属的文件、改变恢复状态矩阵、增加系统权限或修改
产品范围，停止实现并升级 Board。本增量未触发停止条件。

## 实现状态

本 heartbeat 接续并验证工作树中已有的 T-04 增量：

- `AtomicAudioAssetWriter`：首帧前 manifest、CAF temp、fsync/hash、manifest phase、
  rename、directory fsync、SQLite commit、manifest cleanup。
- `AudioRecoveryReconciler`：启动时联合判定 manifest/file/SQLite，重放可证明的
  stable 资产；坏文件、冲突与无归属孤儿只隔离不删除；未完成录音进入
  `recoveryRequired` 或 `failed` 的确定状态。
- `SessionDeletionCoordinator`：D-12 DB-first `deleting`，文件删除后清理元数据，
  失败保留状态并在启动时幂等续跑。
- `SessionStore`：支持恢复联合判定、recovery/deleting 状态转换和幂等 ready commit。

输出路径：

- `Sources/AIListenerCore/AtomicAudioAssetWriter.swift`
- `Sources/AIListenerCore/AudioRecoveryReconciler.swift`
- `Sources/AIListenerCore/SessionDeletionCoordinator.swift`
- `Sources/AIListenerCore/SessionStore.swift`
- `Tests/AIListenerCoreTests/AtomicAudioAssetWriterTests.swift`

## 验证状态

使用合成 16 kHz mono Float32 PCM；未访问真实用户录音。

定向命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
  "$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache"
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build" \
  --filter AtomicAudioAssetWriterTests
```

原始结果摘要：Debug build 成功；`AtomicAudioAssetWriterTests` 共
`11 tests in 1 suite passed`。

全量回归命令：

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

原始结果摘要：Debug build 成功；Swift Testing 共
`25 tests in 3 suites passed`：

- `SessionStoreTests`
- `CaptureCoordinatorTests`
- `AtomicAudioAssetWriterTests`

验证覆盖：

- 正常 CAF commit 与 SQLite 原子可见性；
- manifest create、audio fsync、manifest stablePendingCommit、rename、
  directory fsync、DB commit、manifest cleanup 故障窗口；
- write/disk-full 注入不产生假 ready；
- stablePendingCommit 启动重放及重复启动幂等；
- committed DB 后遗留 manifest 清理；
- hash mismatch 与 tmp/stable conflict quarantine；
- readable temporary 保持 `recoveryRequired`；
- 无 manifest 的 recording 失败分类与无归属 CAF quarantine；
- D-12 文件删除失败保持 `deleting`，启动续跑及重复续跑幂等。

运行环境对用户级 SwiftPM cache 只读，因此命令显式使用 run scratch，并采用
`--disable-sandbox`；测试过程仍打印用户级 cache disabled/readonly warning，
但 build 与 tests 成功。这是运行环境事实，不是产品失败。

## 风险与下一步

本证据只验证当前自动化夹具，不宣称以下门已通过：

- M-05/M-06 完整逐故障点目录树、hash 前后原始取证；
- DB 已 ready 但 manifest 缺失时的启动资产完整性审计；
- 60 分钟录音、真实设备/真人 TCC、Release build、性能；
- T-01 固定语料质量、模型锁定、完整许可证/SBOM。

下一检查点：补齐并锁定 T-01 固定 60 分钟公开/合成语料门；T-01 未锁定前不进入
T-05。若继续收口 T-04，优先增加“ready/recovered + manifest 缺失 + stable
缺失/hash 错”的启动审计夹具与安全状态回退。
