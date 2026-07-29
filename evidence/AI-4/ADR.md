# ADR AI-4：本轮否决锁定 ASR engine

- 状态：Accepted for this evidence revision
- 日期：2026-07-29
- 决策范围：仅 T-01 隔离基准，不修改 SDD-r3

## Context

SDD-r3 要求候选同时满足中文质量、partial/final latency、RTF、内存、尺寸与许可证门槛。Board 已批准本 T-01 的隔离范围例外和官方来源下载，但未授权降低质量门。

## Decision

本轮不选择 WhisperKit，也不选择 sherpa-onnx：

- WhisperKit runtime 许可证明确，但锁定的 Argmax Core ML 模型仓库未声明具体转换权重许可证，故许可证门未通过；不执行性能下载不能改变这一否决。
- sherpa-onnx runtime 与锁定 14M 中文流式模型的 Apache-2.0 证据可追溯，三轮短样本 RTF、内存与尺寸探针通过；但样本不满足 30 分钟 clean + 30 分钟 noise、10 名说话人、CER、3 人可理解度和 partial/final latency 要求，故完整性能/质量门未通过。

“未通过”表示证据不足或门槛未完成，不表示 sherpa 的准确率已实测失败，也不表示 WhisperKit 权重已证明禁止分发。

## Consequences

- T-05 不得开始，WhisperKit 不得被默认认定为已通过。
- 现有短样本数据可作为后续环境 smoke baseline，但不得用于 Demo 质量验收。
- 若 Board 提供/批准满足 SDD 的固定公开语料、reference manifest 和评审资源，可重开 T-01 新一轮证据；若要调整语料、评审或 latency 门槛，必须形成实质规格修订并重新审批。
- Qwen3-ASR/CoreML 仍为未入围/未测，不得写成性能失败。

## Rejected alternatives

- 以模型自带三条 WAV 代替固定 60 分钟语料：拒绝，样本规模与说话人覆盖不满足规格。
- 以 OpenAI Whisper 上游 MIT 推定 Argmax 转换工件再分发许可：拒绝，缺少具体工件的可追溯声明。
- 仅凭 RTF/内存/尺寸锁定 sherpa：拒绝，质量与实时事件门槛仍缺失。
