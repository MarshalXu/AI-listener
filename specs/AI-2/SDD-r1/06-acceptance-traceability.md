# Acceptance & Verification Traceability

## 环境记录模板

- 硬件型号：
- macOS 版本/build：
- Xcode/Swift 版本：
- App build/commit：
- 麦克风类型（仅类别，不记设备名）：
- 测试音源：人工生成/公开许可，标识：
- 权限初始状态：
- 命令/步骤：
- 证据位置：

状态只能填：`未实现`、`已实现待验证`、`实现者验证通过/失败`、`独立验证通过/失败`、`阻塞`。独立 QA Agent 未另行获批前，禁止填“独立验证通过”。

## 测试矩阵

| ID | 场景与前置 | 操作 | 期望状态/结果 | 证据要求 | 规格映射 |
|---|---|---|---|---|---|
| V-01 | 两权限未决定 | 启动应用但不点击开始 | 无系统权限弹窗，`idle` | 屏幕记录/权限状态 | P-01；Design 权限 |
| V-02 | 两权限未决定 | 点击开始、阅读说明、允许两项 | `requestingPermission` 后两路首 buffer 才 `recording` | 状态事件序列、权限截图、首 buffer 计数 | P-02；不变量 1 |
| V-03 | 正常录制 | 同时播放测试系统音与对麦克风发声 | 两路 frameCount/指示均增长 | 脱敏计数日志；不使用真实录音 | P-03；ADR-002 |
| V-04 | 正常录制 | 点击停止 | `recording → stopping → succeeded`；恰有两份 final CAF | 状态序列、manifest、格式/帧/字节检查 | P-04；不变量 2 |
| V-05 | V-04 工件 | 逐一播放 microphone/system | 两轨均完成播放 | playback started/completed 事件、人工听检记录 | P-04 |
| V-06 | 麦克风 denied | 点击开始 | `failed(permission.microphoneDenied)`；无采集/成功文件；有设置恢复 | 截图、事件、目录检查 | P-05 |
| V-07 | Screen Recording denied | 点击开始 | `failed(permission.screenRecordingDenied)`；无采集/成功文件 | 截图、事件、目录检查 | P-05 |
| V-08 | 麦克风不可用/被占用 | 点击开始 | `failed(input.microphoneUnavailable)`；系统采集被回滚 | failure injection/实体证据、资源释放断言 | P-05 |
| V-09 | 系统音频不可用 | 点击开始 | `failed(input.systemAudioUnavailable)`；麦克风被回滚 | failure injection/实体证据 | P-05 |
| V-10 | 任一 start/首 buffer 故障 | 点击开始 | 不进入 recording；partial 不可播放 | 单测、超时/错误事件 | P-05 |
| V-11 | recording 中注入 stop failure | 点击停止 | 经 stopping 到 failed；无资源存活；首要错误保留 | 单测/诊断事件/资源计数 | P-06 |
| V-12 | open/append/close/commit 任一步失败 | 录制或停止 | failed；不得有 succeeded manifest；partial 标记正确 | 每阶段 failure injection | P-06 |
| V-13 | final 文件不可读/播放设备失败 | 播放 | session 仍 succeeded；显示 playback error 与恢复动作 | 状态断言、错误事件 | P-06；ADR-007 |
| V-14 | 重复 start/stop、非法事件 | 快速重复操作 | 单 active session；stop 幂等；无崩溃 | 单元/压力测试事件序列 | Design 状态机 |
| V-15 | 中途终止后重启 | 制造 partial 并重启 | partial 标记 abandoned，不提升为 final | 恢复测试、manifest | 数据生命周期 |
| V-16 | 隐私审查 | 完成正常/失败路径 | 无网络请求；日志无音频、绝对路径、标题、设备名；文件仅本地容器 | 网络/日志/文件清单 | P-07；ADR-004 |
| V-17 | 契约兼容 | 读写 v1、加入未知字段/枚举 | round-trip；忽略未知字段；unknown 安全处理 | 单元测试 | Data Contracts |
| V-18 | 质量门 | 干净环境构建和测试 | Xcode build 成功、unit tests 全通过，复现步骤完整 | 命令、环境、原始摘要、证据索引 | P-08；ADR-006 |

## 需求到证据映射

| Proposal | 验证 |
|---|---|
| P-01 | V-01、V-02 |
| P-02 | V-02 |
| P-03 | V-03 |
| P-04 | V-04、V-05 |
| P-05 | V-06 至 V-10 |
| P-06 | V-11 至 V-13 |
| P-07 | V-15、V-16 |
| P-08 | V-17、V-18 |

## 从零复现步骤（未来验证执行模板）

1. 记录硬件、macOS、Xcode、app build；确认使用生成/公开许可测试音，不含真实用户录音。
2. 在 System Settings 重置或记录 Microphone 与 Screen Recording 权限。
3. 按批准的干净构建命令构建并运行；证明未点击开始前无权限请求。
4. 点击开始，确认统一用途说明；按场景授予或拒绝权限。
5. 正常路径播放测试系统音并制造麦克风测试声，观察两路计数与状态。
6. 点击停止，记录状态序列、两份文件 metadata 与 manifest；逐轨播放。
7. 使用批准的 failure injection 逐项执行 V-06 至 V-15；每次新建 session。
8. 执行日志/网络/文件隐私检查和契约/单元测试。
9. 报告分列“已实现、已验证、待验证、风险”；不得由实现者代替独立 QA/Review 结论。

## 当前验证状态

- 规格一致性：待本次静态检查并挂证据。
- 实现：未开始。
- 构建/单元/实体音频/权限/异常：未执行；Board 批准前禁止执行实现验证。
- 独立 QA/Code Review：未创建、未执行，且不在本规格任务授权内。
