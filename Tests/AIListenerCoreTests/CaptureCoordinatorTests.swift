import AVFoundation
import Testing
@testable import AIListenerCore

@Suite
struct CaptureCoordinatorTests {
    @Test(arguments: [
        MicrophoneAuthorization.denied,
        MicrophoneAuthorization.restricted,
    ])
    func blockedPermissionNeverStarts(_ authorization: MicrophoneAuthorization) async {
        let capture = CaptureSpy()
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: authorization, requestResult: false),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )

        await coordinator.startFromExplicitUserAction()

        #expect(await capture.startCount == 0)
        #expect(await coordinator.currentStatus().state == .idle)
        #expect(await coordinator.currentStatus().authorization == authorization)
    }

    @Test
    func notDeterminedRequestsOnceThenRecords() async {
        let permission = PermissionStub(status: .notDetermined, requestResult: true)
        let capture = CaptureSpy()
        let coordinator = CaptureCoordinator(
            permission: permission,
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )

        await coordinator.startFromExplicitUserAction()

        #expect(await permission.requestCount == 1)
        #expect(await capture.startCount == 1)
        #expect(await coordinator.currentStatus().state == .recording)
    }

    @Test
    func authorizedStartsAndStopIsIdempotent() async {
        let capture = CaptureSpy()
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: .authorized, requestResult: true),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )

        await coordinator.startFromExplicitUserAction()
        await coordinator.stop()
        await coordinator.stop()

        #expect(await capture.stopCount == 1)
        #expect(await coordinator.currentStatus().state == .idle)
        #expect(await coordinator.currentStatus().terminationReason == .userStopped)
    }

    @Test
    func missingDeviceCanRetry() async {
        let capture = CaptureSpy(startError: .noInputDevice)
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: .authorized, requestResult: true),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )

        await coordinator.startFromExplicitUserAction()
        #expect(await coordinator.currentStatus().state == .failed)
        #expect(await coordinator.currentStatus().errorCode == "capture.no_input_device")

        await capture.setStartError(nil)
        await coordinator.retry()
        #expect(await coordinator.currentStatus().state == .recording)
    }

    @Test
    func interruptionStopsCaptureAndRecordsReason() async throws {
        let capture = CaptureSpy()
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: .authorized, requestResult: true),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )
        await coordinator.startFromExplicitUserAction()

        await capture.interrupt(.deviceConfigurationChanged)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await coordinator.currentStatus().state == .idle)
        #expect(await coordinator.currentStatus().terminationReason == .deviceConfigurationChanged)
        #expect(await capture.stopCount == 1)
    }
}

private actor PermissionStub: MicrophonePermissionProviding {
    let status: MicrophoneAuthorization
    let requestResult: Bool
    private(set) var requestCount = 0

    init(status: MicrophoneAuthorization, requestResult: Bool) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> MicrophoneAuthorization { status }
    func requestAccess() -> Bool {
        requestCount += 1
        return requestResult
    }
}

private actor CaptureSpy: MicrophoneCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var startError: CaptureError?
    private var interruption: (@Sendable (CaptureTerminationReason) -> Void)?

    init(startError: CaptureError? = nil) {
        self.startError = startError
    }

    func start(
        onFrame: @escaping @Sendable (AudioFrame) -> Void,
        onInterruption: @escaping @Sendable (CaptureTerminationReason) -> Void
    ) throws {
        startCount += 1
        if let startError { throw startError }
        interruption = onInterruption
    }

    func stop() {
        stopCount += 1
    }

    func setStartError(_ error: CaptureError?) {
        startError = error
    }

    func interrupt(_ reason: CaptureTerminationReason) {
        interruption?(reason)
    }
}
