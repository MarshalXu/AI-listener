import AIListenerCore
import AppKit
import SwiftUI

extension Notification.Name {
    static let aiListenerSessionDidFinalize = Notification.Name("AIListenerSessionDidFinalize")
}

@main
struct AIListenerApp: App {
    @StateObject private var model = CaptureViewModel()
    @State private var showingAISettings = false

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(model: model, showingAISettings: $showingAISettings)
                    .tabItem { Label("录音", systemImage: "mic") }
                SessionLibraryView()
                    .tabItem { Label("记录", systemImage: "list.bullet") }
            }
            .frame(minWidth: 720, minHeight: 520)
            .sheet(isPresented: $showingAISettings) {
                AISettingsView()
            }
        }
    }
}

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var status = CaptureStatus()
    @Published private(set) var recentEvents: [CaptureEvent] = []
    @Published private(set) var partials: [ASRTranscriptEvent] = []
    @Published private(set) var finalized: [ASRTranscriptEvent] = []
    @Published private(set) var pipelineErrorCode: String?
    @Published private(set) var activeMinutes: MeetingMinutes?
    @Published private(set) var minutesDegradationReason: String?

    public let eventBus = TranscriptEventBus()
    public let subtitleController: SubtitleWindowController
    public let minutesService = MeetingMinutesService()
    public let whiteboardService = WhiteboardService()

    private var coordinator: CaptureCoordinator?
    private var pipeline: RecordingSessionPipeline?
    private var currentSessionId: String?

    init() {
        self.subtitleController = SubtitleWindowController()
        self.subtitleController.connectBus(eventBus)
        self.whiteboardService.subscribeToBus(eventBus)
    }

    var isRecording: Bool { status.state == .recording }
    var canStart: Bool { status.state == .idle || status.state == .failed }
    var canStop: Bool { status.state == .recording || status.state == .interrupted }

    func start() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appending(path: "AIListener", directoryHint: .isDirectory)
            let assets = support.appending(path: "Audio", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let store = try SessionStore(databaseURL: support.appending(path: "sessions.sqlite"))
            guard let paths = SherpaModelPaths.bundled() else {
                pipelineErrorCode = "ASR_BUNDLE_MISSING"
                return
            }
            let engine = try SherpaStreamingASREngine(
                paths: paths, modelVersion: "zh-14M-2023-02-23"
            )
            partials = []
            finalized = []
            activeMinutes = nil
            minutesDegradationReason = nil
            pipelineErrorCode = nil
            whiteboardService.clear()

            let sessionId = UUID().uuidString
            self.currentSessionId = sessionId
            Task {
                await minutesService.startSession(sessionId: sessionId)
            }

            let pipeline = try RecordingSessionPipeline(
                store: store, assetRoot: assets, engine: engine,
                eventBus: eventBus,
                partialSink: { [weak self] in self?.partials = $0 },
                finalizedSink: { [weak self] event in
                    self?.finalized.append(event)
                    let record = TranscriptSegmentRecord(
                        segmentId: event.segmentId,
                        sessionId: sessionId,
                        revisionOf: nil,
                        status: "finalized",
                        sequence: event.sequence,
                        revision: 0,
                        startMs: event.startMs,
                        endMs: event.endMs,
                        text: event.text,
                        createdMonotonicMs: Int64(Date().timeIntervalSince1970 * 1000),
                        engineId: "sherpa-onnx",
                        engineModelVersion: "zh-14M"
                    )
                    Task {
                        await self?.minutesService.handleFinalizedSegment(record)
                        if let updated = await self?.minutesService.latestMinutes {
                            await MainActor.run {
                                self?.activeMinutes = updated
                            }
                        }
                        let reason = await self?.minutesService.status.degradationReason
                        await MainActor.run {
                            self?.minutesDegradationReason = reason
                        }
                    }
                },
                diagnosticSink: { [weak self] diagnostic in
                    Task { @MainActor in
                        self?.pipelineErrorCode = [diagnostic.code, diagnostic.underlyingSafeCode]
                            .compactMap { $0 }.joined(separator: ":")
                    }
                }
            )
            self.pipeline = pipeline
            let coordinator = CaptureCoordinator(
                permission: SystemMicrophonePermissionProvider(),
                capture: AVFoundationMicrophoneCapture(),
                statusSink: { [weak self] in self?.status = $0 },
                eventSink: { [weak self] event in
                    Task { @MainActor in
                        self?.recentEvents.append(event)
                        if self?.recentEvents.count ?? 0 > 20 { self?.recentEvents.removeFirst() }
                    }
                },
                frameSink: { [weak self, pipeline] frame in
                    do { try pipeline.consume(frame) }
                    catch {
                        Task { @MainActor in self?.pipelineErrorCode = "AUDIO_WRITE_FAILED" }
                    }
                }
            )
            self.coordinator = coordinator
            Task { await coordinator.startFromExplicitUserAction() }
        } catch {
            pipelineErrorCode = "RECORDING_PIPELINE_START_FAILED"
        }
    }

    func stop() {
        guard let coordinator else { return }
        let sessionId = self.currentSessionId
        Task {
            await coordinator.stop()
            do {
                try pipeline?.finish()
                if let sessionId {
                    let finalMinutes = await minutesService.finishSession(sessionId: sessionId)
                    await MainActor.run {
                        self.activeMinutes = finalMinutes
                    }
                    let reason = await minutesService.status.degradationReason
                    await MainActor.run {
                        self.minutesDegradationReason = reason
                    }
                    // Flush any batched finalized text before snapshotting so the
                    // last utterances are not lost (AC2.1). flushBatcher() hands
                    // the pending items to handleFinalizedText on a detached Task,
                    // so yield briefly to let that drain before generating.
                    self.whiteboardService.flushBatcher()
                    // Give the batcher's flush callback a moment to enqueue its
                    // processing Task. It is bounded and non-blocking.
                    try? await Task.sleep(nanoseconds: 100_000_000)

                    let snapshot = self.whiteboardService.generateSnapshot(sessionId: sessionId)
                    if let store = try? SessionStore(databaseURL: FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "AIListener/sessions.sqlite")) {
                        do {
                            try store.saveWhiteboardSnapshot(snapshot)
                        } catch {
                            // Surface persistence failures instead of silently
                            // swallowing them with try? (AC2.3).
                            await MainActor.run {
                                self.pipelineErrorCode = "WHITEBOARD_SNAPSHOT_SAVE_FAILED:\(error.localizedDescription)"
                            }
                        }
                    }
                }
                NotificationCenter.default.post(name: .aiListenerSessionDidFinalize, object: nil)
            }
            catch { pipelineErrorCode = "RECORDING_PIPELINE_FINISH_FAILED" }
            pipeline = nil
            self.coordinator = nil
            self.currentSessionId = nil
        }
    }

    func retry() { start() }

    func clearTranscriptDisplay() {
        partials = []
        finalized = []
        activeMinutes = nil
        minutesDegradationReason = nil
        eventBus.publishReset(sessionId: "current")
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct ContentView: View {
    @ObservedObject var model: CaptureViewModel
    @Binding var showingAISettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button(action: { showingAISettings = true }) {
                    Label("AI 纪要与隐私设置", systemImage: "gearshape")
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(model.isRecording ? .red : .secondary)
                    .frame(width: 12, height: 12)
                Text(label)
                    .font(.title2)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("开始录音", action: model.start)
                    .disabled(!model.canStart)
                Button("停止", action: model.stop)
                    .disabled(!model.canStop)
                Button("清屏", action: model.clearTranscriptDisplay)
                    .disabled(model.partials.isEmpty && model.finalized.isEmpty)
                Button(action: model.subtitleController.toggleWindow) {
                    Label("字幕浮窗", systemImage: "captions.bubble")
                }
                if model.status.state == .failed {
                    Button("重试", action: model.retry)
                }
            }

            if model.status.authorization == .denied || model.status.authorization == .restricted {
                Button("打开麦克风隐私设置", action: model.openMicrophoneSettings)
            }

            GroupBox(label: Label("实时增量纪要", systemImage: "sparkles")) {
                if let minutes = model.activeMinutes {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(minutes.overview.generalSummary)
                            .font(.subheadline)
                        if let firstTopic = minutes.topics.first {
                            Text("议题：\(firstTopic.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                } else if let reason = model.minutesDegradationReason {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Text("录音与识别不受影响，纪要将在条件满足后恢复生成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(action: { showingAISettings = true }) {
                            Label("前往设置", systemImage: "gearshape")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                } else if model.isRecording {
                    Text("等待足够逐字稿后自动生成增量纪要…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                } else {
                    Text("开始录音后将自动生成实时增量纪要。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }

            GroupBox(label: Label("实时 AI 画板", systemImage: "paintpalette")) {
                WhiteboardView(whiteboardService: model.whiteboardService)
                    .frame(height: 220)
            }

            List {
                ForEach(model.finalized, id: \.segmentId) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(timestamp(event.startMs)).font(.caption.monospacedDigit())
                        Text(event.text)
                    }
                }
                ForEach(model.partials, id: \.segmentId) { event in
                    HStack(alignment: .firstTextBaseline) {
                        Text(timestamp(event.startMs)).font(.caption.monospacedDigit())
                        Text(event.text).foregroundStyle(.secondary)
                        Text("…").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 180)

            if let code = model.pipelineErrorCode {
                Text("本地处理错误：\(code)").foregroundStyle(.red)
            }

            Text("仅捕获麦克风；音频与 finalized 逐字稿只保存在本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var label: String {
        switch model.status.state {
        case .idle: "未录音"
        case .requestingPermission: "正在检查麦克风权限"
        case .permissionBlocked: "麦克风权限不可用"
        case .preparing: "正在准备麦克风"
        case .recording: "正在录音"
        case .interrupted: "录音已中断"
        case .stopping: "正在停止"
        case .failed: "启动失败"
        }
    }

    private var detail: String {
        if let code = model.status.errorCode { return "错误码：\(code)" }
        if let reason = model.status.terminationReason { return "终止原因：\(reason.rawValue)" }
        return "录音只会在你点击“开始录音”后启动。"
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld.%03lld",
               milliseconds / 60_000, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }
}
