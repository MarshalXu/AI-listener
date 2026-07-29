import AVFoundation
import Foundation

public final class AVFoundationMicrophoneCapture: MicrophoneCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "ai-listener.microphone-capture")
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false

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

                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    continuation.resume(throwing: CaptureError.invalidInputFormat)
                    return
                }

                input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
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

                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange,
                    object: engine,
                    queue: nil
                ) { _ in
                    onInterruption(.deviceConfigurationChanged)
                }

                engine.prepare()
                do {
                    try engine.start()
                    isRunning = true
                    continuation.resume()
                } catch {
                    input.removeTap(onBus: 0)
                    removeObserver()
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
                continuation.resume()
            }
        }
    }

    private func removeObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }
}
