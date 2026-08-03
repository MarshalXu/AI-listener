# 实施计划 - Gemini 增量与会后结构化纪要及 Keychain 隐私安全

## 一、目标与范围
本阶段（阶段二）致力于为 AI 听记 App 引入 **Gemini 结构化会议纪要** 与 **macOS Keychain 隐私安全防护** 机制。系统需在保障本地录音、ASR 转写和音频存储绝对安全的前提下，通过大模型（Gemini API 或本地 Mock）实现实时增量会议摘要与会后完整纪要生成。

核心需求包括：
1. **Keychain 密钥存储与隐私防护**：
   - Gemini API Key 使用 macOS Security.framework 存入 Keychain，绝不落盘到配置文件、日志或 Git。
   - 提供日志/UI 密钥脱敏 (`maskedKey`) 保护，防止 API Key 泄露。
   - 增加云端 AI 传输提示（告知数据离开本机），要求显式授权；提供“关闭 AI”、“仅会后总结”、“实时增量与会后”三种运行模式，以及 Gemini 云端 / 本地 Mock 模型切换。
2. **Gemini 结构化会议纪要引擎**：
   - 会中订阅 `TranscriptEventBus` finalized 字幕事件，窗口化增量生成议题、阶段摘要、关键观点、决策与待办卡片。
   - 会后基于完整逐字稿生成正式结构化纪要（包含会议概览、核心摘要、章节纪要、关键决策、行动项/负责人/截止时间、未决问题及时间点引用）。
   - 支持多种纪要风格：简洁、标准、详细、周会、访谈、头脑风暴。
3. **SQLite 持久化与数据库 V3 迁移**：
   - 升级 `SessionStore` 至 schema v3，新增 `meeting_minutes` 表及 CRUD 接口。
4. **UI 视图与时间点回听**：
   - 提供 AI 设置面板（`AISettingsView`），包含 Key 管理与隐私授权 Toggle。
   - 提供会议纪要视图（`MeetingMinutesView`），支持点击时间点引用（`startMs`）联动 `PlaybackService` 定位回听。
5. **故障隔离与降级机制**：
   - 当网络中断、Gemini API 报错、Quota 超限或 Key 无效时，静默降级并记录安全诊断码，绝不干扰录音、ASR 转写与音频落盘。

---

## 二、架构设计与模块划划

```
+-----------------------------------------------------------------------------------+
|                                  AIListenerApp                                    |
|   +---------------------+   +-----------------------+   +---------------------+   |
|   |   AISettingsView    |   |  MeetingMinutesView   |   | SessionLibraryView  |   |
|   +----------+----------+   +-----------+-----------+   +----------+----------+   |
+--------------|--------------------------|--------------------------|--------------+
               |                          | (seek atMs)              |
+--------------v--------------------------v--------------------------v--------------+
|                                 AIListenerCore                                    |
|   +---------------------+   +-----------------------+   +---------------------+   |
|   |   KeychainManager   |   | MeetingMinutesService |   |   PlaybackService   |   |
|   +---------------------+   +-----------+-----------+   +---------------------+   |
|   |   PrivacySettings   |               |                                         |
|   +---------------------+               v                                         |
|                             +-----------------------+                             |
|                             |  GeminiClient Protocol |                             |
|                             | (Gemini / Mock Client)|                             |
|                             +-----------+-----------+                             |
|                                         |                                         |
|                                         v                                         |
|                             +-----------------------+                             |
|                             |     SessionStore      |                             |
|                             |      (SQLite v3)      |                             |
|                             +-----------------------+                             |
+-----------------------------------------------------------------------------------+
```

---

## 三、实施步骤与阶段

### Phase 1: KeychainManager & PrivacySettings
- 实现 `KeychainManager`：SecItemAdd / SecItemCopyMatching / SecItemDelete 存取 Gemini API Key，提供 `maskedKey()` 接口。
- 实现 `PrivacySettings` 与 `PrivacySettingsStore`：定义 `AIMode` (`.off`, `.postSessionOnly`, `.incrementalAndPost`)、`AIModel` (`.gemini`, `.localMock`)、`MinutesStyle` (`.concise`, `.standard`, `.detailed`, `.weekly`, `.interview`, `.brainstorm`) 及 `cloudConsentGranted` 检查。

### Phase 2: MeetingMinutes 数据结构与 Gemini Client
- 定义 `MeetingMinutes` 结构体，涵盖 Overview, CoreSummary, Topics, Decisions, ActionItems, UnresolvedQuestions, TimestampReferences。
- 定义 `GeminiClientProtocol`，实现 `GeminiClient`（REST API 调用 `v1beta/models/...:generateContent`）与 `MockGeminiClient`（离线与测试用）。
- 实现 Prompt 构建器与 JSON 解析清洗逻辑。

### Phase 3: SessionStore Schema V3 迁移
- 升级 `SessionStore.schemaVersion` 至 3。
- 增加 `meeting_minutes` 数据表定义与 CRUD 方法：`saveMeetingMinutes` / `fetchMeetingMinutes` / `deleteMeetingMinutes`。
- 更新 `SessionStoreTests` 适配 V3 版本。

### Phase 4: MeetingMinutesService 纪要引擎与故障隔离
- 实现 `MeetingMinutesService`：订阅 `TranscriptEventBus` finalized 事件，支持增量触发与会后完整生成。
- 完善静默降级逻辑：API 失败时不抛出未捕获异常，将状态标记为 `.degraded`，保持主流程稳定。

### Phase 5: UI 视图集成与音频定位回听
- 创建 `AISettingsView`：Key 设置与脱敏预览、隐私授权说明及选项。
- 创建 `MeetingMinutesView`：结构化纪要卡片与列表展示，时间点点击回调触发 `PlaybackService` 跳转播放。
- 集成至 `AIListenerApp` 与 `SessionLibraryView`。

### Phase 6: 单元测试与验证
- 编写 `KeychainManagerTests`、`PrivacySettingsTests`、`GeminiClientTests`、`MeetingMinutesServiceTests` 和 `SessionStoreTests`。
- 运行 `swift test` 确保全部测试通过。

---

## 四、验收标准
1. `swift test` 全绿色通过，新增 Mock 单元测试完整覆盖 Keychain 读写、隐私校验、Gemini 结构化 Prompt 解析与 SessionStore v3 迁移。
2. GEMINI_API_KEY 无任何明文落盘日志或提交仓库风险。
3. API 异常或无网环境下，录音与 ASR 转写 100% 独立不受干扰。
4. Issue 提交审核状态为 `in_review`。
