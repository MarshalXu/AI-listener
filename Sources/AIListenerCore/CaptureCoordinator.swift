import Foundation

public actor CaptureCoordinator {
    public typealias StatusSink = @MainActor @Sendable (CaptureStatus) -> Void
    public typealias EventSink = @Sendable (CaptureEvent) -> Void
    public typealias FrameSink = @Sendable (AudioFrame) -> Void

    private let permission: any MicrophonePermissionProviding
    private let capture: any MicrophoneCapturing
    private let statusSink: StatusSink
    private let eventSink: EventSink
    private let frameSink: FrameSink
    private var status = CaptureStatus()
    private var sequence: UInt64 = 0

    public init(
        permission: any MicrophonePermissionProviding,
        capture: any MicrophoneCapturing,
        statusSink: @escaping StatusSink,
        eventSink: @escaping EventSink,
        frameSink: @escaping FrameSink = { _ in }
    ) {
        self.permission = permission
        self.capture = capture
        self.statusSink = statusSink
        self.eventSink = eventSink
        self.frameSink = frameSink
    }

    public func startFromExplicitUserAction() async {
        guard status.state == .idle || status.state == .failed else {
            emit(kind: "state.transition_rejected", code: "start.\(status.state.rawValue)")
            return
        }

        transition(to: .requestingPermission)
        var authorization = await permission.authorizationStatus()
        if authorization == .notDetermined {
            let granted = await permission.requestAccess()
            authorization = granted ? .authorized : .denied
        }
        status.authorization = authorization

        guard authorization == .authorized else {
            transition(to: .permissionBlocked, code: "permission.\(authorization.rawValue)")
            transition(to: .idle)
            return
        }

        transition(to: .preparing)
        do {
            try await capture.start(
                onFrame: frameSink,
                onInterruption: { [weak self] reason in
                    Task { await self?.interrupt(reason: reason) }
                }
            )
            transition(to: .recording)
        } catch {
            transition(to: .failed, code: captureErrorCode(error))
        }
    }

    public func stop() async {
        guard status.state == .recording || status.state == .interrupted else {
            if status.state != .idle { emit(kind: "state.transition_rejected", code: "stop.\(status.state.rawValue)") }
            return
        }
        if status.terminationReason == nil { status.terminationReason = .userStopped }
        transition(to: .stopping)
        await capture.stop()
        transition(to: .idle)
    }

    public func retry() async {
        guard status.state == .failed || status.state == .idle else {
            emit(kind: "state.transition_rejected", code: "retry.\(status.state.rawValue)")
            return
        }
        await startFromExplicitUserAction()
    }

    public func currentStatus() -> CaptureStatus { status }

    private func interrupt(reason: CaptureTerminationReason) async {
        guard status.state == .recording else { return }
        status.terminationReason = reason
        transition(to: .interrupted, code: "capture.\(reason.rawValue)")
        emit(kind: "captureInterrupted", code: reason.rawValue)
        await stop()
    }

    private func transition(to state: CaptureState, code: String? = nil) {
        status.state = state
        status.errorCode = code
        emit(kind: "stateChanged", code: code)
        let snapshot = status
        Task { @MainActor in statusSink(snapshot) }
    }

    private func emit(kind: String, code: String? = nil) {
        sequence += 1
        eventSink(CaptureEvent(
            sequence: sequence,
            monotonicMilliseconds: DispatchTime.now().uptimeNanoseconds / 1_000_000,
            kind: kind,
            state: status.state,
            code: code
        ))
    }

    private func captureErrorCode(_ error: Error) -> String {
        guard let error = error as? CaptureError else { return "capture.unknown" }
        return switch error {
        case .noInputDevice: "capture.no_input_device"
        case .invalidInputFormat: "capture.invalid_input_format"
        case .engineStartFailed: "capture.engine_start_failed"
        case .tapInstallFailed: "capture.tap_install_failed"
        }
    }
}
