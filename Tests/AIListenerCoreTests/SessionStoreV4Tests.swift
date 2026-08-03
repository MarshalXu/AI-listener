import Foundation
import Testing
@testable import AIListenerCore

struct SessionStoreV4Tests {
    @Test func testSchemaV4MigrationAndWhiteboardSnapshotCRUD() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appending(path: "test_v4.sqlite")
        let store = try SessionStore(databaseURL: dbURL)

        #expect(try store.userVersion() == 4)
        #expect(try store.schemaObjectExists(named: "whiteboard_snapshots", type: "table"))

        let sessionId = UUID().uuidString
        let sessionRecord = SessionRecord(
            sessionId: sessionId,
            state: "recording",
            transcriptState: "unavailable",
            createdAtUtc: Int64(Date().timeIntervalSince1970),
            captureStartMonotonicNs: 1000
        )
        try store.insertSession(sessionRecord)

        let snapshot = WhiteboardSnapshot(
            snapshotId: "snap_001",
            sessionId: sessionId,
            elementsJSON: "[{\"id\":\"node_1\",\"type\":\"rectangle\"}]",
            appStateJSON: "{\"viewBackgroundColor\":\"#ffffff\"}"
        )

        try store.saveWhiteboardSnapshot(snapshot)

        let fetched = try store.fetchWhiteboardSnapshot(sessionId: sessionId)
        #expect(fetched != nil)
        #expect(fetched?.snapshotId == "snap_001")
        #expect(fetched?.sessionId == sessionId)
        #expect(fetched?.elementsJSON.contains("node_1") == true)
        #expect(try store.count(in: "whiteboard_snapshots") == 1)

        // Test delete whiteboard snapshot
        try store.deleteWhiteboardSnapshot(sessionId: sessionId)
        let fetchedAfterDelete = try store.fetchWhiteboardSnapshot(sessionId: sessionId)
        #expect(fetchedAfterDelete == nil)

        // Test Cascade delete when session is deleted
        try store.saveWhiteboardSnapshot(snapshot)
        #expect(try store.count(in: "whiteboard_snapshots") == 1)

        try store.beginDeleting(sessionId: sessionId)
        try store.finishDeleting(sessionId: sessionId)
        #expect(try store.count(in: "whiteboard_snapshots") == 0)
    }
}
