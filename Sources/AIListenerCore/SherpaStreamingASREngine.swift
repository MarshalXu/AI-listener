import CSherpaShim
import Foundation

public struct SherpaModelPaths: Sendable, Equatable {
    public let library: URL
    public let encoder: URL
    public let decoder: URL
    public let joiner: URL
    public let tokens: URL

    public init(library: URL, encoder: URL, decoder: URL, joiner: URL, tokens: URL) {
        self.library = library
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.tokens = tokens
    }

    public static func bundled(in bundle: Bundle = .main) -> SherpaModelPaths? {
        let frameworks = bundle.bundleURL.appending(path: "Contents/Frameworks")
        let runtime = frameworks.appending(path: "libsherpa-onnx-c-api.dylib")
        guard FileManager.default.fileExists(atPath: runtime.path),
        let encoder = bundle.url(
            forResource: "encoder-epoch-99-avg-1.int8", withExtension: "onnx",
            subdirectory: "Model"
        ),
        let decoder = bundle.url(
            forResource: "decoder-epoch-99-avg-1", withExtension: "onnx",
            subdirectory: "Model"
        ),
        let joiner = bundle.url(
            forResource: "joiner-epoch-99-avg-1.int8", withExtension: "onnx",
            subdirectory: "Model"
        ),
        let tokens = bundle.url(
            forResource: "tokens", withExtension: "txt", subdirectory: "Model"
        ) else { return nil }
        return SherpaModelPaths(
            library: runtime, encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens
        )
    }
}

public enum SherpaStreamingASRError: Error, Sendable, Equatable {
    case missingFile(String)
    case initialization(Int32)
    case runtime(Int32)
    case sessionMismatch
}

/// Local-only streaming adapter for the Board-approved sherpa-onnx v1.13.2
/// runtime. It has no networking API or fallback.
public final class SherpaStreamingASREngine: LocalStreamingASREngine, @unchecked Sendable {
    private let handle: OpaquePointer
    private let modelVersion: String
    private var sessionId: String?
    private var segmentSequence: Int64 = 0
    private var revision: Int64 = 0
    private var segmentStartMs: Int64?
    private var lastEndMs: Int64 = 0
    private var lastText = ""
    private var finished = false

    public init(paths: SherpaModelPaths, modelVersion: String, numThreads: Int32 = 1) throws {
        for (name, url) in [
            ("library", paths.library), ("encoder", paths.encoder), ("decoder", paths.decoder),
            ("joiner", paths.joiner), ("tokens", paths.tokens),
        ] where !FileManager.default.fileExists(atPath: url.path) {
            throw SherpaStreamingASRError.missingFile(name)
        }
        var status = AL_SHERPA_OK
        let created = paths.library.path.withCString { library in
            paths.encoder.path.withCString { encoder in
                paths.decoder.path.withCString { decoder in
                    paths.joiner.path.withCString { joiner in
                        paths.tokens.path.withCString { tokens in
                            var config = ALSherpaConfig(
                                library_path: library, encoder_path: encoder,
                                decoder_path: decoder, joiner_path: joiner,
                                tokens_path: tokens, num_threads: numThreads
                            )
                            return al_sherpa_create(&config, &status)
                        }
                    }
                }
            }
        }
        guard let created else {
            throw SherpaStreamingASRError.initialization(Int32(status.rawValue))
        }
        handle = created
        self.modelVersion = modelVersion
    }

    deinit { al_sherpa_destroy(handle) }

    public func accept(_ frame: ASRInputFrame) throws -> [ASRTranscriptEvent] {
        guard !finished else { throw SherpaStreamingASRError.runtime(-1) }
        if let sessionId, sessionId != frame.sessionId {
            throw SherpaStreamingASRError.sessionMismatch
        }
        sessionId = frame.sessionId
        segmentStartMs = segmentStartMs ?? frame.startMs
        lastEndMs = max(lastEndMs, frame.startMs + frame.durationMs)
        let status = frame.samples.withUnsafeBufferPointer {
            al_sherpa_accept(handle, Int32(frame.sampleRate), $0.baseAddress, Int32($0.count))
        }
        guard status == AL_SHERPA_OK else {
            throw SherpaStreamingASRError.runtime(Int32(status.rawValue))
        }
        let endpoint = al_sherpa_is_endpoint(handle) != 0
        let text = currentText()
        guard !text.isEmpty else {
            if endpoint { al_sherpa_reset(handle); segmentStartMs = nil }
            return []
        }
        revision += 1
        let event = makeEvent(text: text, finalized: endpoint)
        lastText = text
        if endpoint {
            al_sherpa_reset(handle)
            segmentSequence += 1
            revision = 0
            segmentStartMs = nil
            lastText = ""
        }
        return [event]
    }

    public func finish() throws -> [ASRTranscriptEvent] {
        finished = true
        let status = al_sherpa_finish(handle)
        guard status == AL_SHERPA_OK else {
            throw SherpaStreamingASRError.runtime(Int32(status.rawValue))
        }
        let text = currentText()
        guard !text.isEmpty else { return [] }
        return [makeEvent(text: text, finalized: true)]
    }

    private func currentText() -> String {
        guard let pointer = al_sherpa_copy_text(handle) else { return "" }
        defer { al_sherpa_free_text(pointer) }
        return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeEvent(text: String, finalized: Bool) -> ASRTranscriptEvent {
        let session = sessionId ?? "unknown"
        return ASRTranscriptEvent(
            segmentId: "\(session)-\(segmentSequence)", sessionId: session,
            status: finalized ? .finalized : .partial, sequence: segmentSequence,
            revision: revision, startMs: segmentStartMs ?? max(0, lastEndMs - 1),
            endMs: max(lastEndMs, (segmentStartMs ?? 0) + 1), text: text,
            createdMonotonicMs: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000),
            engineId: "sherpa-onnx", engineModelVersion: modelVersion
        )
    }
}
