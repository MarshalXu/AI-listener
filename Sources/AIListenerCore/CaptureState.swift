import Foundation

public enum CaptureState: String, Sendable, Equatable {
    case idle
    case requestingPermission
    case permissionBlocked
    case preparing
    case recording
    case interrupted
    case stopping
    case failed
}

public struct CaptureStatus: Sendable, Equatable {
    public var state: CaptureState
    public var authorization: MicrophoneAuthorization
    public var errorCode: String?
    public var terminationReason: CaptureTerminationReason?

    public init(
        state: CaptureState = .idle,
        authorization: MicrophoneAuthorization = .notDetermined,
        errorCode: String? = nil,
        terminationReason: CaptureTerminationReason? = nil
    ) {
        self.state = state
        self.authorization = authorization
        self.errorCode = errorCode
        self.terminationReason = terminationReason
    }
}

public struct CaptureEvent: Sendable, Equatable {
    public static let contractVersion = "ai-listener.contracts/1.0"

    public let id: UUID
    public let sequence: UInt64
    public let monotonicMilliseconds: UInt64
    public let kind: String
    public let state: CaptureState
    public let code: String?

    public init(
        id: UUID = UUID(),
        sequence: UInt64,
        monotonicMilliseconds: UInt64,
        kind: String,
        state: CaptureState,
        code: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.monotonicMilliseconds = monotonicMilliseconds
        self.kind = kind
        self.state = state
        self.code = code
    }
}
