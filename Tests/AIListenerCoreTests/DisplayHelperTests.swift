import AIListenerCore
import AppKit
import Testing

struct DisplayHelperTests {
    @Test("Test displayID extraction returns non-empty string based on CGDirectDisplayID")
    func testDisplayIDExtraction() {
        let screens = NSScreen.screens
        guard let firstScreen = screens.first else { return }

        let id = DisplayHelper.displayID(for: firstScreen)
        #expect(!id.isEmpty)

        if let screenNumber = firstScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            #expect(id == String(screenNumber.uint32Value))
        } else {
            #expect(id == firstScreen.localizedName)
        }
    }

    @Test("Test resolveTargetScreen resolves main display, explicit display ID, and fallbacks when display disappears")
    func testResolveTargetScreen() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let mainScreen = NSScreen.main ?? screens[0]

        // Case 1: displayId is "main" -> returns mainScreen
        let resolvedMain = DisplayHelper.resolveTargetScreen(
            displayId: "main",
            screens: screens,
            mainScreen: mainScreen
        )
        #expect(resolvedMain == mainScreen)

        // Case 2: displayId matches an available screen
        let firstScreenID = DisplayHelper.displayID(for: screens[0])
        let resolvedFirst = DisplayHelper.resolveTargetScreen(
            displayId: firstScreenID,
            screens: screens,
            mainScreen: mainScreen
        )
        #expect(resolvedFirst == screens[0])

        // Case 3: displayId is invalid / disappeared screen -> falls back to mainScreen
        let resolvedDisappeared = DisplayHelper.resolveTargetScreen(
            displayId: "disappeared-display-id-999999",
            screens: screens,
            mainScreen: mainScreen
        )
        #expect(resolvedDisappeared == mainScreen)
    }
}
