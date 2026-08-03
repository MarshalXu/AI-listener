import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct KeychainManagerTests {
    private let testAccount = "test_account_\(UUID().uuidString)"
    private let keychain = KeychainManager(serviceName: "ai.listener.test-keychain")

    @Test func saveAndGetApiKey() throws {
        let key = "AIzaSyTestApiKey1234567890"
        try keychain.saveApiKey(key, account: testAccount)

        let retrieved = try keychain.getApiKey(account: testAccount)
        #expect(retrieved == key)

        try keychain.deleteApiKey(account: testAccount)
    }

    @Test func overwriteExistingKey() throws {
        let key1 = "KeyOne1234567890"
        let key2 = "KeyTwo0987654321"

        try keychain.saveApiKey(key1, account: testAccount)
        try keychain.saveApiKey(key2, account: testAccount)

        let retrieved = try keychain.getApiKey(account: testAccount)
        #expect(retrieved == key2)

        try keychain.deleteApiKey(account: testAccount)
    }

    @Test func deleteNonExistentKeyDoesNotThrow() throws {
        #expect(throws: Never.self) {
            try keychain.deleteApiKey(account: "non_existent_account_\(UUID().uuidString)")
        }
    }

    @Test func maskedKeyFormatting() {
        #expect(KeychainManager.maskedKey(nil) == "未设置 Key")
        #expect(KeychainManager.maskedKey("") == "未设置 Key")
        #expect(KeychainManager.maskedKey("   ") == "未设置 Key")
        #expect(KeychainManager.maskedKey("12345") == "****")
        #expect(KeychainManager.maskedKey("12345678") == "****")
        #expect(KeychainManager.maskedKey("AIzaSy1234567890End") == "AIza...0End")
    }
}
