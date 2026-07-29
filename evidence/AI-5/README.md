# AI-5 / T-02 验证与迁移说明

规格基线：AI-3 SDD-r3，aggregate SHA-256
`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`。

## Schema 路径

- v0 → v1：创建 `sessions`（C-01）。
- v1 → v2：创建 `audio_assets`、`transcript_segments`、
  `recording_events`、`errors` 及顺序/查询索引（C-02…C-05）。
- 每一步在 `BEGIN IMMEDIATE` 事务中执行，schema 与 `user_version`
  同事务提交；失败自动 `ROLLBACK`，重开后从未完成版本重试。
- 对现有数据库升级前，使用 SQLite online backup API 保留
  `<database>.pre-migration-v<旧版本>.backup`。比当前实现更新的 schema
  一律拒绝打开，不猜测或降级。
- WAL 与 `foreign_keys` 在迁移前启用。业务写入使用同一事务边界。

## 自动化证据

运行：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ai-5-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ai-5-cache/clang" \
swift test --scratch-path "$PWD/.build/ai-5"
```

`SessionStoreTests` 覆盖：

- fresh install 与幂等 reopen；
- v1 fixture 逐版本升级、原数据保留与迁移前 backup；
- v2 故障注入回滚、随后重开恢复；
- newer schema 拒绝且不修改；
- Session/AudioAsset 原子 ready commit 与相对路径 containment；
- Event 重复幂等、乱序与跨 Session 拒绝；
- finalized Segment 重复幂等、partial 不落库、时间重叠与跨 Session 拒绝；
- Error 重复幂等；
- 所有 SQLite fixture 只写仓库内 `.test-artifacts/<UUID>`。

## 范围声明

这里只实现 T-02 数据契约和 repository。没有实现 ASR、摘要、行动项、
音频捕获/落盘恢复、系统音频、云端、导出或 T-04～T-07。
