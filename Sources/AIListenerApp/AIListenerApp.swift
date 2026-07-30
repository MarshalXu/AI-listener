import AIListenerCore
import AppKit
import SwiftUI

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
    private lazy var coordinator = CaptureCoordinator(
        permission: SystemMicrophonePermissionProvider(),
        capture: AVFoundationMicrophoneCapture(),
        statusSink: { [weak self] in self?.status = $0 },
        eventSink: { [weak self] event in
            Task { @MainActor in
                self?.recentEvents.append(event)
                if self?.recentEvents.count ?? 0 > 20 { self?.recentEvents.removeFirst() }
            }
        }
    )

    var isRecording: Bool { status.state == .recording }
    var canStart: Bool { status.state == .idle || status.state == .failed }
    var canStop: Bool { status.state == .recording || status.state == .interrupted }

    func start() { Task { await coordinator.startFromExplicitUserAction() } }
    func stop() { Task { await coordinator.stop() } }
    func retry() { Task { await coordinator.retry() } }

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

            HStack {
                Button("开始录音", action: model.start)
                    .disabled(!model.canStart)
                Button("停止", action: model.stop)
                    .disabled(!model.canStop)
                if model.status.state == .failed {
                    Button("重试", action: model.retry)
                }
            }

            if model.status.authorization == .denied || model.status.authorization == .restricted {
                Button("打开麦克风隐私设置", action: model.openMicrophoneSettings)
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
}
