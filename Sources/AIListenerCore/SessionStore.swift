import CSQLite
import Foundation

public enum SessionStoreError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    case migrationFailed(version: Int)
    case invalidContract(String)
}

public struct SessionRecord: Sendable, Equatable {
    public static let contractVersion = "ai-listener.contracts/1.0"
    public let sessionId: String
    public let state: String
    public let transcriptState: String
    public let createdAtUtc: Int64
    public let captureStartMonotonicNs: Int64
    public let lastEventSequence: Int64
    public let endedAtUtc: Int64?
    public let terminationReason: String?
    public let committedAudioAssetId: String?
    public let lastErrorId: String?

    public init(
        sessionId: String, state: String, transcriptState: String,
        createdAtUtc: Int64, captureStartMonotonicNs: Int64,
        lastEventSequence: Int64 = 0, endedAtUtc: Int64? = nil,
        terminationReason: String? = nil, committedAudioAssetId: String? = nil,
        lastErrorId: String? = nil
    ) {
        self.sessionId = sessionId
        self.state = state
        self.transcriptState = transcriptState
        self.createdAtUtc = createdAtUtc
        self.captureStartMonotonicNs = captureStartMonotonicNs
        self.lastEventSequence = lastEventSequence
        self.endedAtUtc = endedAtUtc
        self.terminationReason = terminationReason
        self.committedAudioAssetId = committedAudioAssetId
        self.lastErrorId = lastErrorId
    }
}

public struct AudioAssetRecord: Sendable, Equatable {
    public let audioAssetId: String
    public let sessionId: String
    public let relativePath: String
    public let container: String
    public let codec: String
    public let sampleRateHz: Int64
    public let channelCount: Int64
    public let durationMs: Int64
    public let byteCount: Int64
    public let sha256: String
    public let commitState: String

    public init(
        audioAssetId: String, sessionId: String, relativePath: String,
        container: String, codec: String, sampleRateHz: Int64,
        channelCount: Int64, durationMs: Int64, byteCount: Int64,
        sha256: String, commitState: String
    ) {
        self.audioAssetId = audioAssetId
        self.sessionId = sessionId
        self.relativePath = relativePath
        self.container = container
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.durationMs = durationMs
        self.byteCount = byteCount
        self.sha256 = sha256
        self.commitState = commitState
    }
}

public struct CommittedAudioIntegrityRecord: Sendable, Equatable {
    public let session: SessionRecord
    public let asset: AudioAssetRecord
}

public struct SessionListItem: Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let createdAtUtc: Int64
    public let endedAtUtc: Int64?
    public let durationMs: Int64
    public let transcriptState: String
    public let previewText: String?
}

public struct SessionDetail: Sendable, Equatable {
    public let session: SessionRecord
    public let asset: AudioAssetRecord
    public let segments: [TranscriptSegmentRecord]
}

public struct TranscriptSegmentRecord: Sendable, Equatable {
    public let segmentId: String
    public let sessionId: String
    public let revisionOf: String?
    public let status: String
    public let sequence: Int64
    public let revision: Int64
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let createdMonotonicMs: Int64
    public let engineId: String
    public let engineModelVersion: String

    public init(
        segmentId: String,
        sessionId: String,
        revisionOf: String? = nil,
        status: String,
        sequence: Int64,
        revision: Int64 = 0,
        startMs: Int64,
        endMs: Int64,
        text: String,
        createdMonotonicMs: Int64,
        engineId: String,
        engineModelVersion: String
    ) {
        self.segmentId = segmentId
        self.sessionId = sessionId
        self.revisionOf = revisionOf
        self.status = status
        self.sequence = sequence
        self.revision = revision
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.createdMonotonicMs = createdMonotonicMs
        self.engineId = engineId
        self.engineModelVersion = engineModelVersion
    }
}

public struct RecordingEventRecord: Sendable, Equatable {
    public let eventId: String
    public let sessionId: String
    public let sequence: Int64
    public let monotonicMs: Int64
    public let kind: String
    public let correlationId: String
    public let payloadVersion: Int64
    public let safeMetadata: String?
}

public struct ErrorRecord: Sendable, Equatable {
    public let errorId: String
    public let sessionId: String?
    public let domain: String
    public let code: String
    public let occurredMonotonicMs: Int64
    public let recoverable: Bool
    public let userAction: String
    public let correlationId: String
    public let underlyingSafeCode: String?
}

public final class SessionStore: @unchecked Sendable {
    public static let schemaVersion = 4
    private var database: OpaquePointer?

    public init(databaseURL: URL, failMigrationAtVersion: Int? = nil) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SessionStoreError.sqlite(code: SQLITE_CANTOPEN, message: message)
        }
        database = handle
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try migrate(databaseURL: databaseURL, failAtVersion: failMigrationAtVersion)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func insertSession(_ session: SessionRecord) throws {
        try validate(session)
        try transaction {
            try insertSessionStatement(session)
        }
    }

    public func commitReadySession(_ session: SessionRecord, asset: AudioAssetRecord) throws {
        guard ["ready", "recovered"].contains(session.state),
              session.committedAudioAssetId == asset.audioAssetId,
              asset.sessionId == session.sessionId,
              asset.commitState == "committed" else {
            throw SessionStoreError.invalidContract("readyAsset")
        }
        try validate(session)
        try validate(asset)
        try transaction {
            let pending = SessionRecord(
                sessionId: session.sessionId, state: "finalizing",
                transcriptState: session.transcriptState, createdAtUtc: session.createdAtUtc,
                captureStartMonotonicNs: session.captureStartMonotonicNs,
                lastEventSequence: session.lastEventSequence, endedAtUtc: session.endedAtUtc,
                terminationReason: session.terminationReason
            )
            if try scalarInt(
                "SELECT COUNT(*) FROM sessions WHERE session_id = ?", [.text(session.sessionId)]
            ) == 0 {
                try insertSessionStatement(pending)
            } else {
                try execute(
                    """
                    UPDATE sessions SET state = 'finalizing', transcript_state = ?,
                      ended_at_utc = ?, termination_reason = ?
                    WHERE session_id = ?
                    """,
                    [
                        .text(session.transcriptState), .optionalInteger(session.endedAtUtc),
                        .optionalText(session.terminationReason), .text(session.sessionId),
                    ]
                )
            }
            if try scalarInt(
                "SELECT COUNT(*) FROM audio_assets WHERE audio_asset_id = ?",
                [.text(asset.audioAssetId)]
            ) == 0 {
                try insertAssetStatement(asset)
            } else {
                let matches = try scalarInt(
                    """
                    SELECT COUNT(*) FROM audio_assets
                    WHERE audio_asset_id = ? AND session_id = ? AND relative_path = ?
                      AND byte_count = ? AND sha256 = ? AND commit_state = 'committed'
                    """,
                    [
                        .text(asset.audioAssetId), .text(asset.sessionId),
                        .text(asset.relativePath), .integer(asset.byteCount), .text(asset.sha256),
                    ]
                )
                guard matches == 1 else {
                    throw SessionStoreError.invalidContract("audioAssetConflict")
                }
            }
            try execute(
                "UPDATE sessions SET state = ?, committed_audio_asset_id = ? WHERE session_id = ?",
                [.text(session.state), .text(asset.audioAssetId), .text(session.sessionId)]
            )
        }
    }

    public func committedAssetMatches(
        sessionId: String, audioAssetId: String, relativePath: String,
        byteCount: Int64, sha256: String
    ) throws -> Bool {
        try scalarInt(
            """
            SELECT COUNT(*) FROM sessions s JOIN audio_assets a
              ON a.audio_asset_id = s.committed_audio_asset_id
            WHERE s.session_id = ? AND a.audio_asset_id = ? AND a.relative_path = ?
              AND a.byte_count = ? AND a.sha256 = ? AND a.commit_state = 'committed'
              AND s.state IN ('ready','recovered')
            """,
            [
                .text(sessionId), .text(audioAssetId), .text(relativePath),
                .integer(byteCount), .text(sha256),
            ]
        ) == 1
    }

    public func markRecoveryRequired(_ session: SessionRecord) throws {
        let recovery = SessionRecord(
            sessionId: session.sessionId, state: "recoveryRequired",
            transcriptState: session.transcriptState, createdAtUtc: session.createdAtUtc,
            captureStartMonotonicNs: session.captureStartMonotonicNs,
            lastEventSequence: session.lastEventSequence, endedAtUtc: session.endedAtUtc,
            terminationReason: session.terminationReason, lastErrorId: session.lastErrorId
        )
        try validate(recovery)
        try transaction {
            if try scalarInt(
                "SELECT COUNT(*) FROM sessions WHERE session_id = ?", [.text(session.sessionId)]
            ) == 0 {
                try insertSessionStatement(recovery)
            } else {
                try execute(
                    """
                    UPDATE sessions SET state = 'recoveryRequired',
                      committed_audio_asset_id = NULL WHERE session_id = ?
                    """,
                    [.text(session.sessionId)]
                )
            }
        }
    }

    public func markFailed(_ session: SessionRecord) throws {
        try transaction {
            try execute(
                """
                UPDATE sessions SET state = 'failed', committed_audio_asset_id = NULL,
                  termination_reason = ? WHERE session_id = ?
                """,
                [.optionalText(session.terminationReason), .text(session.sessionId)]
            )
        }
    }

    public func sessionState(sessionId: String) throws -> String? {
        try scalarText("SELECT state FROM sessions WHERE session_id = ?", [.text(sessionId)])
    }

    public func sessionIds(inStates states: [String]) throws -> [String] {
        guard !states.isEmpty, states.allSatisfy({
            ["recording", "interrupted", "finalizing", "ready", "recovered",
             "recoveryRequired", "deleting", "failed"].contains($0)
        }) else {
            throw SessionStoreError.invalidContract("state")
        }
        let placeholders = Array(repeating: "?", count: states.count).joined(separator: ",")
        return try textRows(
            "SELECT session_id FROM sessions WHERE state IN (\(placeholders)) ORDER BY session_id",
            states.map(Binding.text)
        )
    }

    public func referencedAudioPaths() throws -> Set<String> {
        Set(try textRows("SELECT relative_path FROM audio_assets"))
    }

    public func committedAudioIntegrityRecords() throws -> [CommittedAudioIntegrityRecord] {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT s.session_id, s.state, s.transcript_state, s.created_at_utc,
              s.capture_start_monotonic_ns, s.last_event_sequence, s.ended_at_utc,
              s.termination_reason, s.committed_audio_asset_id, s.last_error_id,
              a.audio_asset_id, a.relative_path, a.container, a.codec, a.sample_rate_hz,
              a.channel_count, a.duration_ms, a.byte_count, a.sha256, a.commit_state
            FROM sessions s JOIN audio_assets a
              ON a.audio_asset_id = s.committed_audio_asset_id
            WHERE s.state IN ('ready','recovered') AND a.commit_state = 'committed'
            ORDER BY s.session_id
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        var records: [CommittedAudioIntegrityRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func textColumn(_ index: Int32) -> String {
                String(cString: sqlite3_column_text(statement, index))
            }
            func optionalTextColumn(_ index: Int32) -> String? {
                guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
                return textColumn(index)
            }
            func optionalIntColumn(_ index: Int32) -> Int64? {
                guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
                return sqlite3_column_int64(statement, index)
            }
            let sessionId = textColumn(0)
            records.append(CommittedAudioIntegrityRecord(
                session: SessionRecord(
                    sessionId: sessionId, state: textColumn(1),
                    transcriptState: textColumn(2),
                    createdAtUtc: sqlite3_column_int64(statement, 3),
                    captureStartMonotonicNs: sqlite3_column_int64(statement, 4),
                    lastEventSequence: sqlite3_column_int64(statement, 5),
                    endedAtUtc: optionalIntColumn(6),
                    terminationReason: optionalTextColumn(7),
                    committedAudioAssetId: optionalTextColumn(8),
                    lastErrorId: optionalTextColumn(9)
                ),
                asset: AudioAssetRecord(
                    audioAssetId: textColumn(10), sessionId: sessionId,
                    relativePath: textColumn(11), container: textColumn(12),
                    codec: textColumn(13),
                    sampleRateHz: sqlite3_column_int64(statement, 14),
                    channelCount: sqlite3_column_int64(statement, 15),
                    durationMs: sqlite3_column_int64(statement, 16),
                    byteCount: sqlite3_column_int64(statement, 17),
                    sha256: textColumn(18), commitState: textColumn(19)
                )
            ))
        }
        return records
    }

    /// Returns only sessions whose audio has completed the repository commit protocol.
    public func listPlayableSessions() throws -> [SessionListItem] {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT s.session_id, s.created_at_utc, s.ended_at_utc, a.duration_ms,
              s.transcript_state,
              (SELECT text FROM transcript_segments t
               WHERE t.session_id = s.session_id AND t.status = 'finalized'
               ORDER BY t.start_ms, t.sequence LIMIT 1)
            FROM sessions s JOIN audio_assets a
              ON a.audio_asset_id = s.committed_audio_asset_id
            WHERE s.state IN ('ready','recovered') AND a.commit_state = 'committed'
            ORDER BY s.created_at_utc DESC, s.session_id
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        var items: [SessionListItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(SessionListItem(
                sessionId: requiredText(statement, 0),
                createdAtUtc: sqlite3_column_int64(statement, 1),
                endedAtUtc: optionalInteger(statement, 2),
                durationMs: sqlite3_column_int64(statement, 3),
                transcriptState: requiredText(statement, 4),
                previewText: optionalText(statement, 5)
            ))
        }
        return items
    }

    /// Rehydrates the committed audio reference and finalized transcript truth view.
    public func playableSession(sessionId: String) throws -> SessionDetail? {
        guard UUID(uuidString: sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }
        let records = try committedAudioIntegrityRecords()
        guard let record = records.first(where: { $0.session.sessionId == sessionId }) else {
            return nil
        }
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT segment_id, session_id, revision_of, status, sequence, revision,
              start_ms, end_ms, text, created_monotonic_ms, engine_id, engine_model_version
            FROM transcript_segments
            WHERE session_id = ? AND status = 'finalized'
            ORDER BY start_ms, sequence
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(sessionId)], to: statement)
        var segments: [TranscriptSegmentRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            segments.append(TranscriptSegmentRecord(
                segmentId: requiredText(statement, 0),
                sessionId: requiredText(statement, 1),
                revisionOf: optionalText(statement, 2),
                status: requiredText(statement, 3),
                sequence: sqlite3_column_int64(statement, 4),
                revision: sqlite3_column_int64(statement, 5),
                startMs: sqlite3_column_int64(statement, 6),
                endMs: sqlite3_column_int64(statement, 7),
                text: requiredText(statement, 8),
                createdMonotonicMs: sqlite3_column_int64(statement, 9),
                engineId: requiredText(statement, 10),
                engineModelVersion: requiredText(statement, 11)
            ))
        }
        return SessionDetail(session: record.session, asset: record.asset, segments: segments)
    }

    public func markCommittedAssetRecoveryRequired(session: SessionRecord) throws {
        try transaction {
            try execute(
                """
                UPDATE sessions SET state = 'recoveryRequired',
                  committed_audio_asset_id = NULL WHERE session_id = ?
                """,
                [.text(session.sessionId)]
            )
            try execute(
                """
                UPDATE audio_assets SET commit_state = 'quarantined'
                WHERE session_id = ? AND commit_state = 'committed'
                """,
                [.text(session.sessionId)]
            )
        }
    }

    public func audioPathForDeletion(sessionId: String) throws -> String? {
        try scalarText(
            """
            SELECT a.relative_path FROM sessions s JOIN audio_assets a
              ON a.audio_asset_id = s.committed_audio_asset_id
            WHERE s.session_id = ?
            """,
            [.text(sessionId)]
        )
    }

    public func beginDeleting(sessionId: String) throws {
        try transaction {
            let count = try scalarInt(
                "SELECT COUNT(*) FROM sessions WHERE session_id = ?", [.text(sessionId)]
            )
            guard count == 1 else { throw SessionStoreError.invalidContract("sessionId") }
            try execute(
                "UPDATE sessions SET state = 'deleting' WHERE session_id = ?",
                [.text(sessionId)]
            )
            try execute(
                """
                UPDATE audio_assets SET commit_state = 'deleting'
                WHERE audio_asset_id = (
                  SELECT committed_audio_asset_id FROM sessions WHERE session_id = ?
                )
                """,
                [.text(sessionId)]
            )
        }
    }

    public func finishDeleting(sessionId: String) throws {
        try transaction {
            try execute(
                "DELETE FROM sessions WHERE session_id = ? AND state = 'deleting'",
                [.text(sessionId)]
            )
        }
    }

    public func insertAudioAsset(_ asset: AudioAssetRecord) throws {
        try validate(asset)
        try transaction { try insertAssetStatement(asset) }
    }

    public func insertTranscriptSegment(_ segment: TranscriptSegmentRecord) throws {
        guard segment.status != "partial" else {
            throw SessionStoreError.invalidContract("partialNotPersistent")
        }
        try transaction {
            let existing = try scalarInt(
                "SELECT COUNT(*) FROM transcript_segments WHERE segment_id = ? AND revision = ?",
                [.text(segment.segmentId), .integer(segment.revision)]
            )
            if existing == 1 { return }
            if segment.status == "finalized" {
                let lastSequence = try scalarInt(
                    """
                    SELECT COALESCE(MAX(sequence), -1) FROM transcript_segments
                    WHERE session_id = ? AND status = 'finalized'
                    """,
                    [.text(segment.sessionId)]
                )
                guard segment.sequence > lastSequence else {
                    throw SessionStoreError.invalidContract("segmentSequence")
                }
                let overlap = try scalarInt(
                    """
                    SELECT COUNT(*) FROM transcript_segments
                    WHERE session_id = ? AND status = 'finalized'
                      AND NOT (? <= start_ms OR ? >= end_ms)
                    """,
                    [.text(segment.sessionId), .integer(segment.endMs), .integer(segment.startMs)]
                )
                guard overlap == 0 else {
                    throw SessionStoreError.invalidContract("transcriptOrderConflict")
                }
            }
            try execute(
                """
                INSERT OR IGNORE INTO transcript_segments (
                  contract_version, segment_id, session_id, revision_of, status, sequence,
                  revision, start_ms, end_ms, text, created_monotonic_ms, engine_id,
                  engine_model_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(SessionRecord.contractVersion), .text(segment.segmentId),
                    .text(segment.sessionId), .optionalText(segment.revisionOf),
                    .text(segment.status), .integer(segment.sequence), .integer(segment.revision),
                    .integer(segment.startMs), .integer(segment.endMs), .text(segment.text),
                    .integer(segment.createdMonotonicMs), .text(segment.engineId),
                    .text(segment.engineModelVersion),
                ]
            )
        }
    }

    public func transcriptSegmentCount(sessionId: String) throws -> Int {
        try scalarInt(
            "SELECT COUNT(*) FROM transcript_segments WHERE session_id = ?",
            [.text(sessionId)]
        )
    }

    public func insertRecordingEvent(_ event: RecordingEventRecord) throws {
        try transaction {
            let last = try scalarInt(
                "SELECT last_event_sequence FROM sessions WHERE session_id = ?",
                [.text(event.sessionId)]
            )
            guard last >= 0 else { throw SessionStoreError.invalidContract("sessionId") }
            let existing = try scalarInt(
                "SELECT COUNT(*) FROM recording_events WHERE event_id = ?",
                [.text(event.eventId)]
            )
            if existing == 1 { return }
            guard event.sequence > last else {
                throw SessionStoreError.invalidContract("eventSequence")
            }
            try execute(
                """
                INSERT INTO recording_events (
                  contract_version, event_id, session_id, sequence, monotonic_ms, kind,
                  correlation_id, payload_version, safe_metadata
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(SessionRecord.contractVersion), .text(event.eventId),
                    .text(event.sessionId), .integer(event.sequence), .integer(event.monotonicMs),
                    .text(event.kind), .text(event.correlationId),
                    .integer(event.payloadVersion), .optionalText(event.safeMetadata),
                ]
            )
            try execute(
                "UPDATE sessions SET last_event_sequence = ? WHERE session_id = ?",
                [.integer(event.sequence), .text(event.sessionId)]
            )
        }
    }

    public func insertError(_ error: ErrorRecord) throws {
        try transaction {
            try execute(
                """
                INSERT OR IGNORE INTO errors (
                  contract_version, error_id, session_id, domain, code,
                  occurred_monotonic_ms, recoverable, user_action, correlation_id,
                  underlying_safe_code
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(SessionRecord.contractVersion), .text(error.errorId),
                    .optionalText(error.sessionId), .text(error.domain), .text(error.code),
                    .integer(error.occurredMonotonicMs), .integer(error.recoverable ? 1 : 0),
                    .text(error.userAction), .text(error.correlationId),
                    .optionalText(error.underlyingSafeCode),
                ]
            )
        }
    }

    public func saveMeetingMinutes(_ minutes: MeetingMinutes) throws {
        guard UUID(uuidString: minutes.minutesId) != nil,
              UUID(uuidString: minutes.sessionId) != nil else {
            throw SessionStoreError.invalidContract("meetingMinutesId")
        }

        let encoder = JSONEncoder()
        guard let jsonString = String(data: try encoder.encode(minutes), encoding: .utf8) else {
            throw SessionStoreError.invalidContract("jsonEncoding")
        }

        try transaction {
            try execute(
                """
                INSERT OR REPLACE INTO meeting_minutes (
                  contract_version, minutes_id, session_id, minutes_kind, style,
                  summary_json, created_at_utc, updated_at_utc
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(SessionRecord.contractVersion), .text(minutes.minutesId),
                    .text(minutes.sessionId), .text(minutes.kind.rawValue),
                    .text(minutes.style.rawValue), .text(jsonString),
                    .integer(minutes.createdAtUtc), .integer(minutes.updatedAtUtc)
                ]
            )
        }
    }

    public func fetchMeetingMinutes(sessionId: String, kind: MeetingMinutes.MinutesKind? = nil) throws -> MeetingMinutes? {
        guard UUID(uuidString: sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }

        let sql: String
        let bindings: [Binding]
        if let kind = kind {
            sql = "SELECT summary_json FROM meeting_minutes WHERE session_id = ? AND minutes_kind = ? ORDER BY updated_at_utc DESC LIMIT 1"
            bindings = [.text(sessionId), .text(kind.rawValue)]
        } else {
            sql = "SELECT summary_json FROM meeting_minutes WHERE session_id = ? ORDER BY updated_at_utc DESC LIMIT 1"
            bindings = [.text(sessionId)]
        }

        guard let jsonString = try scalarText(sql, bindings),
              let jsonData = jsonString.data(using: .utf8) else {
            return nil
        }

        return try JSONDecoder().decode(MeetingMinutes.self, from: jsonData)
    }

    public func deleteMeetingMinutes(sessionId: String) throws {
        guard UUID(uuidString: sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }

        try transaction {
            try execute("DELETE FROM meeting_minutes WHERE session_id = ?", [.text(sessionId)])
        }
    }

    public func saveWhiteboardSnapshot(_ snapshot: WhiteboardSnapshot) throws {
        guard UUID(uuidString: snapshot.sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }

        try transaction {
            try execute(
                """
                INSERT OR REPLACE INTO whiteboard_snapshots (
                  contract_version, snapshot_id, session_id, elements_json,
                  app_state_json, created_at_utc, updated_at_utc
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(SessionRecord.contractVersion), .text(snapshot.snapshotId),
                    .text(snapshot.sessionId), .text(snapshot.elementsJSON),
                    .text(snapshot.appStateJSON), .integer(snapshot.createdAtUTC),
                    .integer(snapshot.updatedAtUTC)
                ]
            )
        }
    }

    public func fetchWhiteboardSnapshot(sessionId: String) throws -> WhiteboardSnapshot? {
        guard UUID(uuidString: sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }

        let sql = """
            SELECT snapshot_id, session_id, elements_json, app_state_json, created_at_utc, updated_at_utc
            FROM whiteboard_snapshots
            WHERE session_id = ?
            ORDER BY updated_at_utc DESC LIMIT 1
            """

        guard let database else {
            throw SessionStoreError.sqlite(code: SQLITE_MISUSE, message: "closed")
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionStoreError.sqlite(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (sessionId as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) == SQLITE_ROW {
            let snapshotId = String(cString: sqlite3_column_text(statement, 0))
            let sessId = String(cString: sqlite3_column_text(statement, 1))
            let elementsJSON = String(cString: sqlite3_column_text(statement, 2))
            let appStateJSON = String(cString: sqlite3_column_text(statement, 3))
            let createdAtUTC = sqlite3_column_int64(statement, 4)
            let updatedAtUTC = sqlite3_column_int64(statement, 5)

            return WhiteboardSnapshot(
                snapshotId: snapshotId,
                sessionId: sessId,
                elementsJSON: elementsJSON,
                appStateJSON: appStateJSON,
                createdAtUTC: createdAtUTC,
                updatedAtUTC: updatedAtUTC
            )
        }

        return nil
    }

    public func deleteWhiteboardSnapshot(sessionId: String) throws {
        guard UUID(uuidString: sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }

        try transaction {
            try execute("DELETE FROM whiteboard_snapshots WHERE session_id = ?", [.text(sessionId)])
        }
    }

    public func count(in table: String) throws -> Int {
        let allowed = ["sessions", "audio_assets", "transcript_segments", "recording_events", "errors", "meeting_minutes", "whiteboard_snapshots"]
        guard allowed.contains(table) else { throw SessionStoreError.invalidContract("table") }
        return try scalarInt("SELECT COUNT(*) FROM \(table)")
    }

    public func schemaObjectExists(named name: String, type: String) throws -> Bool {
        guard ["table", "index"].contains(type) else {
            throw SessionStoreError.invalidContract("schemaObjectType")
        }
        return try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = ? AND name = ?",
            [.text(type), .text(name)]
        ) == 1
    }

    public func userVersion() throws -> Int {
        try scalarInt("PRAGMA user_version")
    }

    private func migrate(databaseURL: URL, failAtVersion: Int?) throws {
        let current = try userVersion()
        guard current <= Self.schemaVersion else {
            throw SessionStoreError.migrationFailed(version: current)
        }
        guard current < Self.schemaVersion else { return }
        if current > 0 {
            try createMigrationBackup(
                at: databaseURL.appendingPathExtension("pre-migration-v\(current).backup")
            )
        }
        for version in (current + 1)...Self.schemaVersion {
            do {
                try transaction {
                    if failAtVersion == version {
                        throw SessionStoreError.migrationFailed(version: version)
                    }
                    if version == 1 {
                        try execute(Self.schemaV1)
                    } else if version == 2 {
                        try execute(Self.schemaV2)
                    } else if version == 3 {
                        try execute(Self.schemaV3)
                    } else if version == 4 {
                        try execute(Self.schemaV4)
                    }
                    try execute("PRAGMA user_version = \(version)")
                }
            } catch {
                throw error
            }
        }
    }

    private func createMigrationBackup(at url: URL) throws {
        guard let database else {
            throw SessionStoreError.sqlite(code: SQLITE_MISUSE, message: "closed")
        }
        var backupDatabase: OpaquePointer?
        guard sqlite3_open_v2(url.path, &backupDatabase, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let backupDatabase else {
            if let backupDatabase { sqlite3_close(backupDatabase) }
            throw SessionStoreError.sqlite(code: SQLITE_CANTOPEN, message: "migration backup open failed")
        }
        defer { sqlite3_close(backupDatabase) }
        guard let backup = sqlite3_backup_init(backupDatabase, "main", database, "main") else {
            throw SessionStoreError.sqlite(
                code: sqlite3_errcode(backupDatabase),
                message: String(cString: sqlite3_errmsg(backupDatabase))
            )
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw SessionStoreError.sqlite(
                code: sqlite3_errcode(backupDatabase),
                message: String(cString: sqlite3_errmsg(backupDatabase))
            )
        }
    }

    private func validate(_ session: SessionRecord) throws {
        let states = ["recording", "interrupted", "finalizing", "ready", "recovered", "recoveryRequired", "deleting", "failed"]
        let transcriptStates = ["unavailable", "active", "degraded", "finalized", "partialOnly"]
        guard UUID(uuidString: session.sessionId) != nil else {
            throw SessionStoreError.invalidContract("sessionId")
        }
        guard states.contains(session.state), transcriptStates.contains(session.transcriptState) else {
            throw SessionStoreError.invalidContract("state")
        }
        if ["ready", "recovered"].contains(session.state), session.committedAudioAssetId == nil {
            throw SessionStoreError.invalidContract("committedAudioAssetId")
        }
    }

    private func validate(_ asset: AudioAssetRecord) throws {
        guard UUID(uuidString: asset.audioAssetId) != nil,
              UUID(uuidString: asset.sessionId) != nil,
              !asset.relativePath.isEmpty,
              !asset.relativePath.hasPrefix("/"),
              !asset.relativePath.split(separator: "/").contains(".."),
              asset.channelCount == 1,
              asset.sampleRateHz > 0,
              asset.durationMs >= 0,
              asset.byteCount >= 0 else {
            throw SessionStoreError.invalidContract("audioAsset")
        }
    }

    private func insertSessionStatement(_ session: SessionRecord) throws {
        try execute(
            """
            INSERT INTO sessions (
              contract_version, session_id, state, transcript_state, created_at_utc,
              capture_start_monotonic_ns, last_event_sequence, schema_version,
              ended_at_utc, termination_reason, committed_audio_asset_id, last_error_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(SessionRecord.contractVersion), .text(session.sessionId),
                .text(session.state), .text(session.transcriptState),
                .integer(session.createdAtUtc), .integer(session.captureStartMonotonicNs),
                .integer(session.lastEventSequence), .integer(Int64(Self.schemaVersion)),
                .optionalInteger(session.endedAtUtc), .optionalText(session.terminationReason),
                .optionalText(session.committedAudioAssetId), .optionalText(session.lastErrorId),
            ]
        )
    }

    private func insertAssetStatement(_ asset: AudioAssetRecord) throws {
        try execute(
            """
            INSERT INTO audio_assets (
              contract_version, audio_asset_id, session_id, relative_path, container, codec,
              sample_rate_hz, channel_count, duration_ms, byte_count, sha256, commit_state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(SessionRecord.contractVersion), .text(asset.audioAssetId),
                .text(asset.sessionId), .text(asset.relativePath), .text(asset.container),
                .text(asset.codec), .integer(asset.sampleRateHz), .integer(asset.channelCount),
                .integer(asset.durationMs), .integer(asset.byteCount), .text(asset.sha256),
                .text(asset.commitState),
            ]
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private enum Binding {
        case integer(Int64), text(String), null
        static func optionalInteger(_ value: Int64?) -> Self { value.map(Self.integer) ?? .null }
        static func optionalText(_ value: String?) -> Self { value.map(Self.text) ?? .null }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(
                    statement, index, value, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
    }

    private func requiredText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return requiredText(statement, index)
    }

    private func optionalInteger(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        if bindings.isEmpty {
            guard let database else { throw SessionStoreError.sqlite(code: SQLITE_MISUSE, message: "closed") }
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw currentError() }
            return
        }
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func scalarInt(_ sql: String, _ bindings: [Binding] = []) throws -> Int {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func scalarText(_ sql: String, _ bindings: [Binding] = []) throws -> String? {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(
                    statement, index, value, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: bytes)
    }

    private func textRows(_ sql: String, _ bindings: [Binding] = []) throws -> [String] {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(
                    statement, index, value, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentError() }
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let bytes = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: bytes))
            }
        }
        return rows
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard let database else { throw SessionStoreError.sqlite(code: SQLITE_MISUSE, message: "closed") }
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw currentError() }
    }

    private func currentError() -> SessionStoreError {
        guard let database else { return .sqlite(code: SQLITE_MISUSE, message: "closed") }
        return .sqlite(code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }

    private static let schemaV1 = """
    CREATE TABLE sessions (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      session_id TEXT PRIMARY KEY,
      state TEXT NOT NULL CHECK(state IN ('recording','interrupted','finalizing','ready','recovered','recoveryRequired','deleting','failed')),
      transcript_state TEXT NOT NULL CHECK(transcript_state IN ('unavailable','active','degraded','finalized','partialOnly')),
      created_at_utc INTEGER NOT NULL, capture_start_monotonic_ns INTEGER NOT NULL,
      last_event_sequence INTEGER NOT NULL DEFAULT 0 CHECK(last_event_sequence >= 0),
      schema_version INTEGER NOT NULL, ended_at_utc INTEGER, termination_reason TEXT,
      committed_audio_asset_id TEXT UNIQUE, last_error_id TEXT,
      CHECK(state NOT IN ('ready','recovered') OR committed_audio_asset_id IS NOT NULL)
    );
    """

    private static let schemaV2 = """
    CREATE TABLE audio_assets (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      audio_asset_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL UNIQUE REFERENCES sessions(session_id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL CHECK(relative_path NOT LIKE '/%' AND relative_path NOT LIKE '%..%'),
      container TEXT NOT NULL, codec TEXT NOT NULL,
      sample_rate_hz INTEGER NOT NULL CHECK(sample_rate_hz > 0),
      channel_count INTEGER NOT NULL CHECK(channel_count = 1),
      duration_ms INTEGER NOT NULL CHECK(duration_ms >= 0),
      byte_count INTEGER NOT NULL CHECK(byte_count >= 0), sha256 TEXT NOT NULL,
      commit_state TEXT NOT NULL CHECK(commit_state IN ('temporary','stable','committed','quarantined','deleting'))
    );
    CREATE TABLE transcript_segments (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      segment_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
      revision_of TEXT REFERENCES transcript_segments(segment_id),
      status TEXT NOT NULL CHECK(status IN ('finalized','retracted')),
      sequence INTEGER NOT NULL CHECK(sequence >= 0),
      revision INTEGER NOT NULL CHECK(revision >= 0),
      start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
      text TEXT NOT NULL CHECK(length(trim(text)) > 0),
      created_monotonic_ms INTEGER NOT NULL, engine_id TEXT NOT NULL,
      engine_model_version TEXT NOT NULL,
      UNIQUE(segment_id, revision), CHECK(start_ms >= 0 AND start_ms < end_ms)
    );
    CREATE UNIQUE INDEX finalized_sequence
      ON transcript_segments(session_id, sequence) WHERE status = 'finalized';
    CREATE INDEX transcript_order ON transcript_segments(session_id, start_ms, sequence);
    CREATE TABLE recording_events (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      event_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
      sequence INTEGER NOT NULL CHECK(sequence > 0), monotonic_ms INTEGER NOT NULL,
      kind TEXT NOT NULL, correlation_id TEXT NOT NULL, payload_version INTEGER NOT NULL,
      safe_metadata TEXT, UNIQUE(session_id, sequence)
    );
    CREATE TABLE errors (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      error_id TEXT PRIMARY KEY, session_id TEXT REFERENCES sessions(session_id) ON DELETE CASCADE,
      domain TEXT NOT NULL, code TEXT NOT NULL, occurred_monotonic_ms INTEGER NOT NULL,
      recoverable INTEGER NOT NULL CHECK(recoverable IN (0,1)),
      user_action TEXT NOT NULL CHECK(user_action IN ('none','openMicrophoneSettings','retryModel','continueWithoutTranscript','retrySave','retryPlayback','retryDelete')),
      correlation_id TEXT NOT NULL, underlying_safe_code TEXT
    );
    CREATE INDEX events_order ON recording_events(session_id, sequence);
    CREATE INDEX errors_session ON errors(session_id, occurred_monotonic_ms);
    """

    private static let schemaV3 = """
    CREATE TABLE meeting_minutes (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      minutes_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
      minutes_kind TEXT NOT NULL CHECK(minutes_kind IN ('incremental', 'post_session')),
      style TEXT NOT NULL,
      summary_json TEXT NOT NULL,
      created_at_utc INTEGER NOT NULL,
      updated_at_utc INTEGER NOT NULL
    );
    CREATE INDEX minutes_session_kind ON meeting_minutes(session_id, minutes_kind);
    """

    private static let schemaV4 = """
    CREATE TABLE whiteboard_snapshots (
      contract_version TEXT NOT NULL CHECK(contract_version = 'ai-listener.contracts/1.0'),
      snapshot_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
      elements_json TEXT NOT NULL,
      app_state_json TEXT NOT NULL,
      created_at_utc INTEGER NOT NULL,
      updated_at_utc INTEGER NOT NULL
    );
    CREATE INDEX idx_whiteboard_snapshots_session ON whiteboard_snapshots(session_id);
    """
}
