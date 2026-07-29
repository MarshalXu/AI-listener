# AI-3：仅麦克风离线中文听记 MVP SDD-r2

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

- 最低系统：macOS 14.0；仅支持 Apple Silicon（M1 及以上），不支持 Intel。
- 唯一可宣称门槛通过的基准环境：MacBook Air M1（8-core CPU/7-core GPU、8 GB unified memory）、macOS 14.7.x、Xcode 16.2/Swift 6.0.3、Release build、接通电源。精确 OS patch、设备标识、温控状态、模型/权重 hash 必须随证据记录。
- 其他 Apple Silicon 设备可报告独立结果，但不得与基准机混合聚合或据此宣称基准通过；环境变化须单列并经 Board 确认。
- 首版暂定成功门槛见 `01-proposal.md` 与 `06-acceptance-traceability.md`。`T-01` 负责验证并可建议调整，任何调整仍须 Board 批准，不能由实现者自行放宽。

## 追溯标识

- `P-*`：Proposal 结果
- `D-*`：Design 要求
- `C-*`：Contract
- `A-*`：ADR
- `T-*`：未来可独立验收增量（不是已创建的实现任务）
- `M-*`：验收场景

## 当前状态

- 规格状态：SDD-r2 完整，已逐项吸收 r1 Board rejection，待 Board 重新审批。
- 实现状态：未开始；代码、测试代码、脚手架、原型变更为零；未创建实现子任务。
- 验证状态：仅完成规格静态一致性与边界核对；未构建、未运行、未验证产品行为。
- 风险：当前数值是可审批的暂定门槛，不是已测结果；中文质量、实时延迟/内存、模型许可证与分发尺寸仍须在批准后的隔离基准增量中验证。
- 下一步：Board 对本修订给出批准或修订意见；批准前不得进入实现。
