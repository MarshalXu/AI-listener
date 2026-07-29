# AI-15 T-04 原子音频落盘与启动恢复

日期：2026-07-29  
规格基线：AI-3 SDD-r3  
aggregate SHA-256：`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`

## 规格状态

规格未修改。输入为已批准的 `D-04/D-11/D-12`、`C-01/C-02/C-04/C-05/C-07`
及已存在的 T-02/T-03 实现。停止条件为需要访问资产根外文件、无法唯一判定恢复
结果、覆盖冲突文件、增加系统权限或改变产品范围；本增量未触发停止条件。

## 实现状态

从 checkpoint 迁移并审计：

- `AtomicAudioAssetWriter`：SQLite 先插入 `recording` Session，再发布 recovery
  manifest；CAF temporary、file fsync、SHA-256/时长、stablePendingCommit、
  同目录 rename、directory fsync、SQLite ready commit、manifest 清理。
- `AudioRecoveryReconciler`：联合判定 SQLite/manifest/file，重放可证明的
  stable 资产；坏文件、冲突和孤儿只移入 app-owned quarantine。
- 新增无 manifest 的 committed integrity audit：ready/recovered 对应 stable
  缺失或 hash/CAF 不符时撤销假 ready，Session 转 `recoveryRequired`，错误文件
  quarantine，SQLite 资产保留为 `quarantined` 诊断记录。
- `SessionDeletionCoordinator`：D-12 DB-first `deleting`，文件删除失败可重试，
  重启后幂等完成 DB cascade。

## 故障矩阵

| 注入/启动观察点 | 自动化结果 |
|---|---|
| manifest create 前失败 | 已有 `recording` 行；启动确定转 failed；无假 ready |
| write/disk-full 等价失败 | manifest/tmp 保留；启动转 recoveryRequired |
| audio fsync 前失败 | temporary 可读时保留并 recoveryRequired |
| stablePendingCommit publish 前失败 | recording + temporary；无 AudioAsset/ready |
| rename 前失败 | 校验 tmp 后启动 rename、dir fsync、DB 重放 |
| directory fsync 前失败 | stable + manifest 联合校验后 DB 重放 |
| DB commit 前失败 | stablePendingCommit 重放；重复启动幂等 |
| DB commit 后、manifest 清理前失败 | committed/hash 匹配则只清 manifest |
| stable hash mismatch | 错误文件 quarantine；recoveryRequired；不标 ready |
| tmp/stable 冲突 | 两文件均 quarantine；recoveryRequired |
| 无 Session/manifest 的 orphan | 移入 app-owned quarantine；不静默删除 |
| ready/recovered、无 manifest、stable 缺失 | 撤销假 ready；recoveryRequired |
| ready/recovered、无 manifest、stable hash 错 | 错误文件 quarantine；撤销假 ready |
| 删除文件失败 | DB 保持 deleting；启动续删；重复续跑无副作用 |

测试使用合成 16 kHz mono Float32 PCM，未读取真实用户录音。故障点由确定性注入和
重建 reconciler 模拟进程重启；本证据不把它表述为真实 `SIGKILL`、磁盘设备物理
耗尽、60 分钟录音、真人 TCC 或最终 Demo。

## 验证状态

定向测试：

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build" \
  --filter AtomicAudioAssetWriterTests
```

结果：Debug build 成功；`12 tests in 1 suite passed`，其中参数化故障夹具覆盖
6 个 finalize 点和 2 个 committed integrity audit 变体。

全量回归：

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache" \
swift test --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-build"
```

结果：`26 tests in 3 suites passed`，target `arm64e-apple-macos14.0`。

Release build：

```sh
CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-module-cache-release" \
SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-module-cache-release" \
swift build -c release --disable-sandbox \
  --scratch-path "$PAPERCLIP_RUN_SCRATCH_DIR/swift-release"
```

结果：`Build complete! (5.86s)`；产物
`$PAPERCLIP_RUN_SCRATCH_DIR/swift-release/arm64-apple-macosx/release/AIListenerApp`。

格式检查：`git diff --check` 通过。

## 风险与下一步

- 本任务完成的是 T-04 自动化和 Release 编译门，不宣称 app bundle 打包、M5 Max
  性能、60 分钟录音、真人 TCC 或最终 Demo 已通过；这些属于后续 T-07 汇总门。
- 真实 `SIGKILL` 和物理磁盘耗尽属于更强环境级证据，不改变当前确定性恢复实现；
  若 T-07 要求补充，可复用本故障注入点构建独立进程 harness。
- 未新增权限、网络、云 ASR、外部发布或用户删除入口。
