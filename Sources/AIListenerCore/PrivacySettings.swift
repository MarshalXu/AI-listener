import Foundation

public enum AIMode: String, Codable, Sendable, CaseIterable {
    case off = "off"                           // 关闭 AI
    case postSessionOnly = "post_session_only" // 仅会后总结
    case incrementalAndPost = "incremental_and_post" // 实时增量与会后

    public var displayName: String {
        switch self {
        case .off: return "关闭 AI"
        case .postSessionOnly: return "仅会后总结"
        case .incrementalAndPost: return "实时增量与会后"
        }
    }
}

public enum AIModel: String, Codable, Sendable, CaseIterable {
    case gemini = "gemini-flash-latest"
    case localMock = "local-mock"

    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini (云端)"
        case .localMock: return "本地 Mock (测试/离线)"
        }
    }
}

public enum MinutesStyle: String, Codable, Sendable, CaseIterable {
    case concise = "concise"
    case standard = "standard"
    case detailed = "detailed"
    case weekly = "weekly"
    case interview = "interview"
    case brainstorm = "brainstorm"

    public var displayName: String {
        switch self {
        case .concise: return "简洁"
        case .standard: return "标准"
        case .detailed: return "详细"
        case .weekly: return "周会"
        case .interview: return "访谈"
        case .brainstorm: return "头脑风暴"
        }
    }
}

public struct PrivacySettings: Codable, Sendable, Equatable {
    public var aiMode: AIMode
    public var aiModel: AIModel
    public var minutesStyle: MinutesStyle
    public var cloudConsentGranted: Bool

    public init(
        aiMode: AIMode = .incrementalAndPost,
        aiModel: AIModel = .localMock,
        minutesStyle: MinutesStyle = .standard,
        cloudConsentGranted: Bool = false
    ) {
        self.aiMode = aiMode
        self.aiModel = aiModel
        self.minutesStyle = minutesStyle
        self.cloudConsentGranted = cloudConsentGranted
    }

    /// Checks whether AI processing can proceed based on mode, model, consent and key presence.
    public func canProcess(hasApiKey: Bool) -> Bool {
        guard aiMode != .off else { return false }
        if aiModel == .localMock {
            return true
        }
        return cloudConsentGranted && hasApiKey
    }
}

public final class PrivacySettingsStore: @unchecked Sendable {
    public static let shared = PrivacySettingsStore()
    private let userDefaults: UserDefaults
    private let key = "ai.listener.privacySettings"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadSettings() -> PrivacySettings {
        guard let data = userDefaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(PrivacySettings.self, from: data) else {
            return PrivacySettings()
        }
        return settings
    }

    public func saveSettings(_ settings: PrivacySettings) {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: key)
        }
    }
}
