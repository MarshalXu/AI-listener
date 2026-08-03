# AI 听记 (AI Listener) macOS App 项目现状与 UI/UX 设计接交介绍文档

**文档版本**：v1.0.0

**交付责任人**：AI 听记项目总指挥 (Product Architect & Squad Leader)

**目标受众**：UI/UX 专业设计团队、项目 Owner 及研发团队
**仓库地址**：`git@github.com:MarshalXu/AI-listener.git` (分支: `main`)

---

## 一、 项目背景与产品定位 (Project Background & Vision)

`AI 听记 (AI Listener)` 是一款专为 macOS 平台打造的**隐私优先、小而美、可稳定交付的“实时会议理解与表达助手”**。

### 1.1 核心主线与设计哲学
本项目**保留并强化现有本地基础设施**，绝不推倒重写：
- **本地录音与高质量 ASR**：基于 macOS AVFoundation 麦克风采集与本地 `sherpa-onnx` (Zipformer 离线模型) 实时转写；
- **可靠落盘与崩溃恢复**：基于原子 CAF 音频写入、SQLite 会话存储与轻量级崩溃恢复重构机制；
- **音频逐字稿回听**：基于精确时间戳的音频-文本同步 Seek 回听能力。

### 1.2 本轮新增的三条核心产品能力
在本轮迭代中，我们在底层事件总线（`TranscriptEventBus`）的基础上，扩展了三条相互协作但**故障隔离**的核心能力：
1. **实时字幕浮窗 (Subtitle Panel)**：显示在桌面置顶的独立透明毛玻璃悬浮窗中，支持透明度、字号、颜色、背景模糊、行数与多显示器无缝切换，**绝不要求 Screen Recording 权限**。
2. **AI 会议纪要 (AI Meeting Minutes)**：通过可配置的云端/本地大模型对逐字稿进行会中增量生成与会后完整总结，支持多种纪要风格（简洁、标准、详细、周会、访谈、头脑风暴），并提供原文时间戳快速跳播。
3. **实时 AI 画板 (Real-time AI Canvas)**：基于本地嵌入的 Excalidraw Sidecar / WebView，由画板 Agent 根据稳定转写片段增量生成/更新主题、节点、关系与待办卡片，支持用户暂停、撤销、重做与随会话保存。

---

## 二、 仓库与技术架构现状审查 (Architecture Audit)

目前项目基于 **macOS 14.0+ (Swift 6 / SwiftUI / AppKit)** 构建，采用 **Swift Package Manager (SPM)** 进行模块化管理。系统全套 82 项单元与集成测试均处于 **100% GREEN 通状态**。

### 2.1 技术栈概览
- **开发语言与 UI 框架**：Swift 6, SwiftUI, AppKit (用于高性能悬浮窗 `NSPanel` 与显示器管理 `NSScreen`)
- **本地 ASR 引擎**：`sherpa-onnx`（通过 C-API Bridging `CSherpaShim` 嵌入，集成 `zh-14M` 离线模型）
- **本地数据库**：SQLite3（通过 `CSQLite` 原生封装，运行 Schema V4 迁移与原子事务管理）
- **AI 大模型集成**：Google Gemini API (`GeminiClient`)，支持云端与本地 Mock 双模式
- **密钥与配置存储**：macOS Keychain (`KeychainManager`)，保证 API Key 零落盘、零日志泄露
- **富文本/画板容器**：WebKit (`WKWebView`) + Excalidraw JSON 协议控制

### 2.2 代码库模块结构 (Codebase Structure)

```text
AIListener/
├── Package.swift                             # SPM 配置文件 (macOS 14+)
├── Sources/
│   ├── AIListenerCore/                       # 核心业务逻辑与数据驱动层
│   │   ├── MicrophoneCapture.swift           # AVFoundation 麦克风音频采集
│   │   ├── CaptureCoordinator.swift          # 采集状态与权限协调器
│   │   ├── SherpaStreamingASREngine.swift    # sherpa-onnx 实时语音识别引擎
│   │   ├── RecordingSessionPipeline.swift    # 录音与 ASR 主管线
│   │   ├── TranscriptEventBus.swift          # 高并发 FIFO 逐字稿事件总线 (Pub/Sub)
│   │   ├── SessionStore.swift                # SQLite 数据库持久化 (Schema V4)
│   │   ├── AtomicAudioAssetWriter.swift      # 原子 CAF 音频落盘与校验
│   │   ├── AudioRecoveryReconciler.swift     # 崩溃异常恢复协调器
│   │   ├── PlaybackService.swift             # 时间戳精确 Seek 播放服务
│   │   ├── MeetingMinutesService.swift       # 会中/会后 AI 纪要服务
│   │   ├── GeminiClient.swift                # Gemini API 请求与结构化解析
│   │   ├── WhiteboardService.swift           # AI 画板状态与 Undo/Redo 队列
│   │   ├── WhiteboardAgent.swift             # 画板 Action 增量生成 Agent
│   │   ├── KeychainManager.swift             # macOS Keychain 密钥存储
│   │   └── PrivacySettings.swift             # 隐私政策与 AI 模式配置
│   └── AIListenerApp/                        # GUI 界面与 AppKit 交互层
│       ├── AIListenerApp.swift               # App 入口与 CaptureViewModel
│       ├── ContentView.swift                 # 录音主控制台与实时面板
│       ├── SessionLibraryView.swift          # 历史会话库与三页签回听
│       ├── SubtitlePanel.swift               # AppKit NSPanel 悬浮窗口
│       ├── SubtitleView.swift                # 字幕渲染与浮窗设置 Popover
│       ├── SubtitleViewModel.swift           # 字幕浮窗独立状态与 display 绑定
│       ├── MeetingMinutesView.swift          # 结构化会议纪要渲染与时间戳跳转
│       ├── WhiteboardView.swift              # 画板工具栏与容器包装
│       ├── WhiteboardWebView.swift           # Excalidraw WebKit 桥接
│       └── AISettingsView.swift              # Key 配置与隐私设置弹窗
└── Tests/
    └── AIListenerCoreTests/                  # 82 项单元与端到端集成测试 (全量通过)
```

---

## 三、 现有 UI/UX 体验现状与设计痛点 (Current UI/UX Audit & Pain Points)

当前系统的界面主要用于验证底层的并发事件流、ASR 离线识别以及崩溃恢复机制，**UI 均采用 SwiftUI 基础组件 (GroupBox, List, Picker, Button) 原生堆叠**，缺乏专业的 macOS 设计质感与人机交互细化。

### 核心 UI/UX 六大设计痛点 (需专业设计团队优化)

| 模块 | 当前现状 | 专业 UI/UX 设计接防与重构需求 |
| :--- | :--- | :--- |
| **1. 录音主控制台 (Dashboard)** | 垂直平铺状态灯、按钮、纪要卡片、画板与逐字稿，显得沉重且挤压，缺乏主次排版 | **网格化/卡片化响应式布局**；引入动态音频波形动画；提升“开始录音”按钮的仪式感与实时状态提示 |
| **2. 透明字幕浮窗 (Subtitle Panel)** | 基础暗色卡片，边框与阴影硬朗，缺少桌面悬浮的灵动感 | **Glassmorphic 极简毛玻璃设计**；平滑的多行字幕淡入淡出动画；隐藏式拖动手柄与优雅的 Mini 悬浮设置控制条 |
| **3. AI 会议纪要面板 (Minutes Reader)** | 标准 GroupBox 列表堆叠，信息层级平铺 | **飞书/钉钉 AI 听记级别的排版**；卡片化议题展示、待办事项高亮标签（含负责人 Avatar 与截止日徽章）、跳播按钮高亮视觉 |
| **4. AI 画板 (Whiteboard)** | WebView 容器与宿主 App 工具栏切割明显，风格不统一 | **无缝内嵌 Excalidraw 画布**；原生风格的画板浮动工具栏（暂停、撤销、重做、全屏放大）与状态加载微动画 |
| **5. 历史库与播放控制 (Session Library)** | 侧边栏仅展示简单文本预览，底部 Seek 回听指示简陋 | **现代 macOS 侧边栏 (Sidebar Style)**；增加时间/关键词检索；底部集成带有音频波形轨与播放/倍速控制的 Player Bar |
| **6. 隐私与 Key 配置 (AISettings)** | 纯表单配置，用户对“数据是否离开本机”感知不够直观 | **直观的隐私安全示意图**（本地 ASR vs 云端 LLM 数据流向图）；Key 状态以安全锁/Key Icon 视觉呈现 |

---

## 四、 给 UI/UX 设计团队的接防指南 (Design Handoff Specifications)

我们希望专业设计团队能够基于 **macOS 14 / 15 (Sonoma / Sequoia) 原生 Human Interface Guidelines (HIG)**，为 `AI 听记` 打造极具科技感、优雅且干净的设计规范。

### 4.1 设计交付物要求 (Deliverables Checklist)
1. **Figma 完整设计稿与交互原型**：包含 Dark Mode（暗色模式为主）与 Light Mode 适配。
2. ** Design System / Component Library**：
   - 语义化调色盘 (Color Tokens: Vibrancy Backgrounds, Material Accents)
   - 字体层级定义 (Typography: SF Pro / Monospaced Digits for Timestamps)
   - 图标与状态徽章库 (SF Symbols 5 风格统一步调)
   - 原生 AppKit/SwiftUI 风格按钮、卡片、Popover、Modal 规范

### 4.2 核心界面设计规范细节

#### ① 录音主控制台 (Dashboard)
- **录音状态区**：具备呼吸灯效果的波形指示器（Idle / Recording / Interrupted / Stopping）。
- **实时逐字稿区域**：Finalized（确定文本，高对比度）与 Partial（中间预测文本，浅色淡入与尾部省略号动画）的视效区分。
- **快捷浮窗联动**：顶栏放置一键开启/隐藏字幕浮窗按钮。

#### ② 独立透明字幕浮窗 (Subtitle Floating Window)
- **外观**：Rounded Rectangle (Corner Radius 12-16pt)，采用 `.ultraThinMaterial` 毛玻璃，边缘 1px 优雅微光 Stroking。
- **交互**：鼠标 Hover 时浮现顶部控制微条（拖动手柄、设置齿轮、关闭按钮），移开后自动隐匿。
- **文字渲染**：支持多行文字描边/投影，确保在桌面复杂背景下文字依然清晰可读。

#### ③ 结构化会议纪要 (Meeting Minutes Reader)
- **信息架构**：
  - **Header**：会议标题、生成风格 Badge（标准/周会/头脑风暴）、模式 Indicator。
  - **Overview 卡片**：参会人总结、核心概要。
  - **Key Decision 决策卡**：绿/蓝色徽章突出决策结论。
  - **Action Items 待办卡**：复选框形式，带负责人、截止时间标签与右侧**一键播放原文**按钮。
  - **Timestamp Reference 原文引用**：显示引语与带波形 Icon 的快播跳戳。

#### ④ 实时 AI 画板 (Excalidraw Canvas Container)
- **容器形态**：支持在主界面下方内嵌，也可一键放大至全屏或独立窗口。
- **悬浮控制面板**：玻璃质感的悬浮 Pill 悬浮条，包含“暂停更新/恢复”、“撤销”、“重做”、“清空”与诊断状态提醒。

#### ⑤ 历史记录与波形播放控制台 (Session Library & Waveform Player)
- **左侧边栏**：支持时间分组（今天、本周、更早）与关键词搜索框。
- **右侧详情页**：顶部 Segmented Control 切换【逐字稿 | 会议纪要 | AI 画板】。
- **底部 Player Bar**：悬浮式音频播放条，显示总时长、实时进度波形图、播放/暂停、15s 快进快退与时间定位。

#### ⑥ AI 与 Keychain 隐私安全配置 (Privacy & Security Modal)
- **Keychain 状态**：使用加密锁/Key 视觉元素呈现，说明 API Key 安全存入系统 Keychain。
- **云端/本地模式**：清晰切换“仅本地 Mock (数据不出本机)”与“云端 Gemini (需传输逐字稿)”，附带明确的 Toggle 开关与隐私告知。

---

## 五、 项目迭代路线图与 Squad 结构 (Roadmap & Squad Architecture)

根据 **AI 听记项目总指挥** 的规划，本轮迭代严格控制研发边界，拒绝冗余与空转，建立最小化可交付项目组。

### 5.1 最小项目组 (Minimal Squad Structure)

```text
┌─────────────────────────────────────────────────────────────────┐
│              AI 听记项目总指挥 (Product Architect)                │
│       - 负责 MVP 边界划分、组件契约、整体架构与质量验收              │
└─────────────────────────────────────────────────────────────────┘
                               │
       ┌───────────────────────┼───────────────────────┐
       ▼                       ▼                       ▼
┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│  UI/UX 设计   │       │ macOS 客户端 │       │ AI 与数据协议 │
│   (外包/专业) │       │  (Client)    │       │  (Engine)    │
│ - Figma 系统 │       │ - SwiftUI重构│       │ - Prompt 优化│
│ - 组件规范   │       │ - 浮窗与播放器│       │ - Keychain    │
│ - 视觉交付   │       │ - 动效与交互 │       │ - JSON 契约  │
└──────────────┘       └──────────────┘       └──────────────┘
```

### 5.2 阶段路线图与依赖顺序 (Issue Roadmap)

- **Stage 1: 设计与规范定义 (当前阶段)**
  - [x] 代码库现状与技术契约只读审查
  - [x] 输出完整项目现状与 UI/UX 设计接交文档
  - [ ] UI/UX 团队进行 Figma 视觉设计与组件库建立

- **Stage 2: 客户端基础 UI 重构与组件化**
  - [ ] 搭建统一的 macOS Design System (Color Tokens, Dark Mode, Typography)
  - [ ] 重构主控制台 `ContentView` 响应式布局与录音状态动效

- **Stage 3: 三大核心能力视觉与交互升阶**
  - [ ] 重构 `SubtitlePanel` / `SubtitleView` 毛玻璃沉浸浮窗与 Mini 控制条
  - [ ] 重构 `MeetingMinutesView` 结构化纪要卡片与时间戳跳转交互
  - [ ] 重构 `WhiteboardView` 容器与 Excalidraw 悬浮控制条
  - [ ] 重构 `SessionLibraryView` 侧边栏与底部音频波形播放器条

- **Stage 4: 系统联调、性能考核与验收**
  - [ ] 视觉还原度比对与 UI/UX 评审验收
  - [ ] 性能与稳定性门槛考核（CPU、内存、无卡顿 Seek）
  - [ ] 交付至 `in_review` 阶段等待人工最终批准

---

## 六、 质量门槛与风险控制 (Quality Gates & Risk Ownership)

### 6.1 质量门槛 (Quality Gates)
1. **自动化测试 100% 通过**：改动后必须保持现有的 82/82 单元/端到端测试全部 GREEN。
2. **浮窗性能门槛**：字幕浮窗开启实时渲染时，额外 CPU 占用不得超过 3%，且**零 Screen Recording 权限申请**。
3. **音频 Seek 延时**：回听跳转 Seek 触发至音频播放的 P95 延迟小于 50ms。
4. **隐私与 Key 零泄露**：Keychain 操作与设置切换须有 100% 单元测试覆盖，日志中绝对不可出现明文 API Key。

### 6.2 风险矩阵与负责人 (Risk Matrix)

| 风险点 | 风险描述 | 负责人 | 防控与降级策略 |
| :--- | :--- | :--- | :--- |
| **视觉还原度风险** | SwiftUI 实现与 Figma 设计稿有偏差 | UI/UX Designer + Client Engineer | Stage 3 增加视觉比对 Checkpoint；采用统一 Color Tokens |
| **浮窗多屏与渲染兼容性** | 外部显示器插拔导致浮窗位置丢失 | macOS Client Engineer | 依靠 `DisplayHelper` 自动回退至主屏幕，无感恢复 |
| **大模型响应延迟与网络异常** | 云端 AI 响应慢影响界面交互 | AI & Data Protocol Engineer | 增量与会后总结异步排队；界面显示优雅的 Loading 状态与错误 Code |

---

**文档结语**：

本文档已完整梳理 `AI 听记` macOS App 的现有技术架构、代码模块布局、UI/UX 接防痛点、设计规范要求以及团队迭代路线图。请设计团队依据本文档展开 Figma 视觉设计，研发团队将在设计批准后启动 UI 视图层重构。
