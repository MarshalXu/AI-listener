import AppKit
import AIListenerCore
import SwiftUI

@MainActor
public final class SubtitlePanel: NSPanel {
    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 640, height: 160)) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
    }

    /// Positions the floating window on the target screen based on display selection.
    /// Does NOT request or use any Screen Recording permissions.
    public func positionOnScreen(displayId: String) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        guard let targetScreen = DisplayHelper.resolveTargetScreen(
            displayId: displayId,
            screens: screens,
            mainScreen: NSScreen.main
        ) else { return }

        let visibleFrame = targetScreen.visibleFrame
        let windowWidth: CGFloat = min(680, visibleFrame.width * 0.8)
        let windowHeight: CGFloat = 140
        let x = visibleFrame.midX - (windowWidth / 2)
        let y = visibleFrame.minY + 40

        self.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true, animate: true)
    }
}

/// Helper struct for listing available displays safely via AppKit.
public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    @MainActor
    public static func availableDisplays() -> [DisplayInfo] {
        var displays: [DisplayInfo] = [
            DisplayInfo(id: "main", name: "主显示器")
        ]
        for (index, screen) in NSScreen.screens.enumerated() {
            let id = DisplayHelper.displayID(for: screen)
            let name = screen.localizedName.isEmpty ? "显示器 \(index + 1)" : screen.localizedName
            if !displays.contains(where: { $0.id == id }) {
                displays.append(DisplayInfo(id: id, name: name))
            }
        }
        return displays
    }
}
