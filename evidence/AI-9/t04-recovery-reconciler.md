# AI-9 T-04 Recovery Reconciler Evidence

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

未修改规格。实现遵循 D-11、C-01/C-02/C-07 和 M-05/M-06；没有进入受 T-01
锁定门约束的 T-05。

## 输入

- `evidence/AI-8/baseline-inventory.md` 中已通过的 17-test T-04 首段；
- `AtomicAudioAssetWriter` 的 CAF、manifest、fsync、rename、SQLite commit 实现；
- `SessionStore` schema v2 与 repository；
- 合成 16 kHz mono Float32 PCM，不含真实用户音频。

## 输出

- `Sources/AIListenerCore/AudioRecoveryReconciler.swift`
  - 启动扫描 app-owned recovery manifest；
  - `stablePendingCommit` 的 tmp 校验、rename、dir fsync、SQLite 重放；
  - DB 已 committed 且 size/hash/路径匹配时幂等清理 manifest；
  - stable hash/size/CAF 不匹配时移入 app-owned quarantine；
  - 冲突/不完整状态写入 `recoveryRequired`，不产生假 ready、不删除未证明资产。
- `SessionStore.commitReadySession` 支持既有 recording/finalizing Session 的事务提交和
  完全匹配资产的幂等重放；冲突资产拒绝。
- manifest 新增恢复所需 optional session/audio metadata，保持 1.x additive contract。
- 新增三项启动恢复故障夹具：DB commit 前、DB commit 后 manifest 未清、hash mismatch。

## 验证状态

执行命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
  "$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache"
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

原始结果摘要：

```text
Build complete! (6.27s)
Suite CaptureCoordinatorTests passed
Suite SessionStoreTests passed
Suite AtomicAudioAssetWriterTests passed
Test run with 20 tests in 3 suites passed after 0.104 seconds.
```

新增断言证明：

- DB commit 注入失败后，首次 reconcile 得到 `recovered`、Session 为 recovered、
  AudioAsset 唯一一行、manifest 清理；第二次 reconcile 为空；
- DB 已 ready 而 manifest cleanup 注入失败后，联合校验匹配并只清 manifest；
- stable 首字节被篡改后，不写 AudioAsset，Session 为 recoveryRequired，资产移入
  quarantine；再次 reconcile 保持 recoveryRequired，不误删隔离资产。

这次执行是 Debug 自动测试，不代表 Release、M5 Max 性能、真人 TCC、完整
M-05/M-06 或 T-04 全门已通过。

## 风险、下一步与停止条件

- T-04 仍需补全 D-11 矩阵：`temporary` 空/不可读文件、DB 已宣称 committed 但
  stable 缺失/损坏，以及磁盘满的确定性故障夹具。
- 当前 quarantined manifest 的再次扫描会稳定返回 recoveryRequired；后续须增加安全诊断
  event/error 证据。
- 下一检查点：完成上述剩余矩阵并锁定 T-04，然后回到 T-01 固定语料/adapter 锁定。
- 未触发范围、权限、云、付费、许可证或数据删除升级条件。

## 2026-07-29 continuation：启动全目录扫描与 D-12

### 输入

- 上述 `20 tests / 3 suites` 已通过基线；
- D-11 的 temporary/conflict/orphan/no-manifest 联合判定；
- D-12 的“DB 先 deleting、文件失败可重试、崩溃后幂等续删”。

### 输出

- `AudioRecoveryReconciler.reconcileAll` 增加：
  - 可读非空 temporary 保留并转 `recoveryRequired`，不造假 ready；
  - tmp+stable 同时存在时两者隔离；
  - recording 且无 manifest/文件时转 failed；
  - 仅扫描 app asset root 内 `.caf`/`.audio.tmp`，无 DB/manifest owner 的孤儿移入
    app-owned quarantine，返回不含音频正文的安全 outcome。
- `SessionDeletionCoordinator` 与 `SessionStore` 删除事务：
  - 显式删除先将 Session/AudioAsset 标 `deleting`；
  - 文件删除失败保留状态与文件；
  - 启动 `resumePending` 删除文件后事务清除 SQLite 行；
  - 文件已不存在及无 pending Session 的重复恢复均幂等。
- 新增四项合成夹具；没有读取或删除真实用户录音。

### 验证状态

命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
  "$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache"
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

原始结果摘要：

```text
Build complete! (6.58s)
Suite CaptureCoordinatorTests passed
Suite SessionStoreTests passed
Suite AtomicAudioAssetWriterTests passed
Test run with 24 tests in 3 suites passed after 0.143 seconds.
```

验证层级仅为 Debug 自动测试；未验证 Release、真人 TCC、M5 Max 性能或完整 M-05/M-06。

## 2026-07-29 continuation：确定性磁盘满恢复夹具

### 输入

- SDD T-04 明列的“磁盘满”故障注入要求；
- 已通过的启动 reconciler 与“不产生假 ready”不变量；
- 合成 16 kHz mono Float32 PCM，不含真实用户音频。

### 输出

- `AudioCommitFailurePoint.diskFullDuringWrite`：在 CAF 已创建、首个 PCM buffer 写入前
  确定性模拟 write-time ENOSPC 等价失败；
- 新增自动测试证明：失败后 manifest 保留，SQLite 无 Session/AudioAsset ready 记录；
  启动 reconciler 将 CAF header-only temporary 确定归类为
  `recoveryRequired/temporaryAwaitingFinalization`，仍不产生假 ready。

### 验收证据

执行命令：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift test
```

首次新增夹具把 AVAudioFile 创建出的 header-only CAF 预期为
`temporaryMissingEmptyOrUnreadable`，实际可由 AVFoundation 打开，测试因此失败。按可复现
事实修正预期为 `temporaryAwaitingFinalization` 后，全套回归结果：

```text
Build complete! (0.77s)
Suite SessionStoreTests passed
Suite CaptureCoordinatorTests passed
Suite AtomicAudioAssetWriterTests passed
Test run with 25 tests in 3 suites passed after 0.079 seconds.
```

这是 Debug 合成夹具证据，只证明确定性 write failure 分类与无假 ready；不宣称真实卷
ENOSPC、Release、性能、真人 TCC 或最终 Demo 已通过。

### 风险与下一步

- T-04 自动恢复矩阵已覆盖正常提交、commit 各崩溃窗口、write-time 磁盘满等价失败、
  hash mismatch、tmp/stable 冲突、孤儿隔离、无 manifest recording 及幂等删除恢复。
- 下一 live continuation path：回到 T-01 补齐固定公开/合成语料的 adapter 锁定、
  许可证/SBOM 与完整 M5 Max 指标；T-01 未锁定前不进入 T-05。
- 真人麦克风 TCC 仍仅由 local-board 在 Release 与自动化全部就绪后执行，不是当前 blocker。
