import Foundation
import Testing
@testable import AIListenerCore

@Suite
struct PrivacySettingsTests {
    @Test func canProcessModeOffReturnsFalse() {
        let settings = PrivacySettings(aiMode: .off, aiModel: .gemini, cloudConsentGranted: true)
        #expect(settings.canProcess(hasApiKey: true) == false)
    }

    @Test func canProcessLocalMockReturnsTrueWithoutCloudConsent() {
        let settings = PrivacySettings(aiMode: .incrementalAndPost, aiModel: .localMock, cloudConsentGranted: false)
        #expect(settings.canProcess(hasApiKey: false) == true)
    }

    @Test func canProcessCloudGeminiRequiresConsentAndApiKey() {
        var settings = PrivacySettings(aiMode: .incrementalAndPost, aiModel: .gemini, cloudConsentGranted: false)
        // No consent, has key -> false
        #expect(settings.canProcess(hasApiKey: true) == false)

        // Has consent, no key -> false
        settings.cloudConsentGranted = true
        #expect(settings.canProcess(hasApiKey: false) == false)

        // Has consent, has key -> true
        #expect(settings.canProcess(hasApiKey: true) == true)
    }

    @Test func privacySettingsStorePersistence() {
        let defaults = UserDefaults(suiteName: "PrivacySettingsTests_\(UUID().uuidString)")!
        let store = PrivacySettingsStore(userDefaults: defaults)

        let initial = store.loadSettings()
        #expect(initial == PrivacySettings())

        let updated = PrivacySettings(
            aiMode: .postSessionOnly,
            aiModel: .gemini,
            minutesStyle: .detailed,
            cloudConsentGranted: true
        )
        store.saveSettings(updated)

        let reloaded = store.loadSettings()
        #expect(reloaded == updated)
    }
}
