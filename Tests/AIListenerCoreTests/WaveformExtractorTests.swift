import AVFoundation
import Foundation
import Testing
@testable import AIListenerCore

@Suite
struct WaveformExtractorTests {

    @Test func zeroBucketsReturnsEmpty() throws {
        let url = try makeSilentFile()
        let peaks = try WaveformExtractor.peaks(at: url, bucketCount: 0)
        #expect(peaks.isEmpty)
    }

    @Test func silentFileProducesAllZeroPeaks() throws {
        let url = try makeSilentFile()
        let peaks = try WaveformExtractor.peaks(at: url, bucketCount: 50)
        #expect(peaks.count == 50)
        #expect(peaks.allSatisfy { $0 == 0 })
    }

    @Test func uniformLoudFileProducesNormalizedPeaks() throws {
        // A file where every sample is at full amplitude (1.0) should produce
        // all-1.0 peaks after normalization.
        let url = try makeUniformFile(amplitude: 1.0)
        let peaks = try WaveformExtractor.peaks(at: url, bucketCount: 20)
        #expect(peaks.count == 20)
        #expect(peaks.allSatisfy { abs($0 - 1.0) < 0.01 })
    }

    @Test func peakInFirstHalfOnlyHasHighEarlyBuckets() throws {
        // First quarter of samples at full amplitude, rest silent — ensures
        // late buckets are fully within the silent region regardless of
        // minor frame-count rounding when reading back the CAF.
        let url = try makeFile { index in
            index < 4_000 ? 1.0 : 0.0
        }
        let peaks = try WaveformExtractor.peaks(at: url, bucketCount: 10)
        #expect(peaks.count == 10)
        // Early buckets should be near 1.0, late buckets fully silent.
        let earlyMax = peaks.prefix(2).max() ?? 0
        let lateMax = peaks.suffix(5).max() ?? 0
        #expect(earlyMax > 0.9, "early buckets should be near 1.0, got earlyMax=\(earlyMax)")
        #expect(lateMax == 0, "late buckets should be silent, got lateMax=\(lateMax)")
        // The global peak should be 1.0 after normalization.
        #expect(peaks.max() ?? 0 == 1.0)
    }

    @Test func peaksFromBufferMatchesFileBasedExtraction() throws {
        let url = try makeUniformFile(amplitude: 0.5)
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            Issue.record("failed to open audio file")
            return
        }
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("failed to create buffer")
            return
        }
        try audioFile.read(into: buffer, frameCount: frameCount)

        let fromFile = try WaveformExtractor.peaks(at: url, bucketCount: 15)
        let fromBuffer = WaveformExtractor.peaks(from: buffer, bucketCount: 15)
        #expect(fromFile.count == fromBuffer.count)
        for (a, b) in zip(fromFile, fromBuffer) {
            #expect(abs(a - b) < 0.001)
        }
    }

    // MARK: - Fixtures

    private func makeSilentFile() throws -> URL {
        try makeFile { _ in 0.0 }
    }

    private func makeUniformFile(amplitude: Float) throws -> URL {
        try makeFile { _ in amplitude }
    }

    private func makeFile(sampleProvider: (Int) -> Float) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "test.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frameCapacity: AVAudioFrameCount = 16_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
        buffer.frameLength = frameCapacity
        for i in 0..<Int(frameCapacity) {
            buffer.floatChannelData![0][i] = sampleProvider(i)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
