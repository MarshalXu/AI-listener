import AVFoundation
import CryptoKit
import Foundation

public enum PlaybackServiceError: Error, Equatable {
    case sessionNotPlayable
    case segmentNotFinalized
    case assetOutsideRoot
    case assetMissing
    case assetCorrupt
    case playerUnavailable
}

public struct PlaybackPosition: Sendable, Equatable {
    public let requestedMs: Int64
    public let actualMs: Int64

    public var absoluteErrorMs: Int64 { abs(actualMs - requestedMs) }
}

public struct PlaybackSeekGateResult: Sendable, Equatable {
    public let sampleCount: Int
    public let p95ErrorMs: Int64
    public let maxErrorMs: Int64
    public let passed: Bool
}

public protocol AudioPlaybackDriver: AnyObject {
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }
    var rate: Float { get set }
    var isPlaying: Bool { get }
    func play() -> Bool
    func pause()
}

extension AVAudioPlayer: AudioPlaybackDriver {
    // AVAudioPlayer natively provides `duration` (TimeInterval) and `rate` (Float).
    // `enableRate` must be set to true at construction for non-1.0 rates to take
    // effect; see PlaybackService.defaultDriverFactory below.
}

/// D-07 adapter: opens only committed assets and reports the player's media position.
public final class PlaybackService {
    public static let approvedP95LimitMs: Int64 = 250
    public static let approvedMaxLimitMs: Int64 = 500
    public typealias DriverFactory = (URL) throws -> AudioPlaybackDriver

    private let store: SessionStore
    private let assetRoot: URL
    private let fileManager: FileManager
    private let driverFactory: DriverFactory
    private var driver: AudioPlaybackDriver?
    public private(set) var detail: SessionDetail?

    /// Exposed so the UI layer can construct asset URLs for waveform extraction.
    public var assetRootURL: URL { assetRoot }

    public init(
        store: SessionStore,
        assetRoot: URL,
        fileManager: FileManager = .default,
        driverFactory: @escaping DriverFactory = { try AVAudioPlayer(contentsOf: $0) }
    ) {
        self.store = store
        self.assetRoot = assetRoot.standardizedFileURL
        self.fileManager = fileManager
        self.driverFactory = driverFactory
    }

    public var isPlaying: Bool { driver?.isPlaying ?? false }

    @discardableResult
    public func open(sessionId: String) throws -> SessionDetail {
        guard let detail = try store.playableSession(sessionId: sessionId) else {
            throw PlaybackServiceError.sessionNotPlayable
        }
        let url = try containedAssetURL(relativePath: detail.asset.relativePath)
        do {
            guard fileManager.fileExists(atPath: url.path) else {
                try invalidate(detail)
                throw PlaybackServiceError.assetMissing
            }
            guard try byteCount(url) == detail.asset.byteCount,
                  try sha256(url) == detail.asset.sha256,
                  (try? AVAudioFile(forReading: url)) != nil else {
                try invalidate(detail)
                throw PlaybackServiceError.assetCorrupt
            }
            driver = try driverFactory(url)
            self.detail = detail
            return detail
        } catch let error as PlaybackServiceError {
            throw error
        } catch {
            throw PlaybackServiceError.playerUnavailable
        }
    }

    @discardableResult
    public func play(atMs: Int64) throws -> PlaybackPosition {
        guard let driver else {
            throw PlaybackServiceError.playerUnavailable
        }
        let targetMs = max(0, min(atMs, detail?.asset.durationMs ?? atMs))
        driver.currentTime = TimeInterval(targetMs) / 1_000
        guard driver.play() else { throw PlaybackServiceError.playerUnavailable }
        return PlaybackPosition(
            requestedMs: targetMs,
            actualMs: Int64((driver.currentTime * 1_000).rounded())
        )
    }

    @discardableResult
    public func play(segment: TranscriptSegmentRecord) throws -> PlaybackPosition {
        guard segment.status == "finalized",
              segment.sessionId == detail?.session.sessionId,
              detail?.segments.contains(where: {
                  $0.segmentId == segment.segmentId && $0.revision == segment.revision
              }) == true,
              let driver else {
            throw PlaybackServiceError.segmentNotFinalized
        }
        let targetMs = max(0, min(segment.startMs, detail?.asset.durationMs ?? segment.startMs))
        driver.currentTime = TimeInterval(targetMs) / 1_000
        guard driver.play() else { throw PlaybackServiceError.playerUnavailable }
        return PlaybackPosition(
            requestedMs: targetMs,
            actualMs: Int64((driver.currentTime * 1_000).rounded())
        )
    }

    public func pause() {
        driver?.pause()
    }

    /// Current playback position in milliseconds (0 when no asset is loaded).
    public var currentTimeMs: Int64 {
        guard let driver else { return 0 }
        return Int64((driver.currentTime * 1_000).rounded())
    }

    /// Total duration of the currently loaded asset in milliseconds,
    /// sourced from the driver when available, else from the asset record.
    public var durationMs: Int64 {
        if let driver, driver.duration > 0 {
            return Int64((driver.duration * 1_000).rounded())
        }
        return detail?.asset.durationMs ?? 0
    }

    /// Resumes playback from the current position without seeking.
    @discardableResult
    public func resume() throws -> PlaybackPosition {
        guard let driver else {
            throw PlaybackServiceError.playerUnavailable
        }
        let requestedMs = currentTimeMs
        guard driver.play() else { throw PlaybackServiceError.playerUnavailable }
        return PlaybackPosition(
            requestedMs: requestedMs,
            actualMs: Int64((driver.currentTime * 1_000).rounded())
        )
    }

    /// Sets the playback rate (1.0 = normal speed). The driver must have rate
    /// control enabled; for `AVAudioPlayer` this sets `enableRate = true`
    /// automatically before applying the rate.
    public func setRate(_ rate: Float) {
        guard let driver else { return }
        if let player = driver as? AVAudioPlayer {
            player.enableRate = true
        }
        driver.rate = max(0.0, min(rate, 4.0))
    }

    /// Evaluates the approved M-08 thresholds; callers retain the raw 30 measurements.
    public static func evaluateSeekGate(_ positions: [PlaybackPosition]) -> PlaybackSeekGateResult {
        let errors = positions.map(\.absoluteErrorMs).sorted()
        guard !errors.isEmpty else {
            return PlaybackSeekGateResult(
                sampleCount: 0, p95ErrorMs: .max, maxErrorMs: .max, passed: false
            )
        }
        let rank = max(0, Int(ceil(Double(errors.count) * 0.95)) - 1)
        let p95 = errors[rank]
        let maximum = errors[errors.count - 1]
        return PlaybackSeekGateResult(
            sampleCount: errors.count, p95ErrorMs: p95, maxErrorMs: maximum,
            passed: errors.count == 30
                && p95 <= approvedP95LimitMs
                && maximum <= approvedMaxLimitMs
        )
    }

    private func invalidate(_ detail: SessionDetail) throws {
        try store.markCommittedAssetRecoveryRequired(session: detail.session)
        self.detail = nil
        driver = nil
    }

    private func containedAssetURL(relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw PlaybackServiceError.assetOutsideRoot
        }
        let rootPath = assetRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let candidate = assetRoot.appending(path: relativePath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(rootPath) else {
            throw PlaybackServiceError.assetOutsideRoot
        }
        return candidate
    }

    private func byteCount(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
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
