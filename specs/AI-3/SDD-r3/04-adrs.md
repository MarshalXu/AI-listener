# 04 ADRs

所有决策为 SDD-r3 proposed；Board 批准后才可实施。

## `A-01` ASR：首选 WhisperKit，sherpa-onnx 为基准备选，Qwen3-ASR/CoreML 暂不入围

决策：先以 WhisperKit adapter 做中文离线可行性基准；只有 `T-01` 在目标设备/固定中文语料满足经 Board 固化的质量、partial 首现、finalized 延迟、RTF、峰值内存和安装体积门槛，才成为 MVP engine。并行纸面备选为 sherpa-onnx streaming 中文模型；不在 UI 暴露多模型设置。

| 维度 | WhisperKit | sherpa-onnx | Qwen3-ASR/CoreML |
|---|---|---|---|
| 中文/实时 | Whisper 多语种，官方仓库/论文声明 on-device real-time/streaming；中文专项质量仍需实测 | 官方项目声明 streaming/non-streaming、macOS 与中文模型；具体普通话模型需锁定 | Qwen3-ASR 上游声明中文与 streaming，但 streaming 目前仅 vLLM backend；本规格未找到上游支持的 macOS CoreML 流式发行物，不能把 vLLM 能力等同于 CoreML partial/final |
| 支持面 | Apple Silicon/Core ML 路径与原生 Swift 集成契合 | macOS 可用但 ONNX Runtime/模型打包面更宽、集成复杂度更高 | 需要第三方/自建 CoreML 转换、算子验证、状态缓存和 Swift bridge；成熟度与可复现性风险高 |
| 模型体积 | 随 Whisper variant/Core ML 工件变化；不得在无锁定 manifest 时写死 | 随 Zipformer/Paraformer 等模型变化；不得把单个示例推广 | 参数规模与量化/转换产物相关；没有锁定 artifact 前不写死体积，且可能触碰 2 GB/4 GB 暂定门槛 |
| 延迟/内存 | 有项目级实时证据，无本产品目标机测量 | 有 streaming 能力证据，无本产品目标机测量 | 无本产品目标机 CoreML 测量，也无可依赖的上游流式 CoreML 基线 |
| 离线分发 | 模型可显式下载、校验后完全离线；需固定 artifact/hash | 同样可下载后离线；需同时审计 runtime 与 model license | 理论上转换后可离线，但转换链、权重来源、hash 与再分发边界尚未锁定 |
| 许可证 | WhisperKit repo 为 MIT；模型卡/权重另审 | sherpa-onnx 为 Apache-2.0；每个模型权重另审 | 官方 repo 与 1.7B 模型卡当前标示 Apache-2.0；仍须锁定具体 commit/权重 hash，并审计 CoreML 转换工具、依赖、NOTICE 与派生产物 |

决策理由：Qwen3-ASR 的官方 vLLM streaming 不能直接用于原生 macOS CoreML 路径；CoreML partial/final、转换成熟度、可锁定工件尺寸/内存与转换依赖许可证链证据不足，首版不进入候选基准，也不下载/转换权重。若未来有上游可复现的流式 CoreML artifact、完整许可证/SBOM，并能在 README Primary Environment 评估，须新 ADR 和 Board 重批后才可入围。不得把“未测”写成“不达标”。

停止条件：任一候选许可证/模型权重不允许目标分发，或基准失败，不进入集成；升级 Board 选择另一 adapter/调整门槛。证据：[WhisperKit 官方仓库](https://github.com/argmaxinc/WhisperKit)、[WhisperKit 论文](https://arxiv.org/abs/2507.10860)、[sherpa-onnx 官方仓库](https://github.com/k2-fsa/sherpa-onnx)、[Qwen3-ASR 官方仓库](https://github.com/QwenLM/Qwen3-ASR)。

## `A-02` SQLite 为真相源

选择 SQLite（WAL、foreign keys、事务迁移）保存 Session、AudioAsset 引用、finalized segments、事件和错误；音频 bytes 不放 BLOB。理由是原子事务、崩溃恢复与可查询顺序优于散落 JSON/Markdown。Markdown 非 MVP 且永不是真相源。

## `A-03` 音频格式

选择单声道 Linear PCM CAF 作为首个正确性基线：AVFoundation 原生、无有损编码、崩溃后较易检查；代价为体积较大。压缩格式须在后续 ADR 比较 CPU、尺寸、可恢复性后重批，不可静默改变。实际 sample rate 记录在 AudioAsset，不假设设备恒定。

## `A-04` 原子持久化

采用 `D-11/C-07` 协议：首帧前持久化 recovery manifest；音频文件 fsync/close/hash；manifest 宣告 stablePendingCommit；同卷 atomic rename 与 parent-directory fsync；最后 SQLite 事务登记 committed 资产与 ready；DB commit 确认后才清理 manifest。任何窗口崩溃均按确定性矩阵重放或 quarantine，禁止先标 ready、静默删除孤儿或覆盖外部文件。

## `A-05` VAD/切块

VAD/切块属于 ASR adapter，不属于录音 writer。自然停顿优先 finalize；必须设最大 chunk 上限防止长语音无限增长。具体阈值由 `T-01` 基准，阈值变化属于 engine config version 并写入事件。VAD 失败可退化为定长重叠窗口，不能丢录音。

## `A-06` 麦克风权限

只在用户点击录音后查询/请求 Microphone TCC；拒绝/受限时显示解释和系统设置入口，不自动重复请求。Info.plist 文案必须说明本地录音/转写用途。禁止导入或调用 ScreenCaptureKit 权限流，禁止请求 Screen Recording。

## `A-07` 模型分发与许可证

首启不隐式下载。用户显式选择“下载离线中文模型”后展示大小、来源、许可证和磁盘需求；下载到 staging，校验 SHA-256/manifest/signature（若上游提供），再原子激活。离线录音不依赖模型存在。应用/runtime license 与具体权重 license 分开形成 SBOM；版本升级不自动接受新许可证。持续托管成本或外部下载服务必须升级 Board。

## `A-08` 参考项目边界

- Muesli（MIT）：仅借鉴 native/local-first、partial/final 分离、VAD 自然停顿、时间轴关联；不复制实现。证据：[官方仓库](https://github.com/pHequals7/muesli)。
- MacParakeet（上游标示 GPL-3.0）：仅借鉴来源选择行为中“仅麦克风不请求 Screen Recording”和音频保留策略；本 MVP 不实现来源选择。许可证评估完成前严禁复制代码、资源或派生结构，审查结论须入 SBOM/ADR。
- Meetily（MIT）：仅借鉴录音/本地 ASR 核心与增强功能失败隔离；不采用 Tauri/Rust 主架构。证据：[项目开源说明](https://meetily.ai/open-source-ai-note-taker)。
- Anarlog/原 Char/Hyprnote（上游标示 MIT）：仅借鉴 SQLite 真相源、本地音频文件、LLM 可替换；本 MVP 无 LLM/Markdown。仓库身份、当前许可证与第三方依赖必须在复用前重新锁定，当前不复制代码。

行为借鉴不等于许可证许可；未来任何代码复用必须逐文件 provenance、NOTICE 与法务/Board 审批。
