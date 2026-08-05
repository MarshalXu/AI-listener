import AVFoundation
import Foundation

public final class AVFoundationMicrophoneCapture: MicrophoneCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "ai-listener.microphone-capture")
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false
    private var onFrame: (@Sendable (AudioFrame) -> Void)?
    private var onInterruption: (@Sendable (CaptureTerminationReason) -> Void)?

    public init() {}

    public func start(
        onFrame: @escaping @Sendable (AudioFrame) -> Void,
        onInterruption: @escaping @Sendable (CaptureTerminationReason) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !isRunning else {
                    continuation.resume()
                    return
                }
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.microphone],
                    mediaType: .audio,
                    position: .unspecified
                )
                guard !discovery.devices.isEmpty else {
                    continuation.resume(throwing: CaptureError.noInputDevice)
                    return
                }

                self.onFrame = onFrame
                self.onInterruption = onInterruption

                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    continuation.resume(throwing: CaptureError.invalidInputFormat)
                    return
                }

                installTap(on: input, format: format)

                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.handleConfigurationChange() }
                }

                engine.prepare()
                do {
                    try engine.start()
                    isRunning = true
                    continuation.resume()
                } catch {
                    input.removeTap(onBus: 0)
                    removeObserver()
                    self.onFrame = nil
                    self.onInterruption = nil
                    continuation.resume(throwing: CaptureError.engineStartFailed)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if isRunning {
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                    isRunning = false
                }
                removeObserver()
                onFrame = nil
                onInterruption = nil
                continuation.resume()
            }
        }
    }

    private func installTap(on input: AVAudioNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self, let onFrame = self.onFrame else { return }
            guard let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            ) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                let byteCount = Int(source[index].mDataByteSize)
                guard
                    let sourceData = source[index].mData,
                    let destinationData = destination[index].mData
                else { continue }
                destinationData.copyMemory(from: sourceData, byteCount: byteCount)
            }
            onFrame(AudioFrame(
                buffer: copy,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
        }
    }

    private func handleConfigurationChange() {
        // When a device configuration change occurs (permission grant, device
        // plug/unplug, route change), attempt to reconnect instead of
        // terminating. Only if reconnection fails do we surface an
        // interruption to the coordinator.
        guard isRunning else { return }

        let input = engine.inputNode
        engine.stop()
        input.removeTap(onBus: 0)

        do {
            let newFormat = input.outputFormat(forBus: 0)
            guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
                reportInterruption(.deviceUnavailable)
                return
            }
            installTap(on: input, format: newFormat)
            engine.prepare()
            try engine.start()
            // Reconnection succeeded; capture continues without interruption.
        } catch {
            reportInterruption(.engineFailure)
        }
    }

    private func reportInterruption(_ reason: CaptureTerminationReason) {
        isRunning = false
        onInterruption?(reason)
    }

    private func removeObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }
}
