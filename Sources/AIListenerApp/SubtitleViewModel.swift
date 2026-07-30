import AIListenerCore
import Combine
import Foundation
import SwiftUI

public struct SubtitleSettings: Codable, Equatable, Sendable {
    public var opacity: Double = 0.85
    public var fontSize: Double = 18.0
    public var textColorHex: String = "#FFFFFF"
    public var backgroundMaterialEnabled: Bool = true
    public var maxLines: Int = 3
    public var selectedDisplayId: String = "main"

    public init(
        opacity: Double = 0.85,
        fontSize: Double = 18.0,
        textColorHex: String = "#FFFFFF",
        backgroundMaterialEnabled: Bool = true,
        maxLines: Int = 3,
        selectedDisplayId: String = "main"
    ) {
        self.opacity = opacity
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.backgroundMaterialEnabled = backgroundMaterialEnabled
        self.maxLines = maxLines
        self.selectedDisplayId = selectedDisplayId
    }

    public var textColor: Color {
        Color(hex: textColorHex) ?? .white
    }
}

extension Color {
    init?(hex: String) {
        let r, g, b, a: Double
        var hexColor = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexColor.hasPrefix("#") {
            hexColor.remove(at: hexColor.startIndex)
        }

        let scanner = Scanner(string: hexColor)
        var hexNumber: UInt64 = 0
        if scanner.scanHexInt64(&hexNumber) {
            if hexColor.count == 6 {
                r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
                g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
                b = Double(hexNumber & 0x0000FF) / 255.0
                a = 1.0
                self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
                return
            } else if hexColor.count == 8 {
                r = Double((hexNumber & 0xFF000000) >> 24) / 255.0
                g = Double((hexNumber & 0x00FF0000) >> 16) / 255.0
                b = Double((hexNumber & 0x0000FF00) >> 8) / 255.0
                a = Double(hexNumber & 0x000000FF) / 255.0
                self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
                return
            }
        }
        return nil
    }
}

@MainActor
public final class SubtitleViewModel: ObservableObject {
    @Published public var settings: SubtitleSettings {
        didSet {
            saveSettings()
        }
    }
    @Published public private(set) var finalizedEvents: [ASRTranscriptEvent] = []
    @Published public private(set) var partialEvents: [ASRTranscriptEvent] = []
    @Published public private(set) var isVisible: Bool = false

    private var busSubscription: TranscriptBusSubscription?
    private let userDefaultsKey = "AIListener.SubtitleSettings"

    public init(settings: SubtitleSettings? = nil) {
        if let settings {
            self.settings = settings
        } else if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let decoded = try? JSONDecoder().decode(SubtitleSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = SubtitleSettings()
        }
    }

    public func connect(to bus: TranscriptEventBus) {
        busSubscription?.cancel()
        busSubscription = bus.subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEvent(event)
            }
        }
    }

    public func disconnect() {
        busSubscription?.cancel()
        busSubscription = nil
    }

    public func clear() {
        finalizedEvents.removeAll()
        partialEvents.removeAll()
    }

    public func toggleVisibility() {
        isVisible.toggle()
    }

    public func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    /// Returns the active lines to display up to `maxLines`.
    public var visibleLines: [SubtitleLine] {
        var lines: [SubtitleLine] = []

        // Finalized segments
        for event in finalizedEvents.suffix(settings.maxLines) {
            lines.append(SubtitleLine(id: event.segmentId, text: event.text, isPartial: false))
        }

        // Partial segments
        if lines.count < settings.maxLines, let latestPartial = partialEvents.last, !latestPartial.text.isEmpty {
            lines.append(SubtitleLine(id: latestPartial.segmentId, text: latestPartial.text + "…", isPartial: true))
        }

        return Array(lines.suffix(settings.maxLines))
    }

    private func handleEvent(_ event: TranscriptBusEvent) {
        switch event {
        case .partials(let partials):
            self.partialEvents = partials
        case .finalized(let finalized):
            self.finalizedEvents.append(finalized)
            self.partialEvents.removeAll()
        case .reset:
            clear()
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
}

public struct SubtitleLine: Identifiable, Equatable {
    public let id: String
    public let text: String
    public let isPartial: Bool

    public init(id: String, text: String, isPartial: Bool) {
        self.id = id
        self.text = text
        self.isPartial = isPartial
    }
}
