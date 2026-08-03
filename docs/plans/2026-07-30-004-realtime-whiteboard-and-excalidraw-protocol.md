# 实施计划：实时 AI 画板与 Excalidraw 受限操作协议

## 1. 概述与目标

本计划旨在实现 `AI-listener` 阶段三的核心功能：
1. **Excalidraw/WebView 集成**：通过 AppKit `WKWebView` 嵌入本地 Sidecar/HTML 画板渲染器，实现原生 Swift 层与 Excalidraw 画板之间的双向安全通信 Bridge。
2. **受限结构化 JSON 操作协议**：建立强类型、严格受限的 JSON 协议与 `WhiteboardSanitizer` 安全检测模块，屏蔽模型直接生成任意 HTML/JS 自由代码的风险，所有画板节点（矩形、椭圆、菱形、文本、卡片、流程节点、时间线）均由结构化 Action 渲染。
3. **实时画板服务与状态管理**：订阅 `TranscriptEventBus` 的 `.finalized` 逐字稿事件流，增量转译为画板节点；支持实时更新暂停/恢复 (`isPaused`)、撤销/重做 (`undo`/`redo`) 栈及人工手动拖拽编辑。
4. **数据库 V4 持久化**：升级 `SessionStore` 至 Schema V4，新增 `whiteboard_snapshots` 数据表，支持会议结束自动落盘以及重新打开历史会话加载和编辑画板。
5. **故障隔离**：画板 Agent、WebView 崩溃或解析异常降级记录，绝对不影响底层音频采集、ASR 转写与逐字稿落盘。

---

## 2. 详细设计

### 2.1 受限结构化 JSON 操作协议 (`WhiteboardProtocol.swift` & `WhiteboardSanitizer.swift`)

#### 核心节点与动作定义
- **受限节点类型 (`WhiteboardNodeType`)**：
  - `rectangle`, `ellipse`, `diamond`, `text`, `card`, `flowStep`, `timelineEvent`
- **受限动作类型 (`WhiteboardActionKind`)**：
  - `addNode`: 创建新节点（含坐标、宽高、文本内容、颜色等）
  - `updateNode`: 更新已有节点属性
  - `deleteNode`: 删除指定节点
  - `connectNodes`: 创建节点间的连接线或箭头
  - `addFlowStep`: 快速创建流程步骤卡片
  - `addTimelineEvent`: 快速创建时间线节点
  - `addCard`: 快速创建主题待办卡片
  - `clear`: 清空画布
  - `loadSnapshot`: 全量恢复画板快照
- **安全过滤模块 (`WhiteboardSanitizer`)**：
  - 拦截并净化任何包含 `<script>`, `javascript:`, `onload=`, `onerror=` 等恶意注入代码。
  - 对文本与卡片内容进行转义或剥离非法 HTML 标签，保证渲染安全性。

---

### 2.2 Excalidraw / WebView 安全通信 Bridge (`WhiteboardWebView.swift`)

#### 双向 Message Handler 机制
- **Swift -> WebView (JavaScript)**：
  - 通过 `WKWebView.evaluateJavaScript("window.renderWhiteboardAction(...)")` 向画板推送受限动作 JSON。
  - 支持 `loadSnapshot(...)` 加载整体 Excalidraw 画布 JSON。
- **WebView (JavaScript) -> Swift**：
  - 注册 `WKScriptMessageHandler` 名称 `whiteboardBridge`。
  - 捕获用户在 Web 画布上的拖拽、修改动作 (`userEdited`) 并回调给 Swift 层的 `WhiteboardService`，同步更新数据模型。

---

### 2.3 实时画板服务与状态管理 (`WhiteboardService.swift` & `WhiteboardAgent.swift`)

#### 订阅事件与增量生成
- `WhiteboardService` 订阅 `TranscriptEventBus` 的 `.finalized` 事件。
- 经过 `WhiteboardAgent`（支持本地启发式规则或 AI 模型）解析 finalized 逐字稿，提取议题关键词、流程与卡片，生成对应的 `WhiteboardAction`。
- **状态控制**：
  - `isPaused`: 暂停状态下丢弃/缓存新生成的增量动作，画板不被刷新。
  - `undoStack` / `redoStack`: 管理受限 Action 的历史轨迹，支持撤销与重做。

#### 故障隔离
- 若 WebView 加载失败或 Agent 生成非法 JSON，`WhiteboardService` 捕获异常并设置 `lastDiagnosticCode`，抛出警告，不终止主线程与录音任务。

---

### 2.4 数据库 Schema V4 升级与持久化 (`SessionStore.swift`)

#### 数据库 Migration V4
- `PRAGMA user_version` 提升为 `4`。
- 新增 `whiteboard_snapshots` 表：
  ```sql
  CREATE TABLE whiteboard_snapshots (
    contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
    snapshot_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    elements_json TEXT NOT NULL,
    app_state_json TEXT NOT NULL,
    created_at_utc INTEGER NOT NULL,
    updated_at_utc INTEGER NOT NULL
  );
  CREATE INDEX idx_whiteboard_snapshots_session ON whiteboard_snapshots(session_id);
  ```
- 提供 `saveWhiteboardSnapshot(_ snapshot: WhiteboardSnapshot)` 与 `fetchWhiteboardSnapshot(sessionId: String)` 方法。

---

### 2.5 UI 交互视图 (`WhiteboardView.swift` & `SessionLibraryView.swift`)

- **实时录音界面**：
  - 添加“AI 画板”可伸缩/切换视图，包含 暂停/恢复、撤销/重做、清空 按钮。
- **历史记录详情界面**：
  - 在 `SessionLibraryView` 详情页新增 “AI 画板” 标签页，载入会议结束时的画板快照，并允许用户离线编辑。

---

## 3. 测试与验证计划

1. `WhiteboardProtocolTests`：验证受限 JSON 协议解析、生成及 `WhiteboardSanitizer` 安全代码过滤拦截。
2. `SessionStoreV4Tests`：验证 Schema V4 迁移、快照保存、查询及 `ON DELETE CASCADE` 外键关联。
3. `WhiteboardServiceTests`：验证 `.finalized` 事件处理、暂停/恢复、撤销/重做栈及 Agent 异常下的降级故障隔离。
4. 全量编译与测试：执行 `swift test` 确保 100% 测试通过。

---

## 4. 交付文件列表

1. `docs/plans/2026-07-30-004-realtime-whiteboard-and-excalidraw-protocol.md`
2. `Sources/AIListenerCore/WhiteboardProtocol.swift`
3. `Sources/AIListenerCore/WhiteboardService.swift`
4. `Sources/AIListenerCore/WhiteboardAgent.swift`
5. `Sources/AIListenerCore/SessionStore.swift` (V4 升级)
6. `Sources/AIListenerApp/WhiteboardWebView.swift`
7. `Sources/AIListenerApp/WhiteboardView.swift`
8. `Sources/AIListenerApp/SessionLibraryView.swift` (集成画板标签页)
9. `Tests/AIListenerCoreTests/WhiteboardProtocolTests.swift`
10. `Tests/AIListenerCoreTests/SessionStoreV4Tests.swift`
11. `Tests/AIListenerCoreTests/WhiteboardServiceTests.swift`
