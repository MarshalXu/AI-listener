import AIListenerCore
import AppKit
import SwiftUI

extension Notification.Name {
    static let aiListenerSessionDidFinalize = Notification.Name("AIListenerSessionDidFinalize")
}

@main
struct AIListenerApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(model: model)
                    .tabItem { Label("录音", systemImage: "mic") }
                SessionLibraryView()
                    .tabItem { Label("记录", systemImage: "list.bullet") }
            }
            .frame(minWidth: 680, minHeight: 480)
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

    public let eventBus = TranscriptEventBus()
    public let subtitleController: SubtitleWindowController

    private var coordinator: CaptureCoordinator?
    private var pipeline: RecordingSessionPipeline?

    init() {
        self.subtitleController = SubtitleWindowController()
        self.subtitleController.connectBus(eventBus)
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
            pipelineErrorCode = nil
            let pipeline = try RecordingSessionPipeline(
                store: store, assetRoot: assets, engine: engine,
                eventBus: eventBus,
                partialSink: { [weak self] in self?.partials = $0 },
                finalizedSink: { [weak self] event in self?.finalized.append(event) },
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
        Task {
            await coordinator.stop()
            do {
                try pipeline?.finish()
                NotificationCenter.default.post(name: .aiListenerSessionDidFinalize, object: nil)
            }
            catch { pipelineErrorCode = "RECORDING_PIPELINE_FINISH_FAILED" }
            pipeline = nil
            self.coordinator = nil
        }
    }

    func retry() { start() }

    /// Clears transient on-screen captions without deleting persisted local data.
    func clearTranscriptDisplay() {
        partials = []
        finalized = []
        eventBus.publishReset(sessionId: "current")
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct ContentView: View {
    @ObservedObject var model: CaptureViewModel

    var body: some View {
        VStack(spacing: 20) {
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
        .padding(32)
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
