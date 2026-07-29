# AI-8 T-04 Recovery / Deletion Checkpoint

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

规格未修改。本增量实现批准范围内的 `D-04/D-11/D-12`，只操作调用方传入的
应用资产根；未新增系统权限、网络、云 ASR 或用户数据删除入口。删除协调器只是
底层能力，产品 UI 尚未暴露删除动作。

## 实现状态

输入：

- AI-5 `SessionStore` / SQLite v2；
- AI-6 单路麦克风 frame 合约；
- SDD-r3 `C-01/C-02/C-04/C-05/C-07`、`D-04/D-11/D-12`。

输出：

- `AtomicAudioAssetWriter`：首帧前 manifest、CAF temporary、file fsync、hash/
  duration、stable-pending manifest、同目录 rename、directory fsync、SQLite
  commit、manifest cleanup，并可逐点注入失败；
- `AudioRecoveryReconciler`：启动扫描、已提交 manifest 清理、stable-pending
  重放、hash/可读性校验、tmp/stable 冲突隔离、未知孤儿隔离、无 manifest 的
  recording 归类 failed；
- `SessionDeletionCoordinator`：SQLite 先标 deleting、音频删除、DB cascade
  清理，文件失败保留 deleting，启动后可幂等续删；
- `SessionStore`：恢复重放所需的幂等 ready commit、状态查询/转换、引用路径
  与删除事务 API。

停止条件检查：没有访问资产根外路径，没有以文件名自动删除孤儿，没有覆盖冲突
文件；ASR 尚未接入 writer，因此本检查点不宣称已经证明 ASR/writer 隔离。

## 验证状态

执行命令：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
  "$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache"
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
git diff --check
```

当前实机结果：

- macOS/arm64 target `arm64e-apple-macos14.0`，Debug build 完成；
- Swift Testing：`25 tests in 3 suites passed`，其中 T-04 suite 覆盖正常 CAF
  commit、6 个 finalize 失败点、manifest 创建失败、模拟 disk-full write、
  stable-pending 重放、DB 已提交后的清理、hash mismatch、可读 temporary、
  tmp/stable conflict、无 manifest recording、未知 orphan、删除失败与启动续删；
- 正常夹具生成 16 kHz mono Float32 synthetic PCM，CAF 可由 `AVAudioFile`
  重开并读到 1600 frames / 100 ms；
- `git diff --check` 通过。

上述是自动化故障注入与 Debug 回归，不等同于真实进程 `SIGKILL` 崩溃矩阵、
60 分钟连续录音、Release 性能、真人麦克风 TCC 或最终 Demo 验收。

## 风险与下一步

- T-04 实现面已具备确定性恢复与 D-12 续删，但正式验收仍需把七个边界做成
  独立进程强退/重启夹具，并保存每点的目录树、SQLite、manifest、hash 原始结果；
- 仍需 60 分钟 writer frame-duration 对账与磁盘满环境级证据；
- `quarantined` manifest 会被保留供诊断，重复启动保持 `recoveryRequired`，
  不会静默删除；后续应在 T-07 报告中验证诊断可见性；
- live continuation path：补建独立进程 crash harness 完成 M-06 原始证据；
  与此同时 T-01 仍需固定 60 分钟许可语料、CER/RTF/streaming latency 后才可
  解锁 T-05。

## 2026-07-29 19:19 CST 续行回归

本 heartbeat 未修改规格或扩大实现范围；对上述尚未提交的 T-04 增量及其
`SessionStore` 依赖执行了最小定向回归。

首次直接执行 `swift test --filter ...` 未进入代码编译，原因是受管运行环境禁止
Swift/Clang 写入用户级 module cache；随后显式把
`CLANG_MODULE_CACHE_PATH` 指向 `$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache`，
并在获准的外层执行环境中重跑：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache"
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache" \
swift test \
  --filter 'AtomicAudioAssetWriterTests|AudioRecoveryReconcilerTests|SessionDeletionCoordinatorTests|SessionStoreTests'
```

原始结果摘要：

- Debug build 完成；
- target：`arm64e-apple-macos14.0`；
- `SessionStoreTests` 与 `AtomicAudioAssetWriterTests` 共 `20 tests in 2 suites
  passed`，耗时 `0.083 seconds`；
- 本次 filter 中后两个名称不是独立 suite；恢复与删除测试当前归入
  `AtomicAudioAssetWriterTests`，因此不将 XCTest 的 `0 tests` 兼容输出误报为
  未执行，也不虚构额外 suite。

本次结果再次证明现有自动化夹具通过，但仍不等同于独立进程强退、Release、
60 分钟、真人 TCC 或最终 Demo 门通过。下一最小实现点保持为 M-06 独立进程
crash harness；T-01 未锁定前继续禁止进入 T-05。
