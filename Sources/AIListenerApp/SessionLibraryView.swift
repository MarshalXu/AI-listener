import AIListenerCore
import Foundation
import SwiftUI

@MainActor
final class SessionLibraryViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionListItem] = []
    @Published private(set) var detail: SessionDetail?
    @Published private(set) var playbackPosition: PlaybackPosition?
    @Published private(set) var errorCode: String?
    @Published var selection: String? {
        didSet {
            guard selection != oldValue, let selection else { return }
            open(sessionId: selection)
        }
    }

    private var store: SessionStore?
    private var playback: PlaybackService?

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
            }
        } catch {
            errorCode = "LIBRARY_READ_FAILED"
        }
    }

    func open(sessionId: String) {
        do {
            detail = try playback?.open(sessionId: sessionId)
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
                .navigationTitle("逐字稿")
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
        String(format: "%lld:%02lld", milliseconds / 60_000, (milliseconds / 1_000) % 60)
    }
}
