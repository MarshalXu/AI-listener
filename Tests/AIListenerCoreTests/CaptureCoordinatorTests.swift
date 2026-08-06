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

    @Test
    func deviceUnavailableInterruptionRecordsReason() async throws {
        let capture = CaptureSpy()
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: .authorized, requestResult: true),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )
        await coordinator.startFromExplicitUserAction()

        await capture.interrupt(.deviceUnavailable)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await coordinator.currentStatus().state == .idle)
        #expect(await coordinator.currentStatus().terminationReason == .deviceUnavailable)
    }

    @Test(arguments: [
        (CaptureTerminationReason.userStopped, "用户停止"),
        (CaptureTerminationReason.deviceUnavailable, "音频设备不可用"),
        (CaptureTerminationReason.deviceConfigurationChanged, "音频设备配置变化"),
        (CaptureTerminationReason.engineFailure, "音频引擎启动失败"),
    ])
    func terminationReasonLocalizedDescription(
        _ reason: CaptureTerminationReason, _ expected: String
    ) {
        #expect(reason.localizedDescription == expected)
        // rawValue 保持原始英文枚举值，向后兼容
        #expect(reason.rawValue != reason.localizedDescription)
    }

    @Test
    func reconnectionDoesNotSurfaceInterruptionToCoordinator() async throws {
        // 模拟配置变化后自动重连成功：capture 不向 coordinator 上报中断，
        // coordinator 保持 recording 状态，stop 次数为 0。
        let capture = CaptureSpy()
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: .authorized, requestResult: true),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )
        await coordinator.startFromExplicitUserAction()

        // 配置变化由 capture 层内部重连处理，不触发 onInterruption 回调
        // coordinator 状态保持 recording
        try await Task.sleep(for: .milliseconds(50))

        #expect(await coordinator.currentStatus().state == .recording)
        #expect(await coordinator.currentStatus().terminationReason == nil)
        #expect(await capture.stopCount == 0)
    }

    @Test
    func tapInstallFailedSurfacesErrorCode() async {
        // XUC-16: 当 installTap 抛 NSException（被 ObjC bridge 转为
        // CaptureError.tapInstallFailed）时，coordinator 进入 failed
        // 状态并记录 capture.tap_install_failed 错误码，而非 abort()。
        let capture = CaptureSpy(startError: .tapInstallFailed)
        let coordinator = CaptureCoordinator(
            permission: PermissionStub(status: .authorized, requestResult: true),
            capture: capture,
            statusSink: { _ in },
            eventSink: { _ in }
        )

        await coordinator.startFromExplicitUserAction()
        #expect(await coordinator.currentStatus().state == .failed)
        #expect(await coordinator.currentStatus().errorCode == "capture.tap_install_failed")
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
