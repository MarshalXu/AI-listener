import AVFoundation
import CryptoKit
import Darwin
import Foundation

public enum AudioRecoveryOutcome: Sendable, Equatable {
    case recovered(sessionId: String)
    case cleanedCommitted(sessionId: String)
    case recoveryRequired(sessionId: String, reason: String)
    case failedRecording(sessionId: String, reason: String)
    case quarantinedOrphan(relativePath: String)
}

/// Reconciles app-owned D-11 manifests. It never deletes an unproven audio file.
public final class AudioRecoveryReconciler {
    private let assetRoot: URL
    private let quarantineRoot: URL
    private let fileManager: FileManager

    public init(assetRoot: URL, fileManager: FileManager = .default) throws {
        self.assetRoot = assetRoot.standardizedFileURL
        self.quarantineRoot = self.assetRoot.appending(path: "quarantine", directoryHint: .isDirectory)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.assetRoot, withIntermediateDirectories: true)
    }

    public func reconcileAll(store: SessionStore) throws -> [AudioRecoveryOutcome] {
        let manifests = try fileManager.contentsOfDirectory(
            at: assetRoot, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".recovery.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var outcomes = try manifests.map { try reconcile(manifestURL: $0, store: store) }
        let manifestSessionIds = Set(manifests.map {
            String($0.lastPathComponent.dropLast(".recovery.json".count))
        })
        for sessionId in try store.sessionIds(inStates: ["recording"])
        where !manifestSessionIds.contains(sessionId) {
            let failed = SessionRecord(
                sessionId: sessionId, state: "failed", transcriptState: "unavailable",
                createdAtUtc: 0, captureStartMonotonicNs: 0,
                terminationReason: "recoveryMissingAsset"
            )
            try store.markFailed(failed)
            outcomes.append(.failedRecording(
                sessionId: sessionId, reason: "manifestAndFileMissing"
            ))
        }
        for record in try store.committedAudioIntegrityRecords() {
            let stable = assetRoot.appending(path: record.asset.relativePath)
            guard validLeaf(record.asset.relativePath),
                  fileManager.fileExists(atPath: stable.path),
                  try matches(stable, record.asset.byteCount, record.asset.sha256),
                  readableCAF(stable) else {
                if validLeaf(record.asset.relativePath),
                   fileManager.fileExists(atPath: stable.path) {
                    try quarantineCommitted(stable, sessionId: record.session.sessionId)
                }
                try store.markCommittedAssetRecoveryRequired(session: record.session)
                outcomes.append(.recoveryRequired(
                    sessionId: record.session.sessionId,
                    reason: "committedAssetMissingOrInvalid"
                ))
                continue
            }
        }
        let referenced = try store.referencedAudioPaths()
        var manifestPaths = Set<String>()
        for url in manifests {
            if let manifest = try? JSONDecoder().decode(
                RecoveryManifest.self, from: Data(contentsOf: url)
            ) {
                manifestPaths.insert(manifest.temporaryRelativePath)
                manifestPaths.insert(manifest.stableRelativePath)
            }
        }
        let candidates = try fileManager.contentsOfDirectory(
            at: assetRoot, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "caf" || $0.lastPathComponent.hasSuffix(".audio.tmp") }
        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where !referenced.contains(candidate.lastPathComponent)
            && !manifestPaths.contains(candidate.lastPathComponent) {
            try quarantineOrphan(candidate)
            outcomes.append(.quarantinedOrphan(relativePath: candidate.lastPathComponent))
        }
        return outcomes
    }

    private func reconcile(manifestURL: URL, store: SessionStore) throws -> AudioRecoveryOutcome {
        let manifest = try JSONDecoder().decode(
            RecoveryManifest.self, from: Data(contentsOf: manifestURL)
        )
        guard manifest.version == RecoveryManifest.currentVersion,
              validLeaf(manifest.temporaryRelativePath),
              validLeaf(manifest.stableRelativePath) else {
            throw AudioAssetWriterError.invalidRelativePath
        }
        let temporary = assetRoot.appending(path: manifest.temporaryRelativePath)
        let stable = assetRoot.appending(path: manifest.stableRelativePath)
        let session = manifestSession(manifest)

        if let bytes = manifest.byteCount, let hash = manifest.sha256,
           try store.committedAssetMatches(
                sessionId: manifest.sessionId, audioAssetId: manifest.audioAssetId,
                relativePath: manifest.stableRelativePath, byteCount: bytes, sha256: hash
           ), fileManager.fileExists(atPath: stable.path), try matches(stable, bytes, hash) {
            try fileManager.removeItem(at: manifestURL)
            try syncDirectory(assetRoot)
            return .cleanedCommitted(sessionId: manifest.sessionId)
        }

        if manifest.phase == .temporary {
            let hasTemporary = fileManager.fileExists(atPath: temporary.path)
            if hasTemporary,
               (try? fileSize(temporary)) ?? 0 > 0,
               readableCAF(temporary) {
                try store.markRecoveryRequired(session)
                return .recoveryRequired(
                    sessionId: manifest.sessionId, reason: "temporaryAwaitingFinalization"
                )
            }
            if hasTemporary {
                try quarantine([temporary], manifest: manifest, manifestURL: manifestURL)
            }
            try store.markRecoveryRequired(session)
            return .recoveryRequired(
                sessionId: manifest.sessionId, reason: "temporaryMissingEmptyOrUnreadable"
            )
        }

        guard manifest.phase == .stablePendingCommit,
              let bytes = manifest.byteCount, let duration = manifest.durationMs,
              let hash = manifest.sha256, let sampleRate = manifest.sampleRateHz,
              let channels = manifest.channelCount else {
            try store.markRecoveryRequired(session)
            return .recoveryRequired(sessionId: manifest.sessionId, reason: "incompleteManifest")
        }

        let hasTemporary = fileManager.fileExists(atPath: temporary.path)
        let hasStable = fileManager.fileExists(atPath: stable.path)
        if hasTemporary && hasStable {
            try quarantine([temporary, stable], manifest: manifest, manifestURL: manifestURL)
            try store.markRecoveryRequired(session)
            return .recoveryRequired(sessionId: manifest.sessionId, reason: "pathConflict")
        }
        if hasTemporary {
            guard try matches(temporary, bytes, hash), readableCAF(temporary) else {
                try quarantine([temporary], manifest: manifest, manifestURL: manifestURL)
                try store.markRecoveryRequired(session)
                return .recoveryRequired(sessionId: manifest.sessionId, reason: "hashMismatch")
            }
            guard rename(temporary.path, stable.path) == 0 else {
                throw AudioAssetWriterError.fileIO("recoveryRename")
            }
            try syncDirectory(assetRoot)
        }
        guard fileManager.fileExists(atPath: stable.path),
              try matches(stable, bytes, hash), readableCAF(stable) else {
            if fileManager.fileExists(atPath: stable.path) {
                try quarantine([stable], manifest: manifest, manifestURL: manifestURL)
            }
            try store.markRecoveryRequired(session)
            return .recoveryRequired(sessionId: manifest.sessionId, reason: "stableMissingOrInvalid")
        }

        let asset = AudioAssetRecord(
            audioAssetId: manifest.audioAssetId, sessionId: manifest.sessionId,
            relativePath: manifest.stableRelativePath, container: "caf", codec: "lpcm",
            sampleRateHz: sampleRate, channelCount: channels, durationMs: duration,
            byteCount: bytes, sha256: hash, commitState: "committed"
        )
        let recovered = SessionRecord(
            sessionId: session.sessionId, state: "recovered",
            transcriptState: session.transcriptState, createdAtUtc: session.createdAtUtc,
            captureStartMonotonicNs: session.captureStartMonotonicNs,
            endedAtUtc: session.endedAtUtc, terminationReason: session.terminationReason,
            committedAudioAssetId: manifest.audioAssetId
        )
        try store.commitReadySession(recovered, asset: asset)
        try fileManager.removeItem(at: manifestURL)
        try syncDirectory(assetRoot)
        return .recovered(sessionId: manifest.sessionId)
    }

    private func manifestSession(_ manifest: RecoveryManifest) -> SessionRecord {
        SessionRecord(
            sessionId: manifest.sessionId, state: "recoveryRequired",
            transcriptState: manifest.transcriptState ?? "unavailable",
            createdAtUtc: manifest.createdAtUtc ?? 0,
            captureStartMonotonicNs: manifest.captureStartMonotonicNs ?? 0,
            endedAtUtc: manifest.endedAtUtc, terminationReason: manifest.terminationReason
        )
    }

    private func validLeaf(_ path: String) -> Bool {
        !path.isEmpty && path != "." && path != ".." && !path.contains("/")
    }

    private func matches(_ url: URL, _ expectedBytes: Int64, _ expectedHash: String) throws -> Bool {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size == expectedBytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hash == expectedHash
    }

    private func readableCAF(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func quarantineOrphan(_ url: URL) throws {
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let destination = quarantineRoot.appending(path: "orphan-\(url.lastPathComponent)")
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: url, to: destination)
        }
        try syncDirectory(quarantineRoot)
        try syncDirectory(assetRoot)
    }

    private func quarantineCommitted(_ url: URL, sessionId: String) throws {
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let destination = quarantineRoot.appending(
            path: "\(sessionId)-committed-\(url.lastPathComponent)"
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: url, to: destination)
        }
        try syncDirectory(quarantineRoot)
        try syncDirectory(assetRoot)
    }

    private func quarantine(
        _ urls: [URL], manifest: RecoveryManifest, manifestURL: URL
    ) throws {
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        for url in urls where fileManager.fileExists(atPath: url.path) {
            let destination = quarantineRoot.appending(
                path: "\(manifest.sessionId)-\(url.lastPathComponent)"
            )
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: url, to: destination)
            }
        }
        var quarantined = manifest
        quarantined.phase = .quarantined
        let data = try JSONEncoder().encode(quarantined)
        try data.write(to: manifestURL, options: .atomic)
        try syncDirectory(quarantineRoot)
        try syncDirectory(assetRoot)
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw AudioAssetWriterError.fileIO("openDirectory") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw AudioAssetWriterError.fileIO("directorySync")
        }
    }
}
