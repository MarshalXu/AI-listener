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
    @Published var selectedTab: Int = 0 // 0: Transcript, 1: Summary, 2: Whiteboard
    @Published var selection: String? {
        didSet {
            guard selection != oldValue, let selection else { return }
            open(sessionId: selection)
        }
    }

    // XUC-12: sidebar search + navigation filter state. These drive the
    // client-side filtering of `sessions` via `SessionListFilter.apply` (pure
    // function in AIListenerCore, unit-tested there). Favorites are a local
    // UserDefaults set — the store schema is unchanged.
    @Published var searchText: String = ""
    @Published var selectedFilter: SidebarFilter = .all
    @Published var showingAISettings: Bool = false
    let favorites = SessionFavoritesStore()

    /// Client-side filtered view of `sessions` honoring the sidebar search
    /// text and the selected navigation filter.
    var filteredSessions: [SessionListItem] {
        SessionListFilter.apply(
            to: sessions,
            filter: selectedFilter,
            searchText: searchText,
            favoriteIds: favorites.favoriteIds
        )
    }

    private var store: SessionStore?
    private var playback: PlaybackService?
    private let minutesService = MeetingMinutesService()
    public let whiteboardService = WhiteboardService()
    public let audioPlayerModel = AudioPlayerModel()

    /// Audio asset URL for the currently open session, derived from
    /// `PlaybackService.assetRoot` + `detail.asset.relativePath`.
    var currentAssetURL: URL? {
        guard let detail, let playback else { return nil }
        let root = playback.assetRootURL
        return root.appending(path: detail.asset.relativePath)
    }

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
            if let playback {
                audioPlayerModel.configure(playback: playback, assetURL: currentAssetURL)
            }
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
            audioPlayerModel.syncAfterSeek()
        } catch {
            errorCode = "PLAYBACK_SEEK_FAILED"
        }
    }

    func play(atMs: Int64) {
        do {
            playbackPosition = try playback?.play(atMs: atMs)
            errorCode = nil
            audioPlayerModel.syncAfterSeek()
        } catch {
            errorCode = "PLAYBACK_SEEK_FAILED"
        }
    }

    func generateMinutes() {
        guard let detail = detail else { return }

        // Pre-flight: fail fast with an actionable error code before touching
        // the network. This mirrors MeetingMinutesService's degradation logic
        // but is surfaced here so the library view can show guidance without
        // waiting for an actor round-trip.
        let settings = PrivacySettingsStore.shared.loadSettings()
        let apiKey = try? KeychainManager.shared.getApiKey()
        let hasKey = apiKey != nil && !apiKey!.isEmpty

        if settings.aiMode == .off {
            self.errorCode = "MINUTES_AI_MODE_OFF"
            return
        }
        if settings.aiModel != .localMock {
            if !settings.cloudConsentGranted {
                self.errorCode = "MINUTES_CLOUD_CONSENT_MISSING"
                return
            }
            if !hasKey {
                self.errorCode = "MINUTES_API_KEY_MISSING"
                return
            }
        }

        Task {
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
                self.minutes = generated
                self.errorCode = nil
            } catch let GeminiClientError.invalidResponse(code, _) {
                // 4xx → bad key/quota; 5xx → server fault. Both map to codes
                // the UI can render with tailored guidance.
                if (400..<500).contains(code) {
                    self.errorCode = "MINUTES_API_KEY_INVALID_OR_QUOTA"
                } else {
                    self.errorCode = "MINUTES_GEMINI_SERVER_ERROR"
                }
            } catch GeminiClientError.invalidJsonPayload {
                self.errorCode = "MINUTES_RESPONSE_PARSE_FAILED"
            } catch GeminiClientError.networkError {
                self.errorCode = "MINUTES_NETWORK_ERROR"
            } catch {
                self.errorCode = "MINUTES_GENERATE_FAILED"
            }
        }
    }
}

// MARK: - Shared formatters

/// Shared timestamp formatter used by the detail and status-bar views.
private func sessionTimestamp(_ milliseconds: Int64) -> String {
    String(format: "%02lld:%02lld.%03lld",
            milliseconds / 60_000, (milliseconds / 1_000) % 60, milliseconds % 1_000)
}

/// Chinese guidance rendered beneath a minutes error code, pointing the
/// user at the specific settings action that unblocks generation.
func sessionMinutesGuidance(for code: String) -> String {
    switch code {
    case "MINUTES_AI_MODE_OFF":
        return "请在「AI 纪要与隐私设置」中开启 AI 模式后重试。"
    case "MINUTES_API_KEY_MISSING":
        return "请前往「AI 纪要与隐私设置」保存 Gemini API Key 后重试。"
    case "MINUTES_CLOUD_CONSENT_MISSING":
        return "请前往「AI 纪要与隐私设置」勾选允许逐字稿上传至云端后重试。"
    case "MINUTES_API_KEY_INVALID_OR_QUOTA":
        return "Gemini 返回 4xx，请检查 API Key 是否有效、是否触发配额限制。"
    case "MINUTES_GEMINI_SERVER_ERROR":
        return "Gemini 服务端异常（5xx），请稍后重试。"
    case "MINUTES_NETWORK_ERROR":
        return "网络异常，请检查连接后重试。"
    case "MINUTES_RESPONSE_PARSE_FAILED":
        return "Gemini 返回内容解析失败，可重试或检查模型输出规范。"
    default:
        return "纪要生成失败，请检查设置后重试。"
    }
}

// MARK: - Reusable columns

/// Reusable session list column (the middle column of the app-level
/// three-column split, and the content column of the legacy two-column view).
///
/// Extracted from `SessionLibraryView` (XUC-11) so the app-level
/// `MainSplitView` can compose it as its content column. Honors the sidebar
/// search/filter/favorites state (XUC-12) and renders the date-grouped
/// card-style rows (XUC-13).
struct SessionListView: View {
    @ObservedObject var model: SessionLibraryViewModel

    var body: some View {
        // Content column (XUC-13): the grouped, card-styled session list.
        // `filteredSessions` honors the sidebar search/filter (XUC-12);
        // `groupSessionsByDay` then segments that newest-first list into
        // 今天/昨天/更早 sections. Empty buckets are dropped so only
        // non-empty groups render.
        let groups = SessionListGrouping.groupSessionsByDay(model.filteredSessions)
        List(selection: $model.selection) {
            ForEach(groups) { group in
                Section(group.label) {
                    ForEach(group.items) { session in
                        sessionCard(session)
                            .tag(session.sessionId)
                    }
                }
            }
        }
        .overlay {
            if model.filteredSessions.isEmpty {
                emptyStateView
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            Button("刷新", systemImage: "arrow.clockwise", action: model.reload)
        }
    }

    /// Empty-state shown in the middle column when the filtered list is empty.
    /// Varies by the selected sidebar filter so the user gets a meaningful
    /// message (e.g. "no favorites yet" vs. the trash placeholder).
    @ViewBuilder
    private var emptyStateView: some View {
        switch model.selectedFilter {
        case .favorites:
            ContentUnavailableView("暂无收藏", systemImage: "star",
                                   description: Text("在会话列表中点击星标即可收藏。"))
        case .trash:
            // Trash is a placeholder: hard-delete store has no trash state,
            // so this is always empty by design until a soft-delete model
            // lands in a later slice.
            ContentUnavailableView("回收站为空", systemImage: "trash",
                                   description: Text("删除的会话不进入回收站。"))
        case .recent, .all:
            if model.searchText.isEmpty {
                ContentUnavailableView("暂无可回听记录", systemImage: "waveform")
            } else {
                ContentUnavailableView("无匹配会话", systemImage: "magnifyingglass",
                                      description: Text("尝试更换关键词或清除筛选。"))
            }
        }
    }

    /// Middle-column title mirrors the selected sidebar filter so the user
    /// always sees which list they are viewing.
    private var navigationTitle: String {
        model.selectedFilter.label
    }

    /// Card-style row for a single session in the grouped list. Shows the
    /// preview title, creation time, and duration, with a highlighted look
    /// when selected. Selection binding and `open(sessionId:)` are handled
    /// by the enclosing `List(selection:)` + `.tag(sessionId)`.
    @ViewBuilder
    private func sessionCard(_ session: SessionListItem) -> some View {
        let isSelected = model.selection == session.sessionId
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.previewText ?? "无 finalized 逐字稿")
                    .font(.body)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(SessionListGrouping.timeOfDay(from: session.createdAtUtc))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                // XUC-12: favorite indicator (star) kept on the card row so
                // favoriting is still visible after the list migration.
                if model.favorites.isFavorite(session.sessionId) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(SessionListGrouping.durationLabel(session.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

/// Reusable session detail column (the right column of the app-level
/// three-column split). Hosts the title bar + audio player bar +
/// transcript / summary / whiteboard tabs and the bottom playback/error
/// inset (XUC-11 extraction; XUC-14 added the audio player bar).
struct SessionDetailView: View {
    @ObservedObject var model: SessionLibraryViewModel

    var body: some View {
        if let detail = model.detail {
            VStack(spacing: 0) {
                // Title bar
                HStack {
                    Text(Date(timeIntervalSince1970: Double(detail.session.createdAtUtc) / 1_000),
                         style: .date)
                        .font(.headline)
                    Spacer()
                    Text(SessionListGrouping.durationLabel(detail.asset.durationMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(NSColor.windowBackgroundColor))

                // Audio player bar (XUC-14)
                AudioPlayerBar(model: model.audioPlayerModel)

                Divider()

                // Tab selector
                Picker("", selection: $model.selectedTab) {
                    Text("转录").tag(0)
                    Text("总结").tag(1)
                    Text("画板").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                // Tab content
                if model.selectedTab == 0 {
                    List(detail.segments, id: \.segmentId) { segment in
                        Button {
                            model.play(segment)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(sessionTimestamp(segment.startMs))
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
                            ContentUnavailableView("尚无总结", systemImage: "doc.text")
                            Button("生成总结") {
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
            .safeAreaInset(edge: .bottom) {
                SessionDetailStatusBar(model: model)
            }
        } else {
            ContentUnavailableView("选择一条记录", systemImage: "text.bubble")
        }
    }
}

/// Bottom playback-position / error-code bar shared by the detail column.
struct SessionDetailStatusBar: View {
    @ObservedObject var model: SessionLibraryViewModel

    var body: some View {
        VStack(spacing: 4) {
            if let position = model.playbackPosition {
                Text("目标 \(sessionTimestamp(position.requestedMs)) · 实际 \(sessionTimestamp(position.actualMs))")
            }
            if let code = model.errorCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("错误码：\(code)").foregroundStyle(.red)
                    Text(sessionMinutesGuidance(for: code))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(8)
    }
}

// MARK: - Legacy two-column entry

/// Legacy two-column library entry. Delegates to the same reusable
/// components as the app-level `MainSplitView` (XUC-11) so behavior stays
/// consistent; the sidebar column uses `SidebarView` (XUC-12).
struct SessionLibraryView: View {
    @StateObject private var model = SessionLibraryViewModel()

    var body: some View {
        NavigationSplitView {
            // XUC-12: left column is the dedicated sidebar (search box +
            // navigation items + bottom user/settings entry). Settings sheet
            // is triggered from here; its logic is unchanged.
            SidebarView(
                searchText: $model.searchText,
                selectedFilter: $model.selectedFilter,
                showingAISettings: $model.showingAISettings
            )
        } content: {
            SessionListView(model: model)
        } detail: {
            SessionDetailView(model: model)
        }
        .onAppear(perform: model.reload)
        .onReceive(NotificationCenter.default.publisher(for: .aiListenerSessionDidFinalize)) { _ in
            model.reload()
        }
        // XUC-12: settings sheet now triggered from the sidebar's bottom
        // settings button (via model.showingAISettings). The settings view's
        // logic is unchanged — only its trigger source migrated.
        .sheet(isPresented: $model.showingAISettings) {
            AISettingsView()
        }
    }
}
