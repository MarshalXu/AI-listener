import AppKit

/// Helper for retrieving stable display identifiers and resolving display positioning across launches.
public enum DisplayHelper {
    /// Returns a stable display identifier for an `NSScreen` backed by CoreGraphics `CGDirectDisplayID` (`NSScreenNumber`).
    /// Unlike `NSScreen.hashValue` (which uses process-randomized hash seeds across restarts), `CGDirectDisplayID`
    /// is persistent across application relaunches for the same physical display.
    public static func displayID(for screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return String(screenNumber.uint32Value)
        }
        return screen.localizedName
    }

    /// Resolves the target screen from a saved display ID string.
    ///
    /// - Parameters:
    ///   - displayId: Saved display identifier (e.g. CGDirectDisplayID string or "main").
    ///   - screens: Currently available screens list (`NSScreen.screens`).
    ///   - mainScreen: Primary screen fallback (`NSScreen.main`).
    /// - Returns: Target `NSScreen` to position on. If `displayId` is "main" or the referenced display
    ///   disappeared/disconnected, gracefully falls back to `mainScreen` (or first available screen).
    public static func resolveTargetScreen(
        displayId: String,
        screens: [NSScreen],
        mainScreen: NSScreen?
    ) -> NSScreen? {
        guard !screens.isEmpty else { return nil }
        if displayId != "main",
           let screen = screens.first(where: { displayID(for: $0) == displayId || $0.localizedName == displayId }) {
            return screen
        }
        return mainScreen ?? screens[0]
    }
}
