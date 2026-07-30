import AIListenerCore
import AVFoundation
import Darwin
import Foundation

struct StressResult: Codable {
    let requestedAudioSeconds: Double
    let processedAudioSeconds: Double
    let elapsedSeconds: Double
    let realTimeFactor: Double
    let peakRSSBytes: UInt64
    let inputFrames: Int64
    let partialEvents: Int
    let finalizedEvents: Int
    let networkAPI: String
}

func requiredPath(_ name: String, at index: Int) -> URL {
    guard CommandLine.arguments.count > index else {
        FileHandle.standardError.write(Data("missing argument: \(name)\n".utf8))
        exit(64)
    }
    return URL(fileURLWithPath: CommandLine.arguments[index])
}

let library = requiredPath("library", at: 1)
let model = requiredPath("model directory", at: 2)
let wav = requiredPath("public wav", at: 3)
let requestedSeconds = CommandLine.arguments.count > 4
    ? (Double(CommandLine.arguments[4]) ?? 3_600) : 3_600
guard requestedSeconds > 0 else { exit(64) }

let engine = try SherpaStreamingASREngine(
    paths: SherpaModelPaths(
        library: library,
        encoder: model.appending(path: "encoder-epoch-99-avg-1.int8.onnx"),
        decoder: model.appending(path: "decoder-epoch-99-avg-1.onnx"),
        joiner: model.appending(path: "joiner-epoch-99-avg-1.int8.onnx"),
        tokens: model.appending(path: "tokens.txt")
    ),
    modelVersion: "zh-14M-2023-02-23",
    numThreads: 2
)

let clock = ContinuousClock()
let started = clock.now
var processedSeconds = 0.0
var sequence: Int64 = 0
var startMs: Int64 = 0
var partials = 0
var finals = 0
let chunkFrames: AVAudioFrameCount = 3_200

while processedSeconds < requestedSeconds {
    let audio = try AVAudioFile(forReading: wav)
    let format = audio.processingFormat
    while audio.framePosition < audio.length && processedSeconds < requestedSeconds {
        let remaining = AVAudioFrameCount(audio.length - audio.framePosition)
        let count = min(chunkFrames, remaining)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try audio.read(into: buffer, frameCount: count)
        let sampleCount = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: sampleCount))
        let durationSeconds = Double(sampleCount) / format.sampleRate
        let durationMs = max(1, Int64((durationSeconds * 1_000).rounded()))
        let events = try engine.accept(ASRInputFrame(
            sessionId: "release-stress",
            sequence: sequence,
            startMs: startMs,
            durationMs: durationMs,
            sampleRate: Int(format.sampleRate),
            samples: samples
        ))
        partials += events.filter { $0.status == .partial }.count
        finals += events.filter { $0.status == .finalized }.count
        sequence += 1
        startMs += durationMs
        processedSeconds += durationSeconds
    }
}
let tail = try engine.finish()
partials += tail.filter { $0.status == .partial }.count
finals += tail.filter { $0.status == .finalized }.count

var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let elapsed = started.duration(to: clock.now)
let elapsedSeconds = Double(elapsed.components.seconds)
    + Double(elapsed.components.attoseconds) / 1e18
let result = StressResult(
    requestedAudioSeconds: requestedSeconds,
    processedAudioSeconds: processedSeconds,
    elapsedSeconds: elapsedSeconds,
    realTimeFactor: elapsedSeconds / processedSeconds,
    peakRSSBytes: UInt64(usage.ru_maxrss),
    inputFrames: sequence,
    partialEvents: partials,
    finalizedEvents: finals,
    networkAPI: "none"
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(result))
FileHandle.standardOutput.write(Data("\n".utf8))
