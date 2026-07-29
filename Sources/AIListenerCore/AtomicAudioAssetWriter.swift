import AVFoundation
import CryptoKit
import Darwin
import Foundation

public struct RecoveryManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public enum Phase: String, Codable, Sendable {
        case temporary
        case stablePendingCommit
        case committed
        case quarantined
    }

    public let version: Int
    public let sessionId: String
    public let audioAssetId: String
    public let temporaryRelativePath: String
    public let stableRelativePath: String
    public var phase: Phase
    public var byteCount: Int64? = nil
    public var durationMs: Int64? = nil
    public var sha256: String? = nil
    public var sampleRateHz: Int64? = nil
    public var channelCount: Int64? = nil
    public var createdAtUtc: Int64? = nil
    public var captureStartMonotonicNs: Int64? = nil
    public var transcriptState: String? = nil
    public var endedAtUtc: Int64? = nil
    public var terminationReason: String? = nil
}

public enum AudioCommitFailurePoint: Sendable, Hashable {
    case manifestCreate
    case diskFullDuringWrite
    case audioSync
    case manifestStablePending
    case rename
    case directorySync
    case databaseCommit
    case manifestCleanup
}

public enum AudioAssetWriterError: Error, Equatable {
    case invalidRelativePath
    case invalidState
    case injected(AudioCommitFailurePoint)
    case fileIO(String)
}

/// Implements SDD D-04/D-11 for one microphone asset. Callers serialize access.
public final class AtomicAudioAssetWriter: @unchecked Sendable {
    private let assetRoot: URL
    private let session: SessionRecord
    private let audioAssetId: String
    private let failures: Set<String>
    private let fileManager: FileManager
    private var audioFile: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var format: AVAudioFormat?

    public init(
        assetRoot: URL,
        session: SessionRecord,
        audioAssetId: String = UUID().uuidString,
        injecting failures: Set<AudioCommitFailurePoint> = [],
        fileManager: FileManager = .default
    ) throws {
        self.assetRoot = assetRoot.standardizedFileURL
        self.session = session
        self.audioAssetId = audioAssetId
        self.failures = Set(failures.map { String(describing: $0) })
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.assetRoot, withIntermediateDirectories: true)
    }

    public var manifestURL: URL { assetRoot.appending(path: "\(session.sessionId).recovery.json") }
    public var temporaryURL: URL { assetRoot.appending(path: "\(session.sessionId).audio.tmp") }
    public var stableURL: URL { assetRoot.appending(path: "\(session.sessionId).caf") }

    public func begin(format: AVAudioFormat) throws {
        guard audioFile == nil, !fileManager.fileExists(atPath: temporaryURL.path),
              !fileManager.fileExists(atPath: stableURL.path) else {
            throw AudioAssetWriterError.invalidState
        }
        try validateContained(temporaryURL)
        try validateContained(stableURL)
        try inject(.manifestCreate)
        let manifest = RecoveryManifest(
            version: RecoveryManifest.currentVersion,
            sessionId: session.sessionId,
            audioAssetId: audioAssetId,
            temporaryRelativePath: temporaryURL.lastPathComponent,
            stableRelativePath: stableURL.lastPathComponent,
            phase: .temporary, createdAtUtc: session.createdAtUtc,
            captureStartMonotonicNs: session.captureStartMonotonicNs,
            transcriptState: session.transcriptState, endedAtUtc: session.endedAtUtc,
            terminationReason: session.terminationReason
        )
        try publish(manifest)
        do {
            audioFile = try AVAudioFile(
                forWriting: temporaryURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            self.format = format
        } catch {
            throw AudioAssetWriterError.fileIO("createAudio")
        }
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let audioFile, buffer.frameLength > 0 else {
            throw AudioAssetWriterError.invalidState
        }
        try inject(.diskFullDuringWrite)
        do {
            try audioFile.write(from: buffer)
            frameCount += AVAudioFramePosition(buffer.frameLength)
        } catch {
            throw AudioAssetWriterError.fileIO("writeAudio")
        }
    }

    public func finalize(into store: SessionStore) throws -> AudioAssetRecord {
        guard audioFile != nil, let format else { throw AudioAssetWriterError.invalidState }
        audioFile = nil
        try inject(.audioSync)
        try syncFile(temporaryURL)

        let bytes = try fileSize(temporaryURL)
        guard bytes > 0 else { throw AudioAssetWriterError.fileIO("emptyAudio") }
        let duration = Int64((Double(frameCount) / format.sampleRate * 1_000).rounded())
        let digest = try sha256(temporaryURL)
        var manifest = try loadManifest()
        manifest.phase = .stablePendingCommit
        manifest.byteCount = bytes
        manifest.durationMs = duration
        manifest.sha256 = digest
        manifest.sampleRateHz = Int64(format.sampleRate)
        manifest.channelCount = Int64(format.channelCount)
        try inject(.manifestStablePending)
        try publish(manifest)

        try inject(.rename)
        guard rename(temporaryURL.path, stableURL.path) == 0 else {
            throw AudioAssetWriterError.fileIO("renameAudio")
        }
        try inject(.directorySync)
        try syncDirectory(assetRoot)

        let asset = AudioAssetRecord(
            audioAssetId: audioAssetId, sessionId: session.sessionId,
            relativePath: stableURL.lastPathComponent, container: "caf", codec: "lpcm",
            sampleRateHz: Int64(format.sampleRate), channelCount: Int64(format.channelCount),
            durationMs: duration, byteCount: bytes, sha256: digest, commitState: "committed"
        )
        let ready = SessionRecord(
            sessionId: session.sessionId, state: "ready",
            transcriptState: session.transcriptState, createdAtUtc: session.createdAtUtc,
            captureStartMonotonicNs: session.captureStartMonotonicNs,
            lastEventSequence: session.lastEventSequence, endedAtUtc: session.endedAtUtc,
            terminationReason: session.terminationReason, committedAudioAssetId: audioAssetId,
            lastErrorId: session.lastErrorId
        )
        try inject(.databaseCommit)
        try store.commitReadySession(ready, asset: asset)

        manifest.phase = .committed
        try publish(manifest)
        try inject(.manifestCleanup)
        try fileManager.removeItem(at: manifestURL)
        try syncDirectory(assetRoot)
        return asset
    }

    private func inject(_ point: AudioCommitFailurePoint) throws {
        if failures.contains(String(describing: point)) {
            throw AudioAssetWriterError.injected(point)
        }
    }

    private func loadManifest() throws -> RecoveryManifest {
        do {
            return try JSONDecoder().decode(
                RecoveryManifest.self, from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw AudioAssetWriterError.fileIO("readManifest")
        }
    }

    private func publish(_ manifest: RecoveryManifest) throws {
        let temporaryManifest = manifestURL.appendingPathExtension("publishing")
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: temporaryManifest, options: [.withoutOverwriting])
            try syncFile(temporaryManifest)
            if fileManager.fileExists(atPath: manifestURL.path) {
                guard rename(temporaryManifest.path, manifestURL.path) == 0 else {
                    throw AudioAssetWriterError.fileIO("renameManifest")
                }
            } else {
                guard rename(temporaryManifest.path, manifestURL.path) == 0 else {
                    throw AudioAssetWriterError.fileIO("createManifest")
                }
            }
            try syncDirectory(assetRoot)
        } catch let error as AudioAssetWriterError {
            try? fileManager.removeItem(at: temporaryManifest)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryManifest)
            throw AudioAssetWriterError.fileIO("publishManifest")
        }
    }

    private func validateContained(_ url: URL) throws {
        let root = assetRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.deletingLastPathComponent().resolvingSymlinksInPath()
            .standardizedFileURL.path + "/" == root else {
            throw AudioAssetWriterError.invalidRelativePath
        }
    }

    private func syncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw AudioAssetWriterError.fileIO("openForSync") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw AudioAssetWriterError.fileIO("fileSync") }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw AudioAssetWriterError.fileIO("openDirectory") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AudioAssetWriterError.fileIO("directorySync")
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
