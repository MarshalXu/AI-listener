# AI-2 macOS 双路音频采集尖刺 SDD

- 规格修订：SDD-r1
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

第一里程碑只验证原生 macOS 应用在用户明确授权后同时采集麦克风与系统音频，显示规定状态，停止后生成两份本地音频文件并可逐一播放。任一路不可用即不开始录音；不做单路降级。录音不上传，不接入转写或 AI。

本修订选择 AVFoundation 采集麦克风、ScreenCaptureKit 采集系统音频；两路保持分轨、共享会话时间基准，以 LPCM CAF 落盘。停止操作只有在两路均停止、文件完成关闭并通过最低完整性检查后才进入 `succeeded`。

## 变更与重新审批

任何范围、隐私、外部服务、持续成本、目录例外、质量门豁免，或对状态机、数据契约、采集 API、分轨策略、格式、持久化策略的实质修改，均产生新 SDD 修订并重新申请 Board 审批。审批前不得创建或执行实现任务。
