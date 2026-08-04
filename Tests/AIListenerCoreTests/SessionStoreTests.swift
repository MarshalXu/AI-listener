import CSQLite
import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct SessionStoreTests {
    private func databaseURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "session.sqlite")
    }

    private func isolatedDatabase() throws -> (URL, SessionStore) {
        let url = try databaseURL()
        return (url, try SessionStore(databaseURL: url))
    }

    private func session(id: String = UUID().uuidString) -> SessionRecord {
        .init(
            sessionId: id, state: "recording", transcriptState: "unavailable",
            createdAtUtc: 1, captureStartMonotonicNs: 2
        )
    }

    private func createV1Fixture(at url: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE sessions (
          contract_version TEXT NOT NULL, session_id TEXT PRIMARY KEY, state TEXT NOT NULL,
          transcript_state TEXT NOT NULL, created_at_utc INTEGER NOT NULL,
          capture_start_monotonic_ns INTEGER NOT NULL, last_event_sequence INTEGER NOT NULL,
          schema_version INTEGER NOT NULL, ended_at_utc INTEGER, termination_reason TEXT,
          committed_audio_asset_id TEXT, last_error_id TEXT
        );
        INSERT INTO sessions VALUES (
          'ai-listener.contracts/1.0','00000000-0000-0000-0000-000000000001',
          'recording','unavailable',1,2,0,1,NULL,NULL,NULL,NULL
        );
        PRAGMA user_version = 1;
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func freshInstallAndIdempotentReopen() throws {
        let (url, store) = try isolatedDatabase()
        #expect(try store.userVersion() == SessionStore.schemaVersion)
        #expect(try store.count(in: "sessions") == 0)
        #expect(try store.count(in: "meeting_minutes") == 0)
        #expect(try store.count(in: "whiteboard_snapshots") == 0)
        for index in ["finalized_sequence", "transcript_order", "events_order", "errors_session", "minutes_session_kind", "idx_whiteboard_snapshots_session"] {
            #expect(try store.schemaObjectExists(named: index, type: "index"))
        }
        let reopened = try SessionStore(databaseURL: url)
        #expect(try reopened.userVersion() == SessionStore.schemaVersion)
    }

    @Test func upgradesV1FixtureWithoutLosingData() throws {
        let url = try databaseURL()
        try createV1Fixture(at: url)
        let store = try SessionStore(databaseURL: url)
        #expect(try store.userVersion() == SessionStore.schemaVersion)
        #expect(try store.count(in: "sessions") == 1)
        #expect(try store.count(in: "audio_assets") == 0)
        #expect(try store.count(in: "meeting_minutes") == 0)
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("pre-migration-v1.backup").path
        ))
    }

    @Test func failedMigrationRollsBackAndRetryRecovers() throws {
        let url = try databaseURL()
        try createV1Fixture(at: url)
        #expect(throws: SessionStoreError.migrationFailed(version: 2)) {
            _ = try SessionStore(databaseURL: url, failMigrationAtVersion: 2)
        }
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "SELECT * FROM audio_assets", nil, nil, nil) != SQLITE_OK)
        sqlite3_close(database)
        let recovered = try SessionStore(databaseURL: url)
        #expect(try recovered.userVersion() == SessionStore.schemaVersion)
        #expect(try recovered.count(in: "sessions") == 1)
    }

    @Test func newerSchemaIsRejectedWithoutMutation() throws {
        let url = try databaseURL()
        try createV1Fixture(at: url)
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        #expect(throws: SessionStoreError.migrationFailed(version: 99)) {
            _ = try SessionStore(databaseURL: url)
        }
    }

    @Test func transactionAndContractConstraint() throws {
        let (_, store) = try isolatedDatabase()
        let record = session()
        try store.insertSession(record)
        #expect(throws: SessionStoreError.self) { try store.insertSession(record) }
        #expect(try store.count(in: "sessions") == 1)
    }

    @Test func readyCommitIsAtomicAndRelativePathIsContained() throws {
        let (_, store) = try isolatedDatabase()
        let sessionId = UUID().uuidString
        let assetId = UUID().uuidString
        let ready = SessionRecord(
            sessionId: sessionId, state: "ready", transcriptState: "unavailable",
            createdAtUtc: 1, captureStartMonotonicNs: 2, committedAudioAssetId: assetId
        )
        let invalid = AudioAssetRecord(
            audioAssetId: assetId, sessionId: sessionId, relativePath: "../outside.caf",
            container: "caf", codec: "lpcm", sampleRateHz: 48_000, channelCount: 1,
            durationMs: 10, byteCount: 20, sha256: "abc", commitState: "committed"
        )
        #expect(throws: SessionStoreError.invalidContract("audioAsset")) {
            try store.commitReadySession(ready, asset: invalid)
        }
        #expect(try store.count(in: "sessions") == 0)
        #expect(try store.count(in: "audio_assets") == 0)

        let valid = AudioAssetRecord(
            audioAssetId: assetId, sessionId: sessionId, relativePath: "sessions/a.caf",
            container: "caf", codec: "lpcm", sampleRateHz: 48_000, channelCount: 1,
            durationMs: 10, byteCount: 20, sha256: "abc", commitState: "committed"
        )
        try store.commitReadySession(ready, asset: valid)
        #expect(try store.count(in: "sessions") == 1)
        #expect(try store.count(in: "audio_assets") == 1)
    }

    @Test func eventIsIdempotentAndRejectsOutOfOrderOrCrossSession() throws {
        let (_, store) = try isolatedDatabase()
        let sessionId = UUID().uuidString
        try store.insertSession(session(id: sessionId))
        let event = RecordingEventRecord(
            eventId: UUID().uuidString, sessionId: sessionId, sequence: 1,
            monotonicMs: 3, kind: "stateChanged", correlationId: UUID().uuidString,
            payloadVersion: 1, safeMetadata: nil
        )
        try store.insertRecordingEvent(event)
        try store.insertRecordingEvent(event)
        #expect(try store.count(in: "recording_events") == 1)
        let stale = RecordingEventRecord(
            eventId: UUID().uuidString, sessionId: sessionId, sequence: 1,
            monotonicMs: 4, kind: "captureInterrupted", correlationId: UUID().uuidString,
            payloadVersion: 1, safeMetadata: nil
        )
        #expect(throws: SessionStoreError.invalidContract("eventSequence")) {
            try store.insertRecordingEvent(stale)
        }
        let crossSession = RecordingEventRecord(
            eventId: UUID().uuidString, sessionId: UUID().uuidString, sequence: 2,
            monotonicMs: 5, kind: "stateChanged", correlationId: UUID().uuidString,
            payloadVersion: 1, safeMetadata: nil
        )
        #expect(throws: SessionStoreError.invalidContract("sessionId")) {
            try store.insertRecordingEvent(crossSession)
        }
    }

    @Test func finalizedSegmentIsIdempotentAndRejectsPartialOverlapAndCrossSession() throws {
        let (_, store) = try isolatedDatabase()
        let sessionId = UUID().uuidString
        try store.insertSession(session(id: sessionId))
        let segment = TranscriptSegmentRecord(
            segmentId: UUID().uuidString, sessionId: sessionId, revisionOf: nil,
            status: "finalized", sequence: 1, revision: 0, startMs: 0, endMs: 10,
            text: "hello", createdMonotonicMs: 11, engineId: "fixture",
            engineModelVersion: "1"
        )
        try store.insertTranscriptSegment(segment)
        try store.insertTranscriptSegment(segment)
        #expect(try store.count(in: "transcript_segments") == 1)
        let overlap = TranscriptSegmentRecord(
            segmentId: UUID().uuidString, sessionId: sessionId, revisionOf: nil,
            status: "finalized", sequence: 2, revision: 0, startMs: 5, endMs: 12,
            text: "overlap", createdMonotonicMs: 12, engineId: "fixture",
            engineModelVersion: "1"
        )
        #expect(throws: SessionStoreError.invalidContract("transcriptOrderConflict")) {
            try store.insertTranscriptSegment(overlap)
        }
        let outOfOrder = TranscriptSegmentRecord(
            segmentId: UUID().uuidString, sessionId: sessionId, revisionOf: nil,
            status: "finalized", sequence: 0, revision: 0, startMs: 10, endMs: 20,
            text: "late old sequence", createdMonotonicMs: 13, engineId: "fixture",
            engineModelVersion: "1"
        )
        #expect(throws: SessionStoreError.invalidContract("segmentSequence")) {
            try store.insertTranscriptSegment(outOfOrder)
        }
        let partial = TranscriptSegmentRecord(
            segmentId: UUID().uuidString, sessionId: sessionId, revisionOf: nil,
            status: "partial", sequence: 2, revision: 0, startMs: 10, endMs: 20,
            text: "partial", createdMonotonicMs: 13, engineId: "fixture",
            engineModelVersion: "1"
        )
        #expect(throws: SessionStoreError.invalidContract("partialNotPersistent")) {
            try store.insertTranscriptSegment(partial)
        }
        let crossSession = TranscriptSegmentRecord(
            segmentId: UUID().uuidString, sessionId: UUID().uuidString, revisionOf: nil,
            status: "finalized", sequence: 1, revision: 0, startMs: 20, endMs: 30,
            text: "cross", createdMonotonicMs: 14, engineId: "fixture",
            engineModelVersion: "1"
        )
        #expect(throws: SessionStoreError.self) {
            try store.insertTranscriptSegment(crossSession)
        }
    }

    @Test func errorIsIdempotentAndDatabaseIsRepositoryLocal() throws {
        let (url, store) = try isolatedDatabase()
        let error = ErrorRecord(
            errorId: UUID().uuidString, sessionId: nil, domain: "storage",
            code: "TEST", occurredMonotonicMs: 1, recoverable: true,
            userAction: "retrySave", correlationId: UUID().uuidString,
            underlyingSafeCode: "fixture"
        )
        try store.insertError(error)
        try store.insertError(error)
        #expect(try store.count(in: "errors") == 1)
        #expect(url.path.contains("/.test-artifacts/"))
    }

    @Test func meetingMinutesPersistenceAndCRUD() throws {
        let (_, store) = try isolatedDatabase()
        let sessionId = UUID().uuidString
        try store.insertSession(session(id: sessionId))

        let minutes = MeetingMinutes(
            sessionId: sessionId,
            kind: .postSession,
            style: .standard,
            overview: MeetingOverview(
                title: "Test Meeting",
                durationMs: 60000,
                participantSummary: "Alice & Bob",
                generalSummary: "A productive discussion."
            ),
            coreSummary: ["Core summary 1"],
            topics: [MinutesTopic(title: "Topic 1", summary: "Summary 1", keyPoints: ["Key 1"])],
            decisions: ["Decision 1"],
            actionItems: [ActionItem(task: "Task 1", assignee: "Alice", dueDate: "Tomorrow", timestampMs: 1000)],
            unresolvedQuestions: ["Question 1"],
            timestampReferences: [TimestampReference(text: "Quote 1", startMs: 1000, endMs: 2000, label: "Ref 1")]
        )

        try store.saveMeetingMinutes(minutes)
        #expect(try store.count(in: "meeting_minutes") == 1)

        let fetched = try store.fetchMeetingMinutes(sessionId: sessionId)
        #expect(fetched != nil)
        #expect(fetched?.sessionId == sessionId)
        #expect(fetched?.overview.title == "Test Meeting")
        #expect(fetched?.actionItems.first?.assignee == "Alice")

        try store.deleteMeetingMinutes(sessionId: sessionId)
        #expect(try store.count(in: "meeting_minutes") == 0)
    }

    // MARK: - XUC-9: LocalizedError surfaces real sqlite code/message

    /// `SessionStoreError` must conform to `LocalizedError` so that
    /// `localizedDescription` exposes the real sqlite code+message instead of
    /// the misleading "error 0." (case ordinal) the bug report showed. Before
    /// the fix, a FOREIGN KEY failure (sqlite code 19) was masked as
    /// `error 0.` because Swift's default `localizedDescription` for a raw
    /// Error enum uses the case index.
    @Test func sessionStoreErrorLocalizedDescriptionExposesRealCode() {
        let err = SessionStoreError.sqlite(code: 19, message: "FOREIGN KEY constraint failed")
        // localizedDescription routes through errorDescription when present.
        #expect(err.localizedDescription.contains("19"))
        #expect(err.localizedDescription.contains("FOREIGN KEY constraint failed"))

        // Non-sqlite cases must also produce a human-readable description,
        // not the opaque "error N." ordinal form.
        let migration = SessionStoreError.migrationFailed(version: 2)
        #expect(migration.localizedDescription.contains("2"))

        let contract = SessionStoreError.invalidContract("sessionId")
        #expect(contract.localizedDescription.contains("sessionId"))
    }
}
