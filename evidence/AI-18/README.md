# AI-18 / T-07 Release Demo 集成与验收包

日期：2026-07-30

## 结论与规格状态

AI-3 SDD-r3 已获 Board 批准，批准时提供的 aggregate SHA-256 为
`7711eca19ef7c255a729adad4c48f97ac3b94639356f1a5a9d07723c49e5863e`。
本增量未改变产品范围、数据契约、系统权限或质量阈值。工作树中
`05-tasks.md`、`06-acceptance-traceability.md` 的 Board disposition 明确：
现有 sherpa-onnx 候选只构成阶段性 T-01 gate；完整 M-01 不能据此宣称通过。

输入为已合入的 T-02～T-06、AI-4 锁定的 sherpa-onnx runtime/model、
AI-9 SPDX SBOM，以及公开/合成音频证据。输出为 ad-hoc 签名的原生 arm64
Release app bundle、逐文件 SHA-256、从零运行说明、M-01～M-10 证据索引、
失败恢复说明和真人验收清单。

停止条件：若需要云 ASR、真实用户录音、付费/生产密钥、许可证豁免、新增权限、
删除用户数据、外部发布或修改批准阈值，停止并升级 Board。本次未触发。

## Release 产物

- app：`dist/AIListener.app`
- 逐文件清单：`dist/AIListener.app.sha256`
- Bundle ID：`com.ailistener.local`
- version/build：`0.1.0 (1)`
- deployment target：macOS 14.0；Mach-O arm64
- 签名：本地 ad-hoc，仅供 Board 本机 Demo；未 notarize、未发布
- 权限声明：仅 `NSMicrophoneUsageDescription`；无 Screen Recording entitlement
- 内置离线工件：sherpa C API、ONNX Runtime、3 个 int8 ONNX 文件、tokens、
  sherpa Apache-2.0 LICENSE、model card、SPDX 2.3 SBOM

2026-07-30 local-board 首轮真人 Demo 发现 Release UI 没有连接 T-05 pipeline：
默认空 `frameSink` 丢弃了麦克风帧。该验收正确判为失败。本 revision 新增
`RecordingSessionPipeline`，并由 `CaptureViewModel` 显式连接 writer-first
音频保存、16 kHz 转换、sherpa streaming ASR、partial/finalized UI 和 finalized
SQLite 持久化；`ContentView` 新增滚动字幕区域。不得用首轮失败前的包验收本 revision。

第二轮真人验收确认实时中文 partial 正常，但发现连续 finalized 时间范围契约冲突、
记录页没有在停止后刷新；随后 reviewer 要求主页面提供“清屏”。当前 revision 已将
sherpa segment 起点钳制到上一 finalized 终点之后，持久化失败会显示安全的具体底层
错误码；Session finalize 后主动通知记录页刷新且记录页 `onAppear` 再次 reload；
“清屏”只清 transient UI，不删除 SQLite、Session 或音频。

修复后再次执行 `scripts/package-release-app.sh`：Release build 成功，
`codesign --verify --deep --strict` 成功，bundle 约 58 MiB。当前 app 可执行文件
SHA-256 为 `36afe4e098496588ef686747f874bf32ba873f1fb3a9f35091f86c39b86b364d`；
逐文件清单本身 SHA-256 为
`94722659b1e315e903896137dd4319577bab5b6452e9a65ba9408a95b2348a0a`。

## 从零构建与恢复

在仓库根目录执行：

```sh
mkdir -p "$PAPERCLIP_RUN_SCRATCH_DIR/clang" \
  "$PAPERCLIP_RUN_SCRATCH_DIR/build"
env CLANG_MODULE_CACHE_PATH="$PAPERCLIP_RUN_SCRATCH_DIR/clang" \
  scripts/package-release-app.sh dist "$PAPERCLIP_RUN_SCRATCH_DIR/build"
codesign --verify --deep --strict --verbose=2 dist/AIListener.app
shasum -a 256 dist/AIListener.app.sha256
```

若普通 `swift test` 因受管环境不能写 `~/.cache/clang`，这是 cache 路径限制；
把 `CLANG_MODULE_CACHE_PATH`、SwiftPM `--cache-path`、`--config-path`、
`--security-path` 和 `--scratch-path` 指向 `PAPERCLIP_RUN_SCRATCH_DIR` 后重试。
不要重置 TCC、不要删除数据库或用户音频。启动时的恢复器会保留无法归属或损坏的
工件并标记 `recoveryRequired/quarantined`，不会静默删除。

应用数据由 app 写入 Application Support 下自身目录。模型和 runtime 已包含在
bundle；首个 Demo 不需要网络下载。用户必须通过一次明确点击“开始录音”触发
Microphone TCC。拒绝或 restricted 时不得创建空 Session。

## 自动验证记录

2026-07-30 修复后 Release 全仓测试以隔离 cache 执行：构建成功；共发现 45 个测试，
44 个通过。原有
`productPipelineWritesAudioRunsASRAndPersistsFinalizedTranscript` 以同一产品
pipeline 注入单声道合成麦克风帧，验证 CAF 落盘、ASR partial/finalized 路径、
finalized SQLite 和 ready Session。既有 sherpa 公共中文 WAV 解码测试同轮通过。
唯一失败是
`actualPlayerMeetsThirtyClickSyntheticMarkerGateAfterReopen` 在当前受管进程返回
`playerUnavailable`。同一测试在 AI-17 的 M5 Max 实机执行证据中曾以 30/30
合成 CAF 点击通过（p95/max 44/44 ms，原始行见
`evidence/AI-17/m08-results.tsv`）。本次不把历史成功改写为当前执行成功，也不把
受管进程的 audio-service 不可用当作产品回归已证实；local-board 应在最终 Demo
重跑该项。

本 revision 定向执行两个产品 pipeline 测试，2/2 通过；新增
`productPipelinePersistsMultipleFinalizedSegmentsInOrder` 连续产生两个 finalized，
验证完整逐字稿和 ready Session 可被记录列表查询。UI 的停止后即时刷新、清屏语义、
App 重启与真人点击回听仍须由 local-board 按清单复验，不能由该 core 测试替代。

本轮已独立验证 Release app 编译、arm64/14.0 metadata、ad-hoc codesign、
bundle 文件与模型清单。AI-16 已有一次重复公开 WAV 至 3,600 秒的 Release
adapter stress：RTF `0.00017951833333333332`、peak RSS `20,643,840` bytes，
未观察到网络 socket；这是长输入 adapter 稳定性证据，不是三轮 M-01
CER/streaming latency/真人评审。

## M-01～M-10 证据索引

| 场景 | 当前状态 | 证据 / 剩余动作 |
|---|---|---|
| M-01 质量与 60 分钟 | **未完成** | AI-9 harness、AI-16 单轮 stress 可复用；仍缺固定 60 分钟语料、三轮 CER/partial-final latency/RTF/RSS 和三名中文母语评审 |
| M-02 TCC 三态 | **待 local-board 真人验收** | `evidence/AI-6/README.md` 自动状态机证据；按下方清单执行 fresh/denied/restricted |
| M-03 模型失败降级 | 自动化已验证 | `StreamingASRTests`：ASR failure 不阻塞 writer；AI-16 真实 runtime/model 验证 |
| M-04 捕获中断 | 自动化已验证 | `CaptureCoordinatorTests.interruptionStopsCaptureAndRecordsReason` |
| M-05 写入失败 | 自动化已验证 | `AtomicAudioAssetWriterTests.failureNeverPublishesFalseReady` 六个 commit 点及 disk-full 夹具 |
| M-06 启动恢复 | 自动化已验证 | `AtomicAudioAssetWriterTests` recovery/audit/quarantine/idempotency；不是独立进程七点强退的完整原始矩阵 |
| M-07 ASR 慢/失败 | 自动化已验证 | `StreamingASRTests` bounded queue、gap、writer-first、engine failure，以及产品 pipeline 的音频/ASR/UI 事件/SQLite 接线测试 |
| M-08 30 次 seek | 历史 M5 Max 实机合成夹具已验证；本轮受管进程未复现 | `evidence/AI-17/README.md`、`m08-results.tsv`；最终 Demo 重跑 |
| M-09 macOS 14/arm64 | **仅编译通过** | Package target 14.0、Mach-O arm64、Release build；不等于 macOS 14 实机验证 |
| M-10 M1 8 GB | **待目标设备验证** | 当前无实体设备，按批准规格不阻塞 M5 Max Demo |

## 风险与下一步

完整 T-07 尚不能宣称通过：M-01 的三轮质量/性能与三人评审未完成，当前 heartbeat
的真实播放器自动测试也没有通过。首轮真人 Demo 的空 `frameSink` 缺陷已经修复并由
产品级合成帧集成测试覆盖，但新的 Release 仍需真人麦克风复验，不能由自动化代替。
其余主要风险是 ad-hoc 签名首次运行体验与真人 TCC。owner `local-board` 按
`LOCAL-BOARD-CHECKLIST.md` 执行真人 TCC、M-08 重跑和最终 Demo；若 Board 要求
完整 M-01 作为本次 Demo 的硬门，则继续运行 AI-9 三轮 harness，而不是调整阈值。
