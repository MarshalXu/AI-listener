import AIListenerCore
import AppKit
import Combine
import SwiftUI

@MainActor
public final class SubtitleWindowController: ObservableObject {
    public let viewModel: SubtitleViewModel
    private var panel: SubtitlePanel?
    private var cancellables = Set<AnyCancellable>()

    public init(viewModel: SubtitleViewModel = SubtitleViewModel()) {
        self.viewModel = viewModel

        viewModel.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                if visible {
                    self?.showPanel()
                } else {
                    self?.hidePanel()
                }
            }
            .store(in: &cancellables)

        viewModel.$settings
            .map(\.selectedDisplayId)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displayId in
                self?.panel?.positionOnScreen(displayId: displayId)
            }
            .store(in: &cancellables)
    }

    public func connectBus(_ bus: TranscriptEventBus) {
        viewModel.connect(to: bus)
    }

    public func showWindow() {
        viewModel.setVisible(true)
    }

    public func hideWindow() {
        viewModel.setVisible(false)
    }

    public func toggleWindow() {
        viewModel.toggleVisibility()
    }

    private func showPanel() {
        if panel == nil {
            let panel = SubtitlePanel()
            let hostingView = NSHostingView(rootView: SubtitleView(viewModel: viewModel))
            panel.contentView = hostingView
            self.panel = panel
        }
        panel?.positionOnScreen(displayId: viewModel.settings.selectedDisplayId)
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }
}
