import Darwin
import Foundation

public enum SessionDeletionFailurePoint: Sendable {
    case fileRemoval
}

/// D-12 deletion is explicit, DB-first, and idempotently resumed at startup.
public final class SessionDeletionCoordinator {
    private let assetRoot: URL
    private let fileManager: FileManager
    private let injectFileRemovalFailure: Bool

    public init(
        assetRoot: URL,
        injecting failure: SessionDeletionFailurePoint? = nil,
        fileManager: FileManager = .default
    ) {
        self.assetRoot = assetRoot.standardizedFileURL
        self.fileManager = fileManager
        self.injectFileRemovalFailure = failure == .fileRemoval
    }

    public func delete(sessionId: String, store: SessionStore) throws {
        try store.beginDeleting(sessionId: sessionId)
        try resume(sessionId: sessionId, store: store)
    }

    public func resumePending(store: SessionStore) throws {
        for sessionId in try store.sessionIds(inStates: ["deleting"]) {
            try resume(sessionId: sessionId, store: store)
        }
    }

    private func resume(sessionId: String, store: SessionStore) throws {
        guard let relativePath = try store.audioPathForDeletion(sessionId: sessionId),
              validLeaf(relativePath) else {
            throw SessionStoreError.invalidContract("deleteAudioPath")
        }
        if injectFileRemovalFailure {
            throw AudioAssetWriterError.fileIO("deleteAudio")
        }
        let audioURL = assetRoot.appending(path: relativePath)
        if fileManager.fileExists(atPath: audioURL.path) {
            try fileManager.removeItem(at: audioURL)
            try syncDirectory(assetRoot)
        }
        try store.finishDeleting(sessionId: sessionId)
    }

    private func validLeaf(_ path: String) -> Bool {
        !path.isEmpty && path != "." && path != ".." && !path.contains("/")
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
