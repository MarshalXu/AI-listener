import Foundation
import Testing
import ObjCExceptionBridge

/// XUC-16 regression coverage for the ObjC @try/@catch bridge that
/// prevents `AVAudioNode.installTap` / `AVAudioEngine.start` from
/// aborting the process when they raise an Objective-C `NSException`
/// (not a Swift `Error`) under a Bluetooth route mismatch.
///
/// Swift's `do/catch` cannot capture an `NSException`; without this
/// bridge the exception escapes to `objc_exception_throw` ->
/// `std::terminate` -> `abort()`, killing the app ~4s after the user
/// taps "Start Recording" with AirPods connected.
@Suite
struct ObjCExceptionBridgeTests {
    @Test
    func returnsYesAndNoErrorWhenBlockSucceeds() {
        var error: NSError?
        var ran = false
        let ok = ALExceptionTry({ ran = true }, &error)
        #expect(ok)
        #expect(error == nil)
        #expect(ran)
    }

    @Test
    func catchesNSExceptionAndProducesNSError() {
        // NSArray.object(at:) raises NSRangeException — an Objective-C
        // NSException that Swift do/catch cannot intercept.
        var error: NSError?
        let ok = ALExceptionTry(
            { _ = NSArray().object(at: 99) },
            &error
        )
        #expect(!ok)
        #expect(error != nil)
        // The bridge maps the exception name into localizedDescription.
        #expect(error?.localizedDescription.contains("Range") == true)
    }

    @Test
    func caughtErrorIsAIListenerDomain() {
        var error: NSError?
        _ = ALExceptionTry(
            { _ = NSArray().object(at: 5) },
            &error
        )
        #expect(error?.domain == "AIListener.ObjCExceptionBridge")
        #expect(error?.code == 1)
    }
}
