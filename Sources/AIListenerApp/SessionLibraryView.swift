import AIListenerCore
import Foundation
import SwiftUI

@MainActor
final class SessionLibraryViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionListItem] = []
    @Published private(set) var detail: SessionDetail?
    @Published private(set) var minutes: MeetingMinutes?
    @Published private(set) var playbackPosition: PlaybackPosition?
    @Published private(set) var errorCode: String?
    @Published private(set) var whiteboardSnapshot: WhiteboardSnapshot?
    @Published var selectedTab: Int = 0 // 0: Transcript, 1: Meeting Minutes, 2: AI Whiteboard
    @Published var selection: String? {
        didSet {
            guard selection != oldValue, let selection else { return }
            open(sessionId: selection)
        }
    }

    private var store: SessionStore?
    private var playback: PlaybackService?
    private let minutesService = MeetingMinutesService()
    public let whiteboardService = WhiteboardService()

    init() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appending(path: "AIListener", directoryHint: .isDirectory)
            let assets = support.appending(path: "Audio", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let store = try SessionStore(databaseURL: support.appending(path: "sessions.sqlite"))
            self.store = store
            playback = PlaybackService(store: store, assetRoot: assets)
            reload()
        } catch {
            errorCode = "LIBRARY_OPEN_FAILED"
        }
    }

    func reload() {
        do {
            sessions = try store?.listPlayableSessions() ?? []
            errorCode = nil
            if let selection, !sessions.contains(where: { $0.sessionId == selection }) {
                self.selection = nil
                detail = nil
                minutes = nil
            }
        } catch {
            errorCode = "LIBRARY_READ_FAILED"
        }
    }

    func open(sessionId: String) {
        do {
            detail = try playback?.open(sessionId: sessionId)
            minutes = try store?.fetchMeetingMinutes(sessionId: sessionId)
            whiteboardSnapshot = try store?.fetchWhiteboardSnapshot(sessionId: sessionId)
            if let snapshot = whiteboardSnapshot {
                whiteboardService.loadSnapshot(snapshot)
            } else {
                whiteboardService.clear()
            }
            playbackPosition = nil
            errorCode = nil
        } catch PlaybackServiceError.assetMissing {
            errorCode = "PLAYBACK_ASSET_MISSING"
            reload()
        } catch PlaybackServiceError.assetCorrupt {
            errorCode = "PLAYBACK_ASSET_CORRUPT"
            reload()
        } catch {
            errorCode = "PLAYBACK_OPEN_FAILED"
        }
    }

    func play(_ segment: TranscriptSegmentRecord) {
        do {
            playbackPosition = try playback?.play(segment: segment)
            errorCode = nil
        } catch {
            errorCode = "PLAYBACK_SEEK_FAILED"
        }
    }

    func play(atMs: Int64) {
        do {
            playbackPosition = try playback?.play(atMs: atMs)
            errorCode = nil
        } catch {
            errorCode = "PLAYBACK_SEEK_FAILED"
        }
    }

    func generateMinutes() {
        guard let detail = detail else { return }
        Task {
            let settings = PrivacySettingsStore.shared.loadSettings()
            let apiKey = try? KeychainManager.shared.getApiKey()
            let hasKey = apiKey != nil && !apiKey!.isEmpty

            // Pre-flight: surface configuration problems before any network call.
            if settings.aiMode == .off {
                await MainActor.run { self.errorCode = "MINUTES_AI_MODE_OFF" }
                return
            }
            if settings.aiModel != .localMock {
                if !settings.cloudConsentGranted {
                    await MainActor.run { self.errorCode = "MINUTES_CLOUD_CONSENT_MISSING" }
                    return
                }
                if !hasKey {
                    await MainActor.run { self.errorCode = "MINUTES_API_KEY_MISSING" }
                    return
                }
            }

            let client: GeminiClientProtocol = settings.aiModel == .localMock ? MockGeminiClient() : GeminiClient()

            do {
                let generated = try await client.generateMinutes(
                    sessionId: detail.session.sessionId,
                    segments: detail.segments,
                    kind: .postSession,
                    style: settings.minutesStyle,
                    apiKey: apiKey
                )
                try store?.saveMeetingMinutes(generated)
                await MainActor.run {
                    self.minutes = generated
                    self.errorCode = nil
                }
            } catch let error as GeminiClientError {
                await MainActor.run { self.errorCode = Self.errorCode(for: error) }
            } catch {
                await MainActor.run { self.errorCode = "MINUTES_NETWORK_ERROR" }
            }
        }
    }

    /// Maps a `GeminiClientError` to a granular, user-actionable error code.
    private static func errorCode(for error: GeminiClientError) -> String {
        switch error {
        case .missingApiKey:
            return "MINUTES_API_KEY_MISSING"
        case .invalidResponse(let statusCode, _):
            switch statusCode {
            case 400...499:
                return "MINUTES_API_KEY_INVALID_OR_QUOTA"
            default:
                return "MINUTES_GEMINI_SERVER_ERROR"
            }
        case .invalidJsonPayload:
            return "MINUTES_RESPONSE_PARSE_FAILED"
        case .networkError:
            return "MINUTES_NETWORK_ERROR"
        }
    }

    /// Human-readable guidance shown beneath an error code.
    static func guidance(for code: String?) -> String? {
        guard let code else { return nil }
        switch code {
        case "MINUTES_API_KEY_MISSING":
            return "请前往「AI 纪要与隐私设置」保存 Gemini API Key 后重试。"
        case "MINUTES_CLOUD_CONSENT_MISSING":
            return "请在「AI 纪要与隐私设置」中勾选允许逐字稿上传至云端后重试。"
        case "MINUTES_AI_MODE_OFF":
            return "AI 模式已关闭，请在「AI 纪要与隐私设置」中开启后重试。"
        case "MINUTES_API_KEY_INVALID_OR_QUOTA":
            return "Gemini 返回客户端错误，请检查 API Key 是否有效、是否超配额。"
        case "MINUTES_GEMINI_SERVER_ERROR":
            return "Gemini 服务端暂时不可用，请稍后重试。"
        case "MINUTES_NETWORK_ERROR":
            return "网络连接失败，请检查网络后重试。"
        case "MINUTES_RESPONSE_PARSE_FAILED":
            return "Gemini 返回内容无法解析为纪要，请重试或更换模型。"
        case "MINUTES_GENERATE_FAILED":
            return "纪要生成失败，请重试。"
        default:
            return nil
        }
    }
}

struct SessionLibraryView: View {
    @StateObject private var model = SessionLibraryViewModel()

    var body: some View {
        NavigationSplitView {
            List(model.sessions, selection: $model.selection) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date(timeIntervalSince1970: Double(session.createdAtUtc) / 1_000),
                         style: .date)
                    Text(session.previewText ?? "无 finalized 逐字稿")
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Text(duration(session.durationMs))
                        .font(.caption.monospacedDigit())
                }
                .tag(session.sessionId)
            }
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView("暂无可回听记录", systemImage: "waveform")
                }
            }
            .navigationTitle("记录")
            .toolbar {
                Button("刷新", systemImage: "arrow.clockwise", action: model.reload)
            }
        } detail: {
            if let detail = model.detail {
                VStack(spacing: 0) {
                    Picker("", selection: $model.selectedTab) {
                        Text("逐字稿").tag(0)
                        Text("会议纪要").tag(1)
                        Text("AI 画板").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding()

                    if model.selectedTab == 0 {
                        List(detail.segments, id: \.segmentId) { segment in
                            Button {
                                model.play(segment)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(timestamp(segment.startMs))
                                        .font(.body.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(segment.text)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "play.fill")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else if model.selectedTab == 1 {
                        if let minutes = model.minutes {
                            MeetingMinutesView(minutes: minutes) { atMs in
                                model.play(atMs: atMs)
                            }
                        } else {
                            VStack(spacing: 16) {
                                ContentUnavailableView("尚无会议纪要", systemImage: "doc.text")
                                Button("生成会议纪要") {
                                    model.generateMinutes()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding()
                        }
                    } else {
                        WhiteboardView(whiteboardService: model.whiteboardService)
                    }
                }
                .navigationTitle("会话详情")
            } else {
                ContentUnavailableView("选择一条记录", systemImage: "text.bubble")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if let position = model.playbackPosition {
                    Text("目标 \(timestamp(position.requestedMs)) · 实际 \(timestamp(position.actualMs))")
                }
                if let code = model.errorCode {
                    Text("错误码：\(code)").foregroundStyle(.red)
                    if let guidance = SessionLibraryViewModel.guidance(for: code) {
                        Text(guidance)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .font(.caption)
            .padding(8)
        }
        .onAppear(perform: model.reload)
        .onReceive(NotificationCenter.default.publisher(for: .aiListenerSessionDidFinalize)) { _ in
            model.reload()
        }
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld.%03lld",
               milliseconds / 60_000, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }

    private func duration(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld", milliseconds / 60_000, (milliseconds / 1_000) % 60)
    }
}
