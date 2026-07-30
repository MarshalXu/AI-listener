# 06 验收矩阵与追溯

所有证据必须使用授权的公开/合成测试音频，不得访问真实用户录音。规格通过不等于产品已验证。

## 2026-07-30 第一版 Demo 执行 disposition

- Board 接受 sherpa-onnx 候选、模型/运行库 hash、许可证与已有自动验证作为阶段性 `T-01` gate，允许唯一主线继续 `T-05 → T-06 → T-07`。
- `M-01` 的 60 分钟语料、三轮 Release CER/RTF/partial-final 延迟/峰值内存基准，以及三名中文母语评审当前均为**未完成**；这些项目迁入 `T-07` Release 验收债务，不阻塞进入 `T-05`，但必须在 Release 验收包中逐项披露。
- 阶段性 gate 不是 `M-01` 或完整 `T-01` 通过。任何报告、Issue 或 Demo 说明均不得把未完成项目写成已验证或已通过。

## 证据分层

- `M-01…M-08`：仅可标记“当前 M5 Max 实机已验证”，且只能在 Primary Development & Demo Verification Environment 实际执行后标记；本规格阶段均为未验证。
- `M-09`：仅可标记“仅编译通过”；它证明 macOS 14.0 deployment target / arm64 编译兼容性，不证明 macOS 14 或 M1 实机行为。
- `M-10`：标记“待目标设备验证”；当前无 M1 8 GB 实体设备，默认不阻塞 M5 Max 本机 Demo。
- 迁入 `T-07` 的 Release 验收债务：在原始证据齐备前标记“未完成”；“未完成”不得与“当前 M5 Max 实机已验证”并列用于同一证据项。
- 每份证据必须且只能属于上述一个层级。M5 Max 的性能结果不得外推到 M1 8 GB，不得跨设备、OS 或配置聚合宣称通过。

| ID | 场景与前置 | 可观察预期 | 必需证据 | 追溯 |
|---|---|---|---|---|
| `M-01` | Primary M5 Max、锁定模型/语料、麦克风已授权；完成中文基准与 60 分钟录音 | clean CER ≤15%、noise CER ≤25%、可理解度 ≥90%；partial p95 ≤1.5s、final p95 ≤3.0s、RTF ≤0.8、峰值内存 ≤3.5GB 且报告占 48GB 比例、下载/落盘 ≤2/4GB；60 分钟录音与保存通过 | 三轮逐轮指标、语料/模型 hash、精确 OS/toolchain/Release/温控/电源环境清单、状态事件、DB 查询、音频 hash/时长、重启播放；层级：当前 M5 Max 实机已验证（执行后） | P-01…04; D-01…11; C-01…07; A-01…05; T-01…07 |
| `M-02` | fresh/denied/restricted 权限 | 仅由点击触发 Microphone；拒绝后不开始、不造空记录、可开设置；无 Screen Recording | TCC 三态录像/截图、事件、数据库无伪 Session、静态权限清单 | P-01/P-05; D-02/D-03; A-06; T-03/T-07 |
| `M-03` | 模型缺失、hash 错或加载失败 | 明示 transcript unavailable/degraded；录音、停止、保存、播放仍成功 | Model/Error code、音频 hash/时长、Session transcriptState、无网络捕获 | P-03/P-05; D-04/D-05/D-08; C-05/C-06; A-01/A-07; T-01/T-04/T-05 |
| `M-04` | 录音中模拟设备/route 中断 | 进入 interrupted→stopping；保存中断前音频；终止原因可见；不崩溃 | 状态/事件、可播放时长、DB terminationReason、重复 stop 幂等 | D-02…04/D-11; C-01/C-04/C-05; T-03/T-04 |
| `M-05` | 注入磁盘满、write/fsync/manifest/rename/dir-fsync/DB commit 失败 | 不标假 ready；每个阶段落入 temporary/stable/committed/quarantined + recoveryRequired 的唯一结果；重试幂等；无误删/孤儿静默清理 | 每个故障点目录树、DB、manifest、hash 前后对比与重启结果 | P-03; D-04/D-06/D-11/D-12; C-07; A-03/A-04; T-04 |
| `M-06` | 在 manifest 创建、文件 fsync、stablePendingCommit、rename、dir-fsync、DB commit、manifest 清理各点强退 | 严格按 D-11 矩阵恢复；可证明音频 recovered，冲突/坏文件 quarantined，孤儿不自动删除，逐字稿缺失不否定音频 | 七类崩溃夹具、恢复事件、文件/manifest/DB 状态、hash/播放、重复恢复幂等 | D-11; C-01/C-02/C-04/C-05/C-07; A-04; T-02/T-04 |
| `M-07` | ASR 慢、队列满、进程/adapter 失败 | writer 无丢帧并成功 commit；ASR 发 gap/degraded；已有 finalized 保留 | frame/文件 duration 对账、队列指标、错误事件、DB finalized 查询 | D-03…05; C-03/C-06; A-05; T-05 |
| `M-08` | Primary M5 Max 上含已知声学标记与 finalized startMs 的夹具；重开后点击开头/中间/结尾各 10 次 | 绝对定位误差 p95 ≤250ms、max ≤500ms | 30 次目标/实际毫秒表、精确 OS/toolchain/Release/模型 hash/温控/电源、播放器日志；层级：当前 M5 Max 实机已验证（执行后） | P-04; D-07/D-10; C-02/C-03; T-06 |
| `M-09` | deployment target macOS 14.0、arm64；使用批准的 Xcode/SDK 构建 | Release 配置编译成功；无 Intel slice 要求；部署目标未被提高 | 完整构建命令、deployment target、SDK/Xcode/Swift build、arm64 artifact 元数据；层级：仅编译通过 | README; P-01…05; T-07 |
| `M-10` | MacBook Air M1、8 GB unified memory、符合 deployment target 的 macOS 实机（当前不可用） | 独立执行 M-01…M-08；峰值内存同时报告绝对值与 8GB 比例；不得引用 M5 Max 结果代替 | 对应实体设备的逐项独立证据；取得前层级：待目标设备验证；默认不阻塞 M5 Max Demo | README; P-01; T-01/T-07 |

## 规格静态质量门

- 六类工件与 README 存在，所有 `P/D/C/A/T/M` 引用可解析。
- 搜索不存在 Swift、测试代码、工程脚手架或原型；本规格中的 “Tasks” 只定义未来增量，Paperclip 未创建实现子任务。
- 搜索无 Screen Recording 请求、系统音频实现范围或云 ASR 依赖；出现这些词只能在非目标/禁止/边界说明。
- AI-2 的事实基线必须写为 Board 已标记 `Cancelled`、SDD-r3 为 spec-only archived 技术储备；AI-3 不修改 AI-2 文件、描述或状态。
- deployment target/编译兼容性、Primary M5 Max 当前实机验证、M1 8 GB 待目标设备验证在 README/P-01/M-01/M-08/M-09/M-10 一致；每项证据只属于一个层级，不得混用或把 M5 Max 性能外推至 M1。
- A-01 必须保留 Qwen3-ASR/CoreML 的证据化评估及“不把未测写成失败”的淘汰边界。
- 最新完整修订必须绑定 AI-3 的 Board `request_confirmation`；接受前实现状态固定为未开始。

## 风险与升级

模型/权重许可证、中文性能实测、模型托管持续成本、备份/删除语义尚需 Board 在实施前定案。当前门槛已可审批但仍非实测结论。任何门槛调整、契约 major 变化或非目标进入范围属于实质规格变更：更新全包修订号、重跑静态追溯，并创建新的 confirmation；旧批准失效。
