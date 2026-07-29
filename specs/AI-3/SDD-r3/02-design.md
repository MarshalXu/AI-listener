# 02 Design

## 组件边界

- `D-01 App/UI (SwiftUI)`：呈现列表、详情、录音状态、字幕和播放器；只发 intent，不直接操作设备/SQLite。
- `D-02 SessionCoordinator`：唯一状态机 owner，生成 `sessionId`，编排但不传递正文到日志。
- `D-03 MicrophoneCapture (AVFoundation)`：只产出带单调时间的 PCM frame；独占麦克风、写入器与 ASR fan-out 互不反压。
- `D-04 AudioFileWriter`：连续消费 frame，先写同卷临时文件，停止后 flush/close/checksum/atomic rename；ASR 消费慢不得阻塞它。
- `D-05 ASRAdapter`：版本化输入/事件接口；VAD/切块、模型加载与识别隔离；失败只使 transcript degraded。
- `D-06 SessionRepository`：SQLite 唯一写入口；事务化 Session、AudioAsset、finalized segment、RecordingEvent、Error。
- `D-07 PlaybackService`：只读取 committed AudioAsset；由 finalized `startMs` seek，报告实际位置。
- `D-08 ModelStore`：模型 manifest、许可证、校验和、兼容性；不接触录音或数据库正文。
- `D-09 Telemetry`：仅本地结构化事件和计数，字段白名单；无远程上报。

依赖方向为 UI → Coordinator → ports；AVFoundation、SQLite、ASR engine、文件系统是 adapters。录音流以有界队列分别送 Writer 和 ASR；Writer 为高优先级不可丢，ASR 队列可按契约记录 gap/degraded，禁止拖垮录音。

## 状态机

`idle → requestingPermission → preparing → recording → stopping → finalizing → ready`

异常分支：

- 权限 `denied/restricted`：`requestingPermission → permissionBlocked → idle`。
- 准备期设备/落盘失败：`preparing → failed`，不得创建伪 ready 记录。
- ASR/模型失败：`recording` 不变，同时 transcript 子状态 `active → degraded|unavailable`。
- 路由/设备中断：`recording → interrupted → stopping`；保存已录帧，记录终止原因。
- finalizing 的 DB/file 失败：`recoveryRequired`；保留临时资产供下次启动恢复。

非法 transition 必须拒绝并记录不含内容的 `state.transition_rejected`。停止必须幂等；重复 stop 返回同一 finalization 结果。

## 时间、字幕和定位

- `D-10` 捕获开始记录单调 epoch；所有媒体时间使用从首个已写 frame 起的 Int64 毫秒，禁止用墙钟对齐。
- partial 只存在内存/UI，可按 `C-03` 替换或撤回；finalized 经事务入库后不可原位修改。
- finalized segment 对应 `[startMs,endMs)`；点击以 `startMs` 请求 seek。`M-08` 以播放器实际位置与目标差的绝对值验收，不拿 UI 动画时间作证据。

## 生命周期、原子性与恢复

- `D-11` 创建：SQLite 事务插入 `recording` Session 后，创建同卷 `<sessionId>.audio.tmp`。开始写首帧前，以 create-exclusive 方式创建并 `fsync` recovery manifest，记录 sessionId、temporary/stable 相对路径、期望阶段 `temporary` 和版本；manifest 本身采用 temp-write → fsync → atomic rename → parent-directory fsync。
- 停止协议固定为：① writer flush，文件 `fsync`，close，计算 size/duration/hash；② 原子更新 manifest 为 `stablePendingCommit` 并 fsync；③ 同卷 atomic rename temporary → stable，随后 parent-directory fsync；④ SQLite `BEGIN IMMEDIATE`，登记 committed AudioAsset/finalized segments，将 Session 标 `ready`，提交并确认成功；⑤ 原子更新 manifest 为 `committed` 并 fsync，最后删除 manifest 并 parent-directory fsync。步骤④成功前禁止展示 ready。
- 启动恢复以 SQLite + manifest + 文件实际存在性联合判定，操作仅限应用自有目录且全部幂等：

| 崩溃观察点 | 确定性处理 |
|---|---|
| 无 manifest、Session recording、无文件 | Session → failed/interrupted；不得造 ready |
| manifest `temporary`，仅 tmp 存在且可读非空 | 保持/转为 recoveryRequired；关闭后按停止协议继续；不可读或空则 quarantine |
| manifest `stablePendingCommit`，tmp 存在、stable 不存在 | 验证后执行 rename + dir fsync，再重放 DB commit |
| manifest `stablePendingCommit`，stable 存在、DB 未引用 | 校验 size/hash/可读性；匹配则重放幂等 DB commit，不匹配则 quarantine |
| stable 与 committed DB 均存在且匹配，manifest 未清 | Session 保持 ready/recovered；把 manifest 标 committed 后清理 |
| DB 宣称 committed/ready，但 stable 缺失或 hash 不符 | 撤销假 ready，Session → recoveryRequired；缺失报错，错误文件 quarantine，绝不误删别的文件 |
| tmp 与 stable 同时存在 | 以 manifest 期望路径和已提交 hash 决胜；无法唯一证明来源时两者均不删，隔离冲突并 recoveryRequired |
| 无 Session/manifest 的孤儿 tmp/stable | 不自动删除；移入 app-owned quarantine 并生成安全诊断记录，等待显式清理 |

`temporary`、`stable` 是文件阶段；`committed` 是 SQLite 已提交且 hash 匹配；`quarantined` 是隔离资产；`recoveryRequired` 是 Session 状态。任何恢复都不得仅凭文件名推断所有权或把逐字稿缺失当成音频失败。
- `D-12` 删除：数据库先标 `deleting`，删除音频后事务删除/墓碑元数据；文件失败保留 `deleting` 并允许重试。崩溃后继续幂等清理。
- 保留策略：默认不自动过期；仅用户显式逐条删除。不得读取目标目录之外的用户录音。

## 失败隔离与可观测性

错误域为 Permission、Capture、FileIO、Database、Model、ASR、Playback、Recovery。事件含 contractVersion、eventId、sessionId、monotonicMs、category/code、state、recoverable、correlationId；不得含 transcript/audio bytes。保留本地滚动日志的大小/期限在实现前由 Board 决定，默认诊断 UI 只显示错误码与安全说明。

恢复操作限定为：重试权限检查、重试模型加载、继续无字幕录音、重试 finalization、播放已恢复音频、删除记录。任何上传或后台云恢复禁止。

## 关键不变量

1. Audio writer 不依赖 ASR ready/success。
2. SQLite 是 Session/逐字稿真相源；文件系统只是真实音频资产及恢复线索。
3. `ready` 必须引用存在、可读、校验通过的 committed AudioAsset。
4. finalized 单调有序且不可覆盖；partial 不进真相源。
5. 只由显式用户动作触发麦克风请求；永不请求 Screen Recording。
