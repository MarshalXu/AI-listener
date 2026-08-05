import AIListenerCore
import AVFoundation
import SwiftUI

/// Audio player bar with waveform visualization, play/pause, timestamp,
/// and rate control. Designed for use at the top of the session detail area.
struct AudioPlayerBar: View {
    @ObservedObject var model: AudioPlayerModel

    var body: some View {
        VStack(spacing: 8) {
            // Waveform + progress
            WaveformView(
                peaks: model.peaks,
                progress: model.progress
            )
            .frame(height: 56)

            // Controls row
            HStack(spacing: 16) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28)
                }
                .buttonStyle(.bordered)

                // Timestamp
                Text("\(model.currentTimestamp) / \(model.durationTimestamp)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                // Rate control
                Picker("倍速", selection: $model.rate) {
                    ForEach(AudioPlayerModel.availableRates, id: \.self) { rate in
                        Text(String(format: "%.1f×", rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// Waveform visualization: renders vertical bars for each peak sample, with a
/// progress overlay highlighting the played portion.
struct WaveformView: View {
    let peaks: [Float]
    let progress: Double // 0.0–1.0

    var body: some View {
        GeometryReader { geo in
            let barSpacing: CGFloat = 2
            let barCount = peaks.isEmpty ? 0 : peaks.count
            let barWidth = barCount > 0
                ? max(1, (geo.size.width - CGFloat(barCount - 1) * barSpacing) / CGFloat(barCount))
                : 0

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(Array(peaks.enumerated()), id: \.offset) { index, peak in
                    let barHeight = max(2, CGFloat(peak) * geo.size.height)
                    let isPlayed = Double(index) / Double(max(1, barCount - 1)) <= progress

                    RoundedRectangle(cornerRadius: 1)
                        .fill(isPlayed ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: barWidth, height: barHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
final class AudioPlayerModel: ObservableObject {
    static let availableRates: [Float] = [0.5, 1.0, 1.5, 2.0]

    @Published var isPlaying = false
    @Published var rate: Float = 1.0 {
        didSet {
            playback?.setRate(rate)
        }
    }
    @Published private(set) var currentMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var peaks: [Float] = []

    private var playback: PlaybackService?
    private var assetURL: URL?
    private var timer: Timer?

    var progress: Double {
        guard durationMs > 0 else { return 0 }
        return Double(currentMs) / Double(durationMs)
    }

    var currentTimestamp: String {
        Self.formatTimestamp(currentMs)
    }

    var durationTimestamp: String {
        Self.formatTimestamp(durationMs)
    }

    func configure(playback: PlaybackService, assetURL: URL?) {
        self.playback = playback
        self.assetURL = assetURL
        self.durationMs = playback.durationMs
        self.currentMs = 0
        self.isPlaying = playback.isPlaying
        loadPeaks()
        startTimer()
    }

    func invalidate() {
        stopTimer()
        playback = nil
        assetURL = nil
        peaks = []
        currentMs = 0
        durationMs = 0
        isPlaying = false
    }

    func togglePlayPause() {
        guard let playback else { return }
        if isPlaying {
            playback.pause()
            isPlaying = false
            stopTimer()
        } else {
            do {
                _ = try playback.resume()
                isPlaying = true
                startTimer()
            } catch {
                // Playback may not be available; silently fail.
            }
        }
    }

    func seek(toMs: Int64) {
        guard let playback else { return }
        playback.pause()
        do {
            _ = try playback.play(atMs: toMs)
            currentMs = toMs
            isPlaying = true
            startTimer()
        } catch {
            currentMs = toMs
        }
    }

    func seekToProgress(_ p: Double) {
        let target = Int64(Double(durationMs) * p)
        seek(toMs: target)
    }

    /// Called by the view model after a transcript/minutes timestamp seek to
    /// sync the bar's state with the now-playing driver.
    func syncAfterSeek() {
        guard let playback else { return }
        currentMs = playback.currentTimeMs
        isPlaying = playback.isPlaying
        if isPlaying { startTimer() }
    }

    private func loadPeaks() {
        guard let url = assetURL else { return }
        let captured = url
        DispatchQueue.global(qos: .userInitiated).async {
            let extracted = (try? WaveformExtractor.peaks(at: captured, bucketCount: 200)) ?? []
            DispatchQueue.main.async { [weak self] in
                self?.peaks = extracted
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let playback else { return }
        currentMs = playback.currentTimeMs
        isPlaying = playback.isPlaying
        if !isPlaying { stopTimer() }
    }

    private static func formatTimestamp(_ ms: Int64) -> String {
        let totalSeconds = ms / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let millis = ms % 1_000
        return String(format: "%02lld:%02lld.%03lld", minutes, seconds, millis)
    }
}
