import Foundation

public enum ServiceStatus: Equatable, Sendable {
    case idle
    case active
    case degraded(reason: String)
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

        guard settings.canProcess(hasApiKey: hasKey) else { return }
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

        guard settings.canProcess(hasApiKey: hasKey) else {
            self.status = .idle
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
