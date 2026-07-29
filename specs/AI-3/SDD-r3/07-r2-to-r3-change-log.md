# SDD-r2 → SDD-r3 Board 意见对照

| Board 意见 | r3 修改 | 证据位置 |
|---|---|---|
| 当前实际环境设为 Primary | 固定为 MacBook Pro / M5 Max / 48 GB / macOS 26.5.2 / Xcode 26.6 / Swift 6.3.3 / arm64；首轮 Demo 只以该机独立证据判断 | README、P、M-01…M-08 |
| 报告可复现环境细节 | 强制记录精确 OS build、Release 配置、模型 hash、硬件/工具链、温控和电源状态 | README、P、T-01、M-01/M-08 |
| 区分三层证据 | macOS 14/arm64 是 deployment target 与编译兼容性；M5 Max 是当前实机；M1 8 GB 是待目标设备验证 | README、P、M-09/M-10 |
| 禁止性能外推 | M5 Max 不得外推至 M1；M1 门默认不阻塞本机 Demo，设备结果不得混合 | README、P、M-10 |
| 峰值内存双报告 | 保留 ≤3.5 GB 暂定门槛，并要求报告绝对值与 unified memory 占比 | P、T-01、M-01/M-10 |
| 验收逐项标层 | M-01…M-10 每项明确当前实机、仅编译或待目标设备验证；当前均未执行 | M |
| r2 其余修改保持 | 产品范围、Qwen3-ASR/CoreML 结论、原子协议、任务依赖与 AI-2 Cancelled 基线未改变 | README、A-01、D-11、Tasks |

规格状态：SDD-r3 待 Board 审批。实现状态：未开始；实现文件与实现子任务为 0。验证状态：仅静态规格追溯，不代表产品验证。
