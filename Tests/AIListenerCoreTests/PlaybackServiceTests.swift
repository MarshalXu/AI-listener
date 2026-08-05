import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct PlaybackServiceTests {
    final class FakeDriver: AudioPlaybackDriver {
        var currentTime: TimeInterval = 0 {
            didSet { currentTime += seekOffset }
        }
        var duration: TimeInterval = 1.0
        var rate: Float = 1.0
        var isPlaying = false
        let seekOffset: TimeInterval

        init(seekOffset: TimeInterval = 0) {
            self.seekOffset = seekOffset
        }

        func play() -> Bool {
            isPlaying = true
            return true
        }

        func pause() { isPlaying = false }
    }

    struct Fixture {
        let root: URL
        let databaseURL: URL
        let sessionId: String
        let segment: TranscriptSegmentRecord
        let audioURL: URL
    }

    @Test func listAndDetailSurviveRepositoryReopen() throws {
        let fixture = try makeFixture()
        let reopened = try SessionStore(databaseURL: fixture.databaseURL)
        let list = try reopened.listPlayableSessions()
        #expect(list.count == 1)
        #expect(list[0].sessionId == fixture.sessionId)
        #expect(list[0].previewText == "第一段")
        let detail = try reopened.playableSession(sessionId: fixture.sessionId)
        #expect(detail?.segments == [fixture.segment])
        #expect(detail?.asset.relativePath == fixture.audioURL.lastPathComponent)
    }

    @Test func finalizedSegmentSeeksFromStartAndReportsActualMediaPosition() throws {
        let fixture = try makeFixture(segmentStartMs: 300)
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let fake = FakeDriver(seekOffset: 0.042)
        let service = PlaybackService(
            store: store, assetRoot: fixture.root,
            driverFactory: { _ in fake }
        )
        _ = try service.open(sessionId: fixture.sessionId)
        let position = try service.play(segment: fixture.segment)
        #expect(position.requestedMs == 300)
        #expect(position.actualMs == 342)
        #expect(position.absoluteErrorMs == 42)
        #expect(service.isPlaying)
        service.pause()
        #expect(!service.isPlaying)
    }

    @Test func currentTimeMsReportsPlaybackPositionInMilliseconds() throws {
        let fixture = try makeFixture()
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let fake = FakeDriver(seekOffset: 0)
        let service = PlaybackService(
            store: store, assetRoot: fixture.root,
            driverFactory: { _ in fake }
        )
        _ = try service.open(sessionId: fixture.sessionId)
        #expect(service.currentTimeMs == 0)
        fake.currentTime = 0.5
        #expect(service.currentTimeMs == 500)
        fake.currentTime = 1.2
        #expect(service.currentTimeMs == 1_200)
    }

    @Test func durationMsReflectsDriverDurationWhenAvailable() throws {
        let fixture = try makeFixture()
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let fake = FakeDriver(seekOffset: 0)
        fake.duration = 2.5 // 2500 ms
        let service = PlaybackService(
            store: store, assetRoot: fixture.root,
            driverFactory: { _ in fake }
        )
        _ = try service.open(sessionId: fixture.sessionId)
        #expect(service.durationMs == 2_500)
    }

    @Test func durationMsFallsBackToAssetRecordWhenDriverDurationIsZero() throws {
        let fixture = try makeFixture()
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let fake = FakeDriver(seekOffset: 0)
        fake.duration = 0 // driver reports no duration
        let service = PlaybackService(
            store: store, assetRoot: fixture.root,
            driverFactory: { _ in fake }
        )
        _ = try service.open(sessionId: fixture.sessionId)
        // Fixture asset has durationMs = 1000
        #expect(service.durationMs == 1_000)
    }

    @Test func resumeContinuesPlaybackFromCurrentPosition() throws {
        let fixture = try makeFixture()
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let fake = FakeDriver(seekOffset: 0)
        let service = PlaybackService(
            store: store, assetRoot: fixture.root,
            driverFactory: { _ in fake }
        )
        _ = try service.open(sessionId: fixture.sessionId)
        // Seek to 500ms, play, then pause
        _ = try service.play(atMs: 500)
        service.pause()
        #expect(!service.isPlaying)
        #expect(service.currentTimeMs == 500)
        // Resume should start playing without changing position
        let position = try service.resume()
        #expect(service.isPlaying)
        #expect(position.requestedMs == 500)
    }

    @Test func resumeThrowsWhenNoDriverIsLoaded() {
        let store = try! SessionStore(
            databaseURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "empty-\(UUID().uuidString).sqlite")
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "root-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = PlaybackService(store: store, assetRoot: root)
        #expect(throws: PlaybackServiceError.playerUnavailable) {
            _ = try service.resume()
        }
    }

    @Test func setRateClampsToValidRangeAndAppliesToDriver() throws {
        let fixture = try makeFixture()
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let fake = FakeDriver(seekOffset: 0)
        let service = PlaybackService(
            store: store, assetRoot: fixture.root,
            driverFactory: { _ in fake }
        )
        _ = try service.open(sessionId: fixture.sessionId)
        service.setRate(2.0)
        #expect(fake.rate == 2.0)
        service.setRate(-1.0) // negative → clamped to 0
        #expect(fake.rate == 0.0)
        service.setRate(10.0) // too high → clamped to 4.0
        #expect(fake.rate == 4.0)
    }

    @Test func missingCommittedAssetIsRemovedFromReadyListWithoutDeletingMetadata() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.audioURL)
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let service = PlaybackService(store: store, assetRoot: fixture.root)
        #expect(throws: PlaybackServiceError.assetMissing) {
            try service.open(sessionId: fixture.sessionId)
        }
        #expect(try store.sessionState(sessionId: fixture.sessionId) == "recoveryRequired")
        #expect(try store.count(in: "sessions") == 1)
        #expect(try store.count(in: "transcript_segments") == 1)
        #expect(try store.listPlayableSessions().isEmpty)
    }

    @Test func corruptCommittedAssetIsQuarantinedLogicallyAndCannotPlay() throws {
        let fixture = try makeFixture()
        let handle = try FileHandle(forWritingTo: fixture.audioURL)
        try handle.truncate(atOffset: 16)
        try handle.close()
        let store = try SessionStore(databaseURL: fixture.databaseURL)
        let service = PlaybackService(store: store, assetRoot: fixture.root)
        #expect(throws: PlaybackServiceError.assetCorrupt) {
            try service.open(sessionId: fixture.sessionId)
        }
        #expect(try store.sessionState(sessionId: fixture.sessionId) == "recoveryRequired")
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @Test func approvedSeekGateRequiresThirtySamplesAndEnforcesP95AndMaximum() {
        var passing: [PlaybackPosition] = []
        for index in 0..<30 {
            let requested = Int64(index * 100)
            passing.append(PlaybackPosition(requestedMs: requested, actualMs: requested + 20))
        }
        passing[29] = PlaybackPosition(requestedMs: 2_900, actualMs: 3_400)
        let pass = PlaybackService.evaluateSeekGate(passing)
        #expect(pass.sampleCount == 30)
        #expect(pass.p95ErrorMs == 20)
        #expect(pass.maxErrorMs == 500)
        #expect(pass.passed)

        var failing = passing
        failing[27] = PlaybackPosition(requestedMs: 2_700, actualMs: 3_000)
        failing[28] = PlaybackPosition(requestedMs: 2_800, actualMs: 3_100)
        let fail = PlaybackService.evaluateSeekGate(failing)
        #expect(fail.p95ErrorMs == 300)
        #expect(!fail.passed)
        #expect(!PlaybackService.evaluateSeekGate(Array(passing.prefix(29))).passed)
    }

    @Test func actualPlayerMeetsThirtyClickSyntheticMarkerGateAfterReopen() throws {
        var positions: [PlaybackPosition] = []
        for target in [Int64(0), 300, 700] {
            let fixture = try makeFixture(segmentStartMs: target)
            let reopened = try SessionStore(databaseURL: fixture.databaseURL)
            let service = PlaybackService(store: reopened, assetRoot: fixture.root)
            _ = try service.open(sessionId: fixture.sessionId)
            for click in 1...10 {
                let position = try service.play(segment: fixture.segment)
                positions.append(position)
                print("M08 target=\(target) click=\(click) actual=\(position.actualMs) error=\(position.absoluteErrorMs)")
                service.pause()
            }
        }
        let result = PlaybackService.evaluateSeekGate(positions)
        print("M08 samples=\(result.sampleCount) p95=\(result.p95ErrorMs) max=\(result.maxErrorMs) passed=\(result.passed)")
        #expect(result.sampleCount == 30)
        #expect(result.passed)
    }

    private func makeFixture(segmentStartMs: Int64 = 100) throws -> Fixture {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "sessions.sqlite")
        let store = try SessionStore(databaseURL: databaseURL)
        let sessionId = UUID().uuidString
        let audioAssetId = UUID().uuidString
        let audioURL = root.appending(path: "\(sessionId).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        var file: AVAudioFile? = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try file?.write(from: buffer)
        file = nil
        let data = try Data(contentsOf: audioURL)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ready = SessionRecord(
            sessionId: sessionId, state: "ready", transcriptState: "finalized",
            createdAtUtc: 1_700_000_000_000, captureStartMonotonicNs: 10,
            endedAtUtc: 1_700_000_001_000, committedAudioAssetId: audioAssetId
        )
        let asset = AudioAssetRecord(
            audioAssetId: audioAssetId, sessionId: sessionId,
            relativePath: audioURL.lastPathComponent, container: "caf", codec: "lpcm",
            sampleRateHz: 16_000, channelCount: 1, durationMs: 1_000,
            byteCount: Int64(data.count), sha256: hash, commitState: "committed"
        )
        try store.commitReadySession(ready, asset: asset)
        let segment = TranscriptSegmentRecord(
            segmentId: UUID().uuidString, sessionId: sessionId, revisionOf: nil,
            status: "finalized", sequence: 1, revision: 0,
            startMs: segmentStartMs, endMs: max(600, segmentStartMs + 100), text: "第一段",
            createdMonotonicMs: 600, engineId: "fixture", engineModelVersion: "1"
        )
        try store.insertTranscriptSegment(segment)
        return Fixture(
            root: root, databaseURL: databaseURL, sessionId: sessionId,
            segment: segment, audioURL: audioURL
        )
    }
}
