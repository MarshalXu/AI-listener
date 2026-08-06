import AVFoundation
import Foundation

public enum MicrophoneAuthorization: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

public protocol MicrophonePermissionProviding: Sendable {
    func authorizationStatus() async -> MicrophoneAuthorization
    func requestAccess() async -> Bool
}

public struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    public init() {}

    public func authorizationStatus() async -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .restricted
        }
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public struct AudioFrame: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let monotonicNanoseconds: UInt64

    public init(buffer: AVAudioPCMBuffer, monotonicNanoseconds: UInt64) {
        self.buffer = buffer
        self.monotonicNanoseconds = monotonicNanoseconds
    }
}

public enum CaptureTerminationReason: String, Sendable, Equatable {
    case userStopped
    case deviceUnavailable
    case deviceConfigurationChanged
    case engineFailure

    /// 人类可读的中文描述，用于 UI 展示，替代裸 rawValue。
    public var localizedDescription: String {
        switch self {
        case .userStopped: "用户停止"
        case .deviceUnavailable: "音频设备不可用"
        case .deviceConfigurationChanged: "音频设备配置变化"
        case .engineFailure: "音频引擎启动失败"
        }
    }
}

public protocol MicrophoneCapturing: Sendable {
    func start(
        onFrame: @escaping @Sendable (AudioFrame) -> Void,
        onInterruption: @escaping @Sendable (CaptureTerminationReason) -> Void
    ) async throws
    func stop() async
}

public enum CaptureError: Error, Sendable, Equatable {
    case noInputDevice
    case invalidInputFormat
    case engineStartFailed
    case tapInstallFailed
}
