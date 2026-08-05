import AVFoundation
import Foundation

/// Pure-function PCM peak extractor for waveform visualization.
///
/// `WaveformExtractor` reads a CAF/WAV audio file as mono PCM Float32 samples
/// and reduces them into a fixed number of buckets, each holding the peak
/// (max absolute) amplitude in that range. The algorithm is deterministic and
/// side-effect free given the same file and bucket count, which makes it
/// unit-testable without a live audio engine.
public enum WaveformExtractor {

    public enum WaveformError: Error, Equatable {
        case fileUnreadable
        case unsupportedFormat
        case noSamples
    }

    /// Extracts `bucketCount` peak amplitudes (0.0–1.0) from the audio file at
    /// `url`. Samples are down-mixed to mono before bucketing. Returns an empty
    /// array only when `bucketCount` is zero; otherwise raises `WaveformError`.
    ///
    /// - Parameters:
    ///   - url: Audio file URL (CAF/WAV/etc. readable by `AVAudioFile`).
    ///   - bucketCount: Number of waveform bars to produce (e.g. 200).
    /// - Returns: Array of `bucketCount` floats in [0, 1].
    public static func peaks(
        at url: URL,
        bucketCount: Int = 200
    ) throws -> [Float] {
        guard bucketCount > 0 else { return [] }
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            throw WaveformError.fileUnreadable
        }
        let format = audioFile.processingFormat
        guard format.channelCount > 0,
              format.sampleRate > 0 else {
            throw WaveformError.unsupportedFormat
        }

        let totalFrames = AVAudioFrameCount(audioFile.length)
        guard totalFrames > 0 else { throw WaveformError.noSamples }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: totalFrames
        ) else {
            throw WaveformError.unsupportedFormat
        }
        try audioFile.read(into: buffer, frameCount: totalFrames)

        return peaks(from: buffer, bucketCount: bucketCount)
    }

    /// Extracts peak amplitudes directly from a PCM buffer. Exposed for tests
    /// that synthesize buffers in memory without touching the filesystem.
    public static func peaks(
        from buffer: AVAudioPCMBuffer,
        bucketCount: Int = 200
    ) -> [Float] {
        guard bucketCount > 0, buffer.frameLength > 0 else {
            return []
        }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return [] }
        guard let channels = buffer.floatChannelData else { return [] }

        var peaks: [Float] = [Float](repeating: 0, count: bucketCount)
        let framesPerBucket = max(1, frameLength / bucketCount)

        // Normalize by the largest peak across all channels so the waveform
        // fills the available vertical range regardless of input gain.
        var globalMax: Float = 0
        var bucketMax: [Float] = [Float](repeating: 0, count: bucketCount)
        for bucketIndex in 0..<bucketCount {
            let start = bucketIndex * framesPerBucket
            let end = min(start + framesPerBucket, frameLength)
            guard start < end else { continue }
            var peak: Float = 0
            for frame in start..<end {
                // Down-mix to mono: average across channels, take absolute.
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channels[ch][frame]
                }
                let sample = abs(sum / Float(channelCount))
                if sample > peak { peak = sample }
            }
            bucketMax[bucketIndex] = peak
            if peak > globalMax { globalMax = peak }
        }

        // Normalize to [0, 1]. If the file is silent, leave at 0.
        let scale: Float = globalMax > 0 ? 1.0 / globalMax : 0.0
        for i in 0..<bucketCount {
            peaks[i] = bucketMax[i] * scale
        }
        return peaks
    }
}
