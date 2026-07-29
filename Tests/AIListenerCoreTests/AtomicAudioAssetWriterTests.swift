import AVFoundation
import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct AtomicAudioAssetWriterTests {
    private func fixture() throws -> (URL, SessionStore, SessionRecord, AVAudioFormat) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SessionStore(databaseURL: root.appending(path: "session.sqlite"))
        let session = SessionRecord(
            sessionId: UUID().uuidString, state: "recording", transcriptState: "unavailable",
            createdAtUtc: 1, captureStartMonotonicNs: 2, endedAtUtc: 3,
            terminationReason: "userStopped"
        )
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
            interleaved: false
        ))
        return (root, store, session, format)
    }

    private func buffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<1_600 {
            samples[index] = sin(Float(index) * 0.05) * 0.1
        }
        return buffer
    }

    @Test func commitsReadableCAFAndDatabaseAtomically() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(assetRoot: root, session: session)
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        let asset = try writer.finalize(into: store)

        #expect(asset.durationMs == 100)
        #expect(asset.byteCount > 0)
        #expect(asset.sha256.count == 64)
        #expect(try store.count(in: "sessions") == 1)
        #expect(try store.count(in: "audio_assets") == 1)
        #expect(!FileManager.default.fileExists(atPath: writer.manifestURL.path))
        let reopened = try AVAudioFile(forReading: writer.stableURL)
        #expect(reopened.length == 1_600)
    }

    @Test(arguments: [
        AudioCommitFailurePoint.audioSync,
        .manifestStablePending,
        .rename,
        .directorySync,
        .databaseCommit,
        .manifestCleanup,
    ])
    func failureNeverPublishesFalseReady(point: AudioCommitFailurePoint) throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [point]
        )
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        #expect(throws: AudioAssetWriterError.self) {
            _ = try writer.finalize(into: store)
        }
        if point != .manifestCleanup {
            #expect(try store.count(in: "sessions") == 0)
            #expect(try store.count(in: "audio_assets") == 0)
        } else {
            #expect(try store.count(in: "sessions") == 1)
            #expect(try store.count(in: "audio_assets") == 1)
        }
        #expect(FileManager.default.fileExists(atPath: writer.manifestURL.path))
    }

    @Test func manifestCreationFailureCreatesNoAudioOrDatabaseRows() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.manifestCreate]
        )
        #expect(throws: AudioAssetWriterError.injected(.manifestCreate)) {
            try writer.begin(format: format)
        }
        #expect(!FileManager.default.fileExists(atPath: writer.temporaryURL.path))
        #expect(try store.count(in: "sessions") == 0)
    }

    @Test func diskFullDuringWriteNeverPublishesReadyAndIsRecoverable() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.diskFullDuringWrite]
        )
        try writer.begin(format: format)
        #expect(throws: AudioAssetWriterError.injected(.diskFullDuringWrite)) {
            try writer.write(buffer(format: format))
        }
        #expect(try store.count(in: "sessions") == 0)
        #expect(try store.count(in: "audio_assets") == 0)
        #expect(FileManager.default.fileExists(atPath: writer.manifestURL.path))

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        #expect(try reconciler.reconcileAll(store: store) == [
            .recoveryRequired(
                sessionId: session.sessionId, reason: "temporaryAwaitingFinalization"
            )
        ])
        #expect(try store.sessionState(sessionId: session.sessionId) == "recoveryRequired")
        #expect(try store.count(in: "audio_assets") == 0)
    }

    @Test func startupRecoveryReplaysStablePendingCommitIdempotently() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.databaseCommit]
        )
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        #expect(throws: AudioAssetWriterError.injected(.databaseCommit)) {
            _ = try writer.finalize(into: store)
        }

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        #expect(try reconciler.reconcileAll(store: store) == [
            .recovered(sessionId: session.sessionId)
        ])
        #expect(try store.sessionState(sessionId: session.sessionId) == "recovered")
        #expect(try store.count(in: "audio_assets") == 1)
        #expect(!FileManager.default.fileExists(atPath: writer.manifestURL.path))
        #expect(try reconciler.reconcileAll(store: store).isEmpty)
    }

    @Test func startupRecoveryCleansManifestAfterCommittedDatabase() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.manifestCleanup]
        )
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        #expect(throws: AudioAssetWriterError.injected(.manifestCleanup)) {
            _ = try writer.finalize(into: store)
        }

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        #expect(try reconciler.reconcileAll(store: store) == [
            .cleanedCommitted(sessionId: session.sessionId)
        ])
        #expect(try store.sessionState(sessionId: session.sessionId) == "ready")
        #expect(!FileManager.default.fileExists(atPath: writer.manifestURL.path))
    }

    @Test func startupRecoveryQuarantinesHashMismatchWithoutReady() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.databaseCommit]
        )
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        #expect(throws: AudioAssetWriterError.injected(.databaseCommit)) {
            _ = try writer.finalize(into: store)
        }
        let handle = try FileHandle(forWritingTo: writer.stableURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        #expect(try reconciler.reconcileAll(store: store) == [
            .recoveryRequired(sessionId: session.sessionId, reason: "stableMissingOrInvalid")
        ])
        #expect(try store.sessionState(sessionId: session.sessionId) == "recoveryRequired")
        #expect(try store.count(in: "audio_assets") == 0)
        let quarantine = root.appending(path: "quarantine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count == 1)
        #expect(try reconciler.reconcileAll(store: store) == [
            .recoveryRequired(sessionId: session.sessionId, reason: "incompleteManifest")
        ])
    }

    @Test func startupRecoveryClassifiesReadableTemporaryWithoutPublishingReady() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.audioSync]
        )
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        #expect(throws: AudioAssetWriterError.injected(.audioSync)) {
            _ = try writer.finalize(into: store)
        }

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        #expect(try reconciler.reconcileAll(store: store) == [
            .recoveryRequired(
                sessionId: session.sessionId, reason: "temporaryAwaitingFinalization"
            )
        ])
        #expect(try store.sessionState(sessionId: session.sessionId) == "recoveryRequired")
        #expect(try store.count(in: "audio_assets") == 0)
        #expect(FileManager.default.fileExists(atPath: writer.temporaryURL.path))
    }

    @Test func startupRecoveryQuarantinesTmpAndStableConflict() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(
            assetRoot: root, session: session, injecting: [.databaseCommit]
        )
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        #expect(throws: AudioAssetWriterError.injected(.databaseCommit)) {
            _ = try writer.finalize(into: store)
        }
        try FileManager.default.copyItem(at: writer.stableURL, to: writer.temporaryURL)

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        #expect(try reconciler.reconcileAll(store: store) == [
            .recoveryRequired(sessionId: session.sessionId, reason: "pathConflict")
        ])
        #expect(try store.count(in: "audio_assets") == 0)
        let quarantine = root.appending(path: "quarantine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count == 2)
    }

    @Test func startupRecoveryFailsUnownedRecordingAndQuarantinesOrphan() throws {
        let (root, store, session, _) = try fixture()
        try store.insertSession(session)
        let orphan = root.appending(path: "unknown.caf")
        try Data("synthetic-orphan".utf8).write(to: orphan)

        let reconciler = try AudioRecoveryReconciler(assetRoot: root)
        let outcomes = try reconciler.reconcileAll(store: store)
        #expect(outcomes.contains(.failedRecording(
            sessionId: session.sessionId, reason: "manifestAndFileMissing"
        )))
        #expect(outcomes.contains(.quarantinedOrphan(relativePath: "unknown.caf")))
        #expect(try store.sessionState(sessionId: session.sessionId) == "failed")
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "quarantine/orphan-unknown.caf").path
        ))
    }

    @Test func deletionFailureStaysDeletingAndStartupRetryIsIdempotent() throws {
        let (root, store, session, format) = try fixture()
        let writer = try AtomicAudioAssetWriter(assetRoot: root, session: session)
        try writer.begin(format: format)
        try writer.write(buffer(format: format))
        _ = try writer.finalize(into: store)

        let failing = SessionDeletionCoordinator(
            assetRoot: root, injecting: .fileRemoval
        )
        #expect(throws: AudioAssetWriterError.self) {
            try failing.delete(sessionId: session.sessionId, store: store)
        }
        #expect(try store.sessionState(sessionId: session.sessionId) == "deleting")
        #expect(FileManager.default.fileExists(atPath: writer.stableURL.path))

        let resumed = SessionDeletionCoordinator(assetRoot: root)
        try resumed.resumePending(store: store)
        #expect(try store.sessionState(sessionId: session.sessionId) == nil)
        #expect(try store.count(in: "audio_assets") == 0)
        #expect(!FileManager.default.fileExists(atPath: writer.stableURL.path))
        try resumed.resumePending(store: store)
    }
}
