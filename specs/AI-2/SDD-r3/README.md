# AI-2 macOS 双路音频采集尖刺 SDD

- 规格修订：SDD-r3
- 日期：2026-07-29
- 上游基线：AI-1 hiring plan revision 2（revisionId `75fc864a-b72c-4dda-964b-c728151f8930`，Board 已接受）
- 阶段：仅规格；实现、原型、脚手架均未开始
- 审批顺序：Proposal → Design → Data Contracts → ADRs → Tasks → Board 审批 → 实现

## 工件

1. [01-proposal.md](01-proposal.md)
2. [02-design.md](02-design.md)
3. [03-data-contracts.md](03-data-contracts.md)
4. [04-adrs.md](04-adrs.md)
5. [05-tasks.md](05-tasks.md)
6. [06-acceptance-traceability.md](06-acceptance-traceability.md)

## 规格结论

第一里程碑只验证原生 macOS 应用在用户明确授权后同时采集麦克风与系统音频，显示规定状态，停止后生成两份本地音频文件并提供逐轨播放能力。任一路不可用即不开始录音；不做单路降级。录音不上传，不接入转写或 AI。

本修订选择 AVFoundation 采集麦克风、ScreenCaptureKit 采集系统音频；两路保持分轨、映射到共享单调纳秒时间轴，以 LPCM CAF 落盘。停止操作只有在两路均停止、文件完成关闭与确定性提交、Session Manifest v1 提交，且两份 final 文件均通过可解码验证后才进入 `succeeded`。实际播放是独立操作结果，不是 `succeeded` 门槛。

## SDD-r3 修剪结论

Board 最新意见不改变 AI-2 的双路音频技术尖刺目标，也不授权实时 ASR 或首版产品 Demo 实现。本修订保留 r2 对成功语义、Session Manifest 与共享时间轴的必要修复；删除产品路线图叙述，并把未来转写契约收窄为验收标准要求的本地工件交接边界。麦克风单路实时 ASR Demo、模型 ADR 与离线验收标准必须另立规格任务并单独审批。

## Board 退回项累计对照

| Board 退回项 | 当前处理 | 工件 |
|---|---|---|
| 1. 统一 `succeeded` 与“可播放” | `succeeded` 明确定义为两份 final 文件已提交、可打开并解码至少一个音频 packet/frame；不要求实际播放完成。实际播放成功/失败独立记录，同步修订 P-04/P-06、状态机、ADR-007、V-04/V-05/V-13。 | Proposal、Design、Data Contracts、ADR-007、Traceability |
| 2. Session Manifest v1 | 新增完整字段、状态约束、写前日志式提交顺序、崩溃恢复表；第二份提交失败时确定性回滚已改名文件为 `.abandoned`，不得存在 committed manifest。 | Design、Data Contracts、ADR-004/005、Tasks、Traceability |
| 3. 共享单调时间轴 | 定义 source PTS → nanoseconds 的有理数换算、每路首帧原点、session epoch、起始偏差与窗口漂移计算；尖刺阈值为起始偏差 ≤100 ms、10 分钟漂移 ≤50 ms，超限失败且不宣称同步。 | Proposal、Design、Data Contracts、ADR-002、Tasks、V-19/V-20 |
| 4. 范围不变 | 再次明确本轮只有规格修订，零代码、零实现任务；转写、摘要、云端能力仍排除。 | 全包 |
| 5. 产品方向隔离 | 删除本包中的产品体验路线图叙述；仅声明麦克风单路实时 ASR Demo 及模型比较属于独立规格，不进入 AI-2。 | README、Proposal、Data Contracts |

## 变更与重新审批

任何范围、隐私、外部服务、持续成本、目录例外、质量门豁免，或对状态机、数据契约、采集 API、分轨策略、格式、持久化策略的实质修改，均产生新 SDD 修订并重新申请 Board 审批。审批前不得创建或执行实现任务。
