import Foundation

public enum ServiceStatus: Equatable, Sendable {
    case idle
    case active
    case degraded(reason: String)

    /// Convenience accessor for the embedded degradation reason, if any.
    public var degradationReason: String? {
        if case .degraded(let reason) = self { return reason }
        return nil
    }
}

/// Builds a human-readable degradation reason for the case where AI processing
/// cannot start because the user's configuration is incomplete. The reasons
/// are intentionally specific so the UI can show actionable guidance.
enum MinutesDegradationReason {
    static func forUnconfigured(settings: PrivacySettings, hasApiKey: Bool) -> String {
        if settings.aiMode == .off {
            return "AI 已关闭：请在设置中开启 AI 模式以生成纪要。"
        }
        if settings.aiModel != .localMock {
            if !settings.cloudConsentGranted {
                return "未授权云端处理：请在「AI 纪要与隐私设置」中勾选允许逐字稿上传至云端。"
            }
            if !hasApiKey {
                return "未设置 Gemini API Key：请在「AI 纪要与隐私设置」中保存 Key 后重试。"
            }
        }
        return "当前配置不满足生成纪要的条件，请检查 AI 纪要与隐私设置。"
    }
}

public actor MeetingMinutesService {
    private let client: GeminiClientProtocol
    private let sessionStore: SessionStore?
    private let privacySettingsStore: PrivacySettingsStore
    private let keychainManager: KeychainManager

    private var currentSessionId: String?
    private var bufferedSegments: [TranscriptSegmentRecord] = []
    private var lastIncrementalCount: Int = 0
    private(set) public var status: ServiceStatus = .idle
    private(set) public var latestMinutes: MeetingMinutes?

    public init(
        client: GeminiClientProtocol = GeminiClient(),
        sessionStore: SessionStore? = nil,
        privacySettingsStore: PrivacySettingsStore = .shared,
        keychainManager: KeychainManager = .shared
    ) {
        self.client = client
        self.sessionStore = sessionStore
        self.privacySettingsStore = privacySettingsStore
        self.keychainManager = keychainManager
    }

    public func startSession(sessionId: String) {
        self.currentSessionId = sessionId
        self.bufferedSegments.removeAll()
        self.lastIncrementalCount = 0
        self.latestMinutes = nil
        self.status = .active
    }

    public func handleFinalizedSegment(_ segment: TranscriptSegmentRecord) async {
        guard let activeSessionId = currentSessionId, segment.sessionId == activeSessionId else {
            return
        }
        bufferedSegments.append(segment)
        let count = bufferedSegments.count
        let segmentsToProcess = bufferedSegments

        let settings = privacySettingsStore.loadSettings()
        let apiKey = try? keychainManager.getApiKey()
        let hasKey = apiKey != nil && !apiKey!.isEmpty

        guard settings.canProcess(hasApiKey: hasKey) else {
            self.status = .degraded(reason: MinutesDegradationReason.forUnconfigured(settings: settings, hasApiKey: hasKey))
            return
        }
        guard settings.aiMode == .incrementalAndPost else {
            // Post-session-only mode does not produce incremental minutes; stay
            // active but emit a gentle degraded hint so the UI can explain why
            // no live summary is appearing.
            self.status = .degraded(reason: "当前为仅会后总结模式，录音中不生成增量纪要。")
            return
        }

        // Trigger incremental update every 3 new finalized segments
        if count - lastIncrementalCount >= 3 {
            lastIncrementalCount = count
            await processIncremental(sessionId: activeSessionId, segments: segmentsToProcess, settings: settings, apiKey: apiKey)
        }
    }

    public func processIncremental(
        sessionId: String,
        segments: [TranscriptSegmentRecord],
        settings: PrivacySettings,
        apiKey: String?
    ) async {
        do {
            let actualClient: GeminiClientProtocol
            if settings.aiModel == .localMock {
                actualClient = (client as? MockGeminiClient) ?? MockGeminiClient()
            } else {
                actualClient = client
            }
            let minutes = try await actualClient.generateMinutes(
                sessionId: sessionId,
                segments: segments,
                kind: .incremental,
                style: settings.minutesStyle,
                apiKey: apiKey
            )

            self.latestMinutes = minutes
            self.status = .active

            try? sessionStore?.saveMeetingMinutes(minutes)
        } catch {
            self.status = .degraded(reason: "Incremental generation failed: \(error.localizedDescription)")
            // Silent degradation: do not throw error or crash recording
        }
    }

    public func finishSession(sessionId: String) async -> MeetingMinutes? {
        let segmentsToProcess = bufferedSegments

        let settings = privacySettingsStore.loadSettings()
        let apiKey = try? keychainManager.getApiKey()
        let hasKey = apiKey != nil && !apiKey!.isEmpty

        guard settings.canProcess(hasApiKey: hasKey) else {
            self.status = .degraded(reason: MinutesDegradationReason.forUnconfigured(settings: settings, hasApiKey: hasKey))
            return nil
        }

        do {
            let actualClient: GeminiClientProtocol
            if settings.aiModel == .localMock {
                actualClient = (client as? MockGeminiClient) ?? MockGeminiClient()
            } else {
                actualClient = client
            }
            let finalMinutes = try await actualClient.generateMinutes(
                sessionId: sessionId,
                segments: segmentsToProcess,
                kind: .postSession,
                style: settings.minutesStyle,
                apiKey: apiKey
            )

            self.latestMinutes = finalMinutes
            self.status = .idle

            try? sessionStore?.saveMeetingMinutes(finalMinutes)
            return finalMinutes
        } catch {
            self.status = .degraded(reason: "Post-session generation failed: \(error.localizedDescription)")
            return nil
        }
    }
}
