import Foundation

public enum ServiceStatus: Equatable, Sendable {
    case idle
    case active
    case degraded(reason: String)

    /// Convenience accessor for the degradation reason, if any. UI layers read
    /// this to surface actionable guidance to the user (e.g. "no API key set").
    public var degradationReason: String? {
        if case .degraded(let reason) = self { return reason }
        return nil
    }
}

/// Produces a human-readable, actionable reason explaining why AI minutes
/// cannot be processed for the given settings/key state. Returns nil when
/// processing *can* proceed.
private func degradationReasonIfUnconfigured(
    settings: PrivacySettings,
    hasApiKey: Bool
) -> String? {
    guard settings.canProcess(hasApiKey: hasApiKey) else {
        if settings.aiMode == .off {
            return "AI 已关闭：请在设置中开启 AI 模式以生成纪要。"
        }
        if settings.aiModel == .localMock {
            // localMock does not require consent or key, so reaching here is
            // unexpected; treat as a configuration error.
            return "AI 模式已关闭，无法生成纪要。"
        }
        if !settings.cloudConsentGranted {
            return "未授权云端处理：请在「AI 纪要与隐私设置」中勾选允许逐字稿上传至云端。"
        }
        if !hasApiKey {
            return "未设置 Gemini API Key：请在「AI 纪要与隐私设置」中保存 Key 后重试。"
        }
        return "AI 纪要生成条件未满足，请检查设置。"
    }
    return nil
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

        // Surface actionable degradation rather than silently dropping the
        // segment; the UI binds to `status` to show guidance.
        if let reason = degradationReasonIfUnconfigured(settings: settings, hasApiKey: hasKey) {
            self.status = .degraded(reason: reason)
            return
        }
        guard settings.aiMode == .incrementalAndPost else { return }

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

        // Surface actionable degradation rather than silently returning nil;
        // the UI binds to `status` to show guidance and a CTA to settings.
        if let reason = degradationReasonIfUnconfigured(settings: settings, hasApiKey: hasKey) {
            self.status = .degraded(reason: reason)
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
