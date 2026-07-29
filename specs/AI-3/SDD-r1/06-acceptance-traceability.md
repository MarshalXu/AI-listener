# 06 验收矩阵与追溯

所有证据必须使用授权的公开/合成测试音频，不得访问真实用户录音。规格通过不等于产品已验证。

| ID | 场景与前置 | 可观察预期 | 必需证据 | 追溯 |
|---|---|---|---|---|
| `M-01` | 模型已校验、麦克风已授权；录一段固定中文并停止 | 状态到 ready；有 committed CAF、finalized 字幕；重开可播放并点击定位 | 状态事件序列、DB 查询、文件 hash/可读时长、字幕事件回放、重启后截图/seek 测量 | P-01…04; D-01…11; C-01…06; A-01…05; T-02…07 |
| `M-02` | fresh/denied/restricted 权限 | 仅由点击触发 Microphone；拒绝后不开始、不造空记录、可开设置；无 Screen Recording | TCC 三态录像/截图、事件、数据库无伪 Session、静态权限清单 | P-01/P-05; D-02/D-03; A-06; T-03/T-07 |
| `M-03` | 模型缺失、hash 错或加载失败 | 明示 transcript unavailable/degraded；录音、停止、保存、播放仍成功 | Model/Error code、音频 hash/时长、Session transcriptState、无网络捕获 | P-03/P-05; D-04/D-05/D-08; C-05/C-06; A-01/A-07; T-01/T-04/T-05 |
| `M-04` | 录音中模拟设备/route 中断 | 进入 interrupted→stopping；保存中断前音频；终止原因可见；不崩溃 | 状态/事件、可播放时长、DB terminationReason、重复 stop 幂等 | D-02…04/D-11; C-01/C-04/C-05; T-03/T-04 |
| `M-05` | 注入磁盘满、write/rename/DB commit 失败 | 不标 ready；保留可诊断/恢复资产；重试幂等；不覆盖外部文件 | 故障注入记录、目录清单、DB/recovery manifest 前后对比、重启结果 | P-03; D-04/D-06/D-11/D-12; A-03/A-04; T-04 |
| `M-06` | 在 recording/finalizing/rename 后 DB 前分别强退并重启 | 扫描只处理应用目录；可读音频 recovered；坏文件 quarantined；逐字稿缺失不否定音频 | 三个崩溃点夹具、恢复事件、hash/播放、DB state | D-11; C-01/C-02/C-04/C-05; A-04; T-02/T-04 |
| `M-07` | ASR 慢、队列满、进程/adapter 失败 | writer 无丢帧并成功 commit；ASR 发 gap/degraded；已有 finalized 保留 | frame/文件 duration 对账、队列指标、错误事件、DB finalized 查询 | D-03…05; C-03/C-06; A-05; T-05 |
| `M-08` | 含已知声学标记与 finalized startMs 的夹具；重开后点击 | 实际播放位置与 startMs 误差不超过批准阈值，至少覆盖开头/中间/结尾 | 目标/实际毫秒表、设备/OS、重复次数、播放器日志 | P-04; D-07/D-10; C-02/C-03; T-06 |

## 规格静态质量门

- 六类工件与 README 存在，所有 `P/D/C/A/T/M` 引用可解析。
- 搜索不存在 Swift、测试代码、工程脚手架或原型；本规格中的 “Tasks” 只定义未来增量，Paperclip 未创建实现子任务。
- 搜索无 Screen Recording 请求、系统音频实现范围或云 ASR 依赖；出现这些词只能在非目标/禁止/边界说明。
- AI-2 文件内容、mtime、任务描述和状态不因 AI-3 改变。
- 最新完整修订必须绑定 AI-3 的 Board `request_confirmation`；接受前实现状态固定为未开始。

## 风险与升级

模型/权重许可证、中文性能阈值、模型托管持续成本、备份/删除语义尚需 Board 在实施前定案。任何契约 major 变化或非目标进入范围属于实质规格变更：更新全包修订号、重跑静态追溯，并创建新的 confirmation；旧批准失效。
