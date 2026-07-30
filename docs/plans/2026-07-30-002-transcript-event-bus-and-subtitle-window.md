# 实施计划：共享 Transcript Event Bus 与独立透明字幕浮窗

## 1. 概述与目标

本计划旨在实现 `AI-listener` 阶段一的核心功能：
1. **共享 Transcript Event Bus (`TranscriptEventBus`)**：构建高内聚、低耦合、线程安全的事件总线，负责向主界面、字幕浮窗及后续 AI 模块（会议纪要、画板等）分发 `partial` 与 `finalized` 逐字稿事件。
2. **独立透明字幕浮窗 (`SubtitlePanel` / `SubtitleView`)**：基于 macOS `NSPanel` 与 SwiftUI 实现置顶、透明、可拖拽的实时字幕浮窗，支持字号/颜色/透明度/背景模糊/显示行数/显示器选择，且绝对不触发 Screen Recording 权限申请。
3. **故障隔离保障**：字幕浮窗的关闭、隐藏或崩溃完全不影响底层麦克风录音、sherpa-onnx ASR 引擎及 SQLite 数据持久化。

---

## 2. 详细设计

### 2.1 Transcript Event Bus (`AIListenerCore`)

#### 核心数据类型与接口
- `TranscriptBusEvent`:
  - `.partial(events: [ASRTranscriptEvent])`
  - `.finalized(event: ASRTranscriptEvent)`
  - `.reset(sessionId: String)`
- `TranscriptEventBus`:
  - `publish(_ event: TranscriptBusEvent)` / `publishPartials(...)` / `publishFinalized(...)`
  - `subscribe(onEvent: @escaping @Sendable (TranscriptBusEvent) -> Void) -> TranscriptBusSubscription`
  - `stream() -> AsyncStream<TranscriptBusEvent>`
- 异步隔离机制：
  - 发布事件时，按订阅者非阻塞（Task 异步调度）分发。
  - 单个订阅者处理变慢或出现异常，不会阻塞主 ASR 管道及其他订阅者。

#### 与 `RecordingSessionPipeline` 整合
- `RecordingSessionPipeline` 新增 `eventBus: TranscriptEventBus?` 参数支持（或在 `partialSink`/`finalizedSink` 中统一发布至 `TranscriptEventBus`）。
- 主应用 `CaptureViewModel` 创建单例/会话级 `TranscriptEventBus`，并将其注入 `RecordingSessionPipeline` 与字幕浮窗 ViewModel。

---

### 2.2 独立透明字幕浮窗 (`AIListenerApp`)

#### 窗口实现 (`SubtitlePanel`)
- 基于 `NSPanel` 的浮窗设计：
  - `styleMask`: `[.borderless, .nonactivatingPanel, .resizable]`
  - `level`: `.floating`（确保始终置顶）
  - `isOpaque`: `false`
  - `backgroundColor`: `.clear`
  - `hasShadow`: `true`
  - `isMovableByWindowBackground`: `true`（直接拖拽背景移动位置）
  - `collectionBehavior`: `[.canJoinAllSpaces, .fullScreenAuxiliary]`（支持跨 Desktop Space 和全屏应用上层悬浮）

#### 字幕视图与设置 (`SubtitleViewModel` / `SubtitleSettings` / `SubtitleView`)
- **可配置选项 (`SubtitleSettings`)**：
  - `opacity`: 浮窗/背景透明度（0.1 - 1.0，默认 0.85）
  - `fontSize`: 字号大小（12pt - 36pt，默认 18pt）
  - `textColor`: 字体颜色（白色、黄色、青色、绿色、黑色等，默认白色）
  - `backgroundMaterialEnabled`: 是否开启毛玻璃背景（默认开启）
  - `maxLines`: 最多显示行数（1 - 10 行，默认 3 行）
  - `selectedDisplayId`: 目标显示器 ID（支持多显示器选择与定位）
- **Screen Recording (屏幕录制) 权限防护**：
  - 代码中绝对不引用 `ScreenCaptureKit` / `CGDisplayStream` / `CGWindowListCreateImage`。
  - 仅使用 AppKit 标准 `NSScreen.screens` 获取显示器分辨率与坐标轴，定位浮窗位置。

#### 主界面交互控制
- `ContentView` 标题栏/操作区增加“字幕浮窗”开关按钮（Toggle Subtitle Window）与设置面板按钮。
- 用户可随时隐藏/显示浮窗，关闭浮窗不会停止录音。

---

## 3. 故障隔离与测试计划

1. **单元测试 (`TranscriptEventBusTests`)**：
   - 验证多订阅者并发发布/订阅。
   - 验证订阅者取消订阅 (`cancel`) 后不再接收事件。
   - 验证慢速/阻塞订阅者不会阻塞事件发布者。
   - 验证 `AsyncStream` 接口正常工作。
2. **集成测试 (`RecordingSessionPipelineBusTests`)**：
   - 验证 `RecordingSessionPipeline` 产生的 ASR 事件正确分发至 `TranscriptEventBus`。
   - 验证 ASR 异常或浮窗销毁时，音频持久化与 SQLite 数据存储不受任何影响。
3. **编译与自动化验证**：
   - 执行 `swift test` 确保全量自动化测试通过。

---

## 4. 交付产物

1. `Sources/AIListenerCore/TranscriptEventBus.swift`
2. `Sources/AIListenerApp/SubtitlePanel.swift`
3. `Sources/AIListenerApp/SubtitleViewModel.swift`
4. `Sources/AIListenerApp/SubtitleView.swift`
5. `Sources/AIListenerApp/AIListenerApp.swift` (整合浮窗与事件总线)
6. `Tests/AIListenerCoreTests/TranscriptEventBusTests.swift`
7. `docs/plans/2026-07-30-002-transcript-event-bus-and-subtitle-window.md` (本计划文件)
