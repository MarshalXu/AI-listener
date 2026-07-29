# SDD-r1 → SDD-r2 Board 意见对照

| Board 意见 | r2 修改 | 证据位置 |
|---|---|---|
| 更新 AI-2 事实状态 | 明确 AI-2 已 `Cancelled`，SDD-r3 仅 spec-only archived；AI-3 未修改 AI-2 | README、M 静态质量门 |
| 当前规格给出首版门槛 | 固定语料/CER/可理解度、partial/final、RTF、内存、模型尺寸、60 分钟录音、定位误差均有暂定数值；调整需 Board 批准 | P 成功标准、M-01/M-08 |
| 明确平台/基准环境 | macOS 14、Apple Silicon；M1 8GB + Xcode 16.2/Swift 6.0.3，结果不得跨设备混合 | README |
| 加入 Qwen3-ASR/CoreML | 增加三方比较及许可证、流式/CoreML 成熟度、尺寸/集成风险淘汰理由；未伪造测量 | A-01 |
| 修正任务依赖 | T-04 明确依赖 T-02/T-03；T-05/T-06/T-07 补齐输入与停止条件 | Tasks |
| 补全原子持久化 | 定义 manifest 创建、fsync/rename/DB commit 顺序和七类崩溃确定性处置 | D-11、C-07、A-04、M-05/M-06 |
| 保持产品范围 | 仍仅麦克风、完全本地；ASR 与 writer 隔离；未加入任何禁止项 | P 非目标、Design 不变量 |

规格状态：SDD-r2 待 Board 审批。实现状态：未开始；实现文件与实现子任务为 0。验证状态：仅静态规格追溯，不代表产品验证。
