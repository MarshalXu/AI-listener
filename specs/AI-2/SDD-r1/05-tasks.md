# Future Implementation Tasks

> 本文只定义 Board 批准后可由 CEO 另行创建的未来任务；当前未创建、未分派、未执行任何实现任务。每项负责人均为“待 CEO/Board 批准后指派”，不得由本规格自动授权。

## T-01 规格基线与工程质量门

- 依赖：SDD-r1 Board 批准。
- 负责人：Founding macOS Engineer（待 CEO 创建任务）。
- 输入：完整 SDD-r1、批准 revisionId、批准目录。
- 输出：原生 macOS 工程配置、构建/测试命令说明、无业务实现的质量门配置。
- 验收证据：Xcode 版本、macOS 版本、干净构建命令与成功日志、测试入口、产品文件均在批准目录的清单。
- 停止条件：审批 revision 不匹配；需目录例外、外部依赖/持续成本或签名发布；升级 Board。

## T-02 数据契约、状态机与协调器

- 依赖：T-01。
- 负责人：Founding macOS Engineer。
- 输入：Design 状态转移、不变量、Data Contracts v1。
- 输出：可编译的契约模型、串行状态机、可注入 Clock/ID/failure seams。
- 验收证据：每个合法/非法转移的单元测试；重复 start/stop、首要错误保留、两路首 buffer 守卫证据；schema round-trip/未知字段测试。
- 停止条件：需要改变状态集合、成功语义或 breaking contract；更新规格并重审。

## T-03 权限流程与用户说明

- 依赖：T-02。
- 负责人：Founding macOS Engineer。
- 输入：双权限流程、用途文案要求、错误码。
- 输出：用户触发的麦克风/Screen Recording 查询与请求、设置恢复路径、权限状态 UI。
- 验收证据：首次不自动请求；allowed/denied/notDetermined/restart-required 的测试或实体截图/录屏（不含敏感内容）；状态事件。
- 停止条件：需要私有 API、自动授权、绕过系统设置，或连续两次环境权限阻断；升级 Board。

## T-04 麦克风采集适配器

- 依赖：T-01、T-02、T-03。
- 负责人：Founding macOS Engineer。
- 输入：ADR-001/003、AudioArtifact、错误表。
- 输出：AVFoundation 麦克风 PCM buffer 流、格式/时间元数据、开始停止与失败映射。
- 验收证据：fake-buffer 单测；实体麦克风首 buffer/帧计数脱敏日志；不可用、开始失败、停止失败注入证据。
- 停止条件：需真实用户录音、额外驱动或未批准权限；停止并升级。

## T-05 系统音频采集适配器

- 依赖：T-01、T-02、T-03。
- 负责人：Founding macOS Engineer。
- 输入：ADR-001/003、SCK 权限与排除本应用要求。
- 输出：ScreenCaptureKit 音频 buffer 流，不落屏幕视频，格式/时间元数据及失败映射。
- 验收证据：公开许可/生成测试音源的首 buffer、帧计数；配置证明不保存视频且排除本应用；不可用、开始/停止失败证据。
- 停止条件：目标 OS 不支持、需要虚拟驱动/发布 entitlement 例外，或连续两次同类 SCK 阻断；升级 Board。

## T-06 会话文件存储与恢复

- 依赖：T-02。
- 负责人：Founding macOS Engineer。
- 输入：ADR-002/003/004、Artifact/Session 契约。
- 输出：会话目录、两路 CAF writer、partial/close/validate/atomic commit、失败 manifest 与 abandoned 扫描。
- 验收证据：临时容器单测；写入/关闭/提交/磁盘不足 failure injection；成功两工件不变量；日志无绝对路径扫描结果。
- 停止条件：需要改变格式、上传、自动删除或目录；更新规格并重审。

## T-07 双路原子编排、状态显示与停止

- 依赖：T-02 至 T-06。
- 负责人：Founding macOS Engineer。
- 输入：两采集适配器、store、完整状态机。
- 输出：双路启动/回滚、recording 双指示与计时、幂等停止、成功/失败呈现。
- 验收证据：两路首 buffer 前不 recording；任一路缺失时另一条被释放；`idle → requestingPermission → recording → stopping → succeeded` 实体证据；运行期中断、停止/写入失败证据。
- 停止条件：双路无法在约定环境连续两次复现；停止并向 CEO/Board 报告环境、日志、候选方案。

## T-08 本地播放与结果呈现

- 依赖：T-06、T-07。
- 负责人：Founding macOS Engineer。
- 输入：两个 final AudioArtifact、ADR-007。
- 输出：逐轨播放、停止播放、文件信息/显示位置、播放错误与重试。
- 验收证据：两轨各自可听/可解码；播放失败注入；失败不改变 session succeeded；partial 被拒绝的测试。
- 停止条件：需要云播放、实时混音、编辑或扩大数据访问；更新规格并重审。

## T-09 实现者验证与复现包

- 依赖：T-01 至 T-08。
- 负责人：Founding macOS Engineer；独立 QA/Code Review 不在本任务授权内。
- 输入：验收追溯矩阵、批准环境。
- 输出：构建与单测报告、正常路径和全部关键失败证据、从零复现步骤、隐私检查、已实现/已验证/待验证分列报告。
- 验收证据：`06-acceptance-traceability.md` 每项填入命令、环境、期望、实际、工件位置；零真实用户录音、零上传证明。
- 停止条件：缺少关键证据、质量门需豁免、或需创建 QA/Code Review Agent；不得自称独立验证，升级 CEO/Board。

## 依赖顺序

`T-01 → T-02 → T-03 → (T-04 || T-05 || T-06) → T-07 → T-08 → T-09`

并行符号仅表达未来依赖可能性，不代表已创建子任务或已授权并行 Agent。
