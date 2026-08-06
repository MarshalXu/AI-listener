import AVFoundation
import Foundation
import ObjCExceptionBridge

public final class AVFoundationMicrophoneCapture: MicrophoneCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "ai-listener.microphone-capture")
    private var configurationObserver: NSObjectProtocol?
    private var isRunning = false
    private var onFrame: (@Sendable (AudioFrame) -> Void)?
    private var onInterruption: (@Sendable (CaptureTerminationReason) -> Void)?

    /// Internal seam used by tests to inject a tap-install failure and
    /// exercise the reconnection error path without a real audio device.
    /// In production this is `nil`, which means "use the default
    /// ObjC-bridged `installTap` implementation".
    private let tapInstaller: (@Sendable (AVAudioNode, AVAudioFormat) throws -> Void)?

    public init(tapInstaller: (@Sendable (AVAudioNode, AVAudioFormat) throws -> Void)? = nil) {
        self.tapInstaller = tapInstaller
    }

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

                do {
                    try installTap(on: input, format: format)
                } catch {
                    self.onFrame = nil
                    self.onInterruption = nil
                    continuation.resume(throwing: error)
                    return
                }

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
                    try startEngineCatchingObjCExceptions()
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

    private func installTap(on input: AVAudioNode, format: AVAudioFormat) throws {
        if let tapInstaller {
            try tapInstaller(input, format)
            return
        }
        // AVAudioNode.installTap(onBus:bufferSize:format:block:) raises an
        // Objective-C NSException (not a Swift Error) when the format does
        // not match the audio route currently negotiated by the hardware
        // — notably with Bluetooth HFP/A2DP routes that reconfigure after
        // engine.start(). Swift's do/catch cannot catch NSException, so
        // without this ObjC @try/@catch bridge the exception escapes to
        // objc_exception_throw -> std::terminate -> abort(), killing the
        // app ~4s after the user hits "Start Recording" with AirPods.
        var objcError: NSError?
        let ok = ALExceptionTry(
            { [self] in
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
            },
            &objcError
        )
        if !ok {
            throw CaptureError.tapInstallFailed
        }
    }

    /// Wraps `engine.start()` in the ObjC @try/@catch bridge. `start()` is
    /// documented to throw Swift `Error`s, but the underlying
    /// AVAudioEngineImpl can also raise `NSException` for certain route
    /// states; the bridge guarantees we never abort() here either.
    private func startEngineCatchingObjCExceptions() throws {
        var objcError: NSError?
        var swiftError: Error?
        let ok = ALExceptionTry(
            { [self] in
                do {
                    try self.engine.start()
                } catch {
                    swiftError = error
                }
            },
            &objcError
        )
        if !ok {
            throw CaptureError.engineStartFailed
        }
        if let swiftError {
            throw swiftError
        }
    }

    private func handleConfigurationChange() {
        // When a device configuration change occurs (permission grant,
        // device plug/unplug, Bluetooth route negotiation), attempt to
        // reconnect instead of terminating. Only if reconnection fails
        // do we surface an interruption to the coordinator.
        guard isRunning else { return }

        let input = engine.inputNode
        engine.stop()
        input.removeTap(onBus: 0)

        // Re-query the input format after the route change. Bluetooth
        // HFP/A2DP routes reconfigure sampleRate/channelCount
        // asynchronously, so the pre-change format is likely stale.
        let newFormat = input.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            reportInterruption(.deviceUnavailable)
            return
        }

        // Reconnection: reinstall the tap and restart the engine. Both
        // are wrapped in the ObjC @try/@catch bridge (via installTap and
        // startEngineCatchingObjCExceptions) so that a route/format
        // mismatch raises an NSException that we convert to a Swift
        // error instead of abort()ing the process.
        do {
            try installTap(on: input, format: newFormat)
            engine.prepare()
            try startEngineCatchingObjCExceptions()
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
