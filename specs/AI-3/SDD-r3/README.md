# AI-3：仅麦克风离线中文听记 MVP SDD-r3

- 状态：待 Board 审批；本文档不授权实现
- 日期：2026-07-29
- 权威输入：AI-1 `roadmap-30d` revision 1、AI-3 描述与验收标准
- 顺序：Proposal → Design → Data Contracts → ADRs → Tasks → Board 审批 → 实现
- 契约版本：`ai-listener.contracts/1.0`

## 工件

1. [01-proposal.md](01-proposal.md)
2. [02-design.md](02-design.md)
3. [03-data-contracts.md](03-data-contracts.md)
4. [04-adrs.md](04-adrs.md)
5. [05-tasks.md](05-tasks.md)
6. [06-acceptance-traceability.md](06-acceptance-traceability.md)

## 规格基线与边界

唯一产品闭环：默认仅麦克风 → 本地实时中文 ASR → partial/finalized 滚动字幕 → 停止 → 保存本地音频与 finalized 逐字稿 → 重开记录 → 点击 finalized 字幕定位回听。

明确不包含 Screen Recording、系统音频、双路录制、说话人识别、摘要/行动项、日历、账户、云同步、聊天、多模型设置、复杂导出、移动端和发布。AI-2 已由 Board 手动标记为 `Cancelled`，其 SDD-r3 仅是 spec-only archived 技术储备；AI-2 的规格、状态与内容不属于本规格，AI-3 禁止修改、替代或扩展。

## 首版平台与验收基线

- Deployment target / 编译兼容性目标：macOS 14.0；仅支持 Apple Silicon（M1 及以上），不支持 Intel。该目标只表示构建配置与编译兼容性要求，不等于已在 macOS 14 或 M1 实机验证。
- Primary Development & Demo Verification Environment：MacBook Pro、Apple M5 Max、48 GB unified memory、macOS 26.5.2、Xcode 26.6、Swift 6.3.3、arm64。首轮 Demo 是否通过仅以该当前实机的独立证据判断。
- M1 8 GB 是目标最低支持范围与后续独立低端性能门；当前无对应实体设备，状态固定为“待目标设备验证”，不阻塞 M5 Max 本机 Demo，除非 Board 另行要求。
- 每份实机报告必须记录精确 hardware identifier、macOS build、Xcode/Swift build、arm64、Release 配置、模型与权重 hash、应用 commit/build 标识、温控状态及电源状态。每份编译报告必须记录 deployment target、SDK、架构与编译器版本。
- M5 Max 性能结果不得外推至 M1 8 GB；不同设备、OS 或构建配置的结果必须分开报告，禁止聚合宣称通过。
- 首版暂定成功门槛见 `01-proposal.md` 与 `06-acceptance-traceability.md`。`T-01` 负责验证并可建议调整，任何调整仍须 Board 批准，不能由实现者自行放宽。

## 追溯标识

- `P-*`：Proposal 结果
- `D-*`：Design 要求
- `C-*`：Contract
- `A-*`：ADR
- `T-*`：未来可独立验收增量（不是已创建的实现任务）
- `M-*`：验收场景

## 当前状态

- 规格状态：SDD-r3 完整；仅按 r2 Board rejection 修正执行环境与验收分层，r2 其余已通过修改保持不变，待 Board 重新审批。
- 实现状态：未开始；代码、测试代码、脚手架、原型变更为零；未创建实现子任务。
- 验证状态：仅完成规格静态一致性与边界核对；未构建、未运行、未验证产品行为。
- 风险：当前数值是可审批的暂定门槛，不是已测结果；M5 Max 尚未执行产品验证，M1 8 GB 尚无实体设备；中文质量、实时延迟/内存、模型许可证与分发尺寸仍须在批准后的隔离基准增量中验证。
- 下一步：Board 对本修订给出批准或修订意见；批准前不得进入实现。
