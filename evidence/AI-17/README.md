# AI-17 / T-06 记录列表、重开与时间点回听

日期：2026-07-30

环境：MacBook Pro Mac17,6，Apple M5 Max 48 GB (`arm64`)，macOS 26.5.2
(25F84)，Apple Swift 6.3.3。电源/温控状态未采集，因此本结果不外推为性能基准。

批准输入：AI-3 SDD-r3（Board 提供 aggregate SHA-256
`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`）

## 输入、输出与停止条件

- 输入：T-02 SQLite repository、T-04 committed AudioAsset/recovery、T-05 finalized
  transcript；仅应用自有资产目录与公开生成的合成 CAF 测试音频。
- 输出：只列出 `ready/recovered + committed` 的 session；重开 finalized transcript；
  点击 finalized `startMs` 播放并报告播放器实际媒体位置；缺失/损坏资产撤销假
  ready，保留 session、逐字稿和现存文件。
- 停止条件：需删除用户数据、新增权限、使用云/真实用户录音、SDD 契约破坏性变化或
  M-08 门槛需豁免时升级 Board。本增量未触发这些条件。

## 可复现验证

定向自动化：

```sh
env CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-cache" \
  swift test --filter PlaybackServiceTests
```

结果：6 tests / 1 suite passed。覆盖：

1. SQLite repository 析构并重开后，列表、committed asset 与 finalized segment 不丢失；
2. finalized `startMs` 作为 seek 目标，返回 driver 的实际媒体位置与绝对误差；
3. committed 文件缺失时转 `recoveryRequired`，session/逐字稿不删除；
4. committed 文件大小/hash/音频可读性不匹配时转 `recoveryRequired`，损坏文件不删除；
5. M-08 门算法要求恰好 30 个原始测量，nearest-rank p95 ≤250 ms、max ≤500 ms。
6. M5 Max 上使用合成 CAF，SQLite 重开后由真实 `AVAudioPlayer` 对开头/中间/结尾
   各点击 10 次：p95 44 ms、max 44 ms，通过批准阈值。原始 30 行结果见
   `m08-results.tsv`。

全仓回归：

```sh
env CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-cache" \
  swift test
```

结果：最终 44 tests / 5 suites passed（1.772 秒）；其中真实播放器 30 次测量
p95 44 ms、max 44 ms。

Release 编译：

```sh
env CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang-cache-release" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PAPERCLIP_RUN_SCRATCH_DIR/swiftpm-cache-release" \
  swift build -c release
shasum -a 256 .build/release/AIListenerApp
```

结果：Build complete。产物 `.build/release/AIListenerApp`，SHA-256
`a2569569dcb5cc7b853ee34d081d35f5eb533ca1554a7ce08abfe057b42bacf5`。

## 验证边界

- 已验证：repository 重开、UI/app Release 编译、错误状态、数据保留、seek 目标/实际位置
  报告、30 样本门槛计算，以及 M5 Max 上真实 `AVAudioPlayer` 合成 CAF 三位置各
  10 次测量（p95/max 44/44 ms）。
- 限定：M-08 使用公开生成的合成 CAF，不是私人/真人录音；未采集电源与温控，且不
  构成 ASR 性能基准。
- 未执行：真人麦克风 TCC 与最终 Demo；按授权应在全部自动化和 Release 包完成后由
  local-board 验收。
