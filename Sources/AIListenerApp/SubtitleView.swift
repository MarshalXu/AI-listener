import SwiftUI

public struct SubtitleView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @State private var showingSettings = false

    public init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Header bar for drag & controls
            HStack {
                Image(systemName: "captions.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("字幕浮窗")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: { showingSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.setVisible(false) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            // Captions list
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.visibleLines.isEmpty {
                    Text("等待 ASR 实时逐字稿…")
                        .font(.system(size: viewModel.settings.fontSize))
                        .foregroundStyle(viewModel.settings.textColor.opacity(0.6))
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(viewModel.visibleLines) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.text)
                                .font(.system(size: viewModel.settings.fontSize, weight: .medium))
                                .foregroundStyle(line.isPartial ? viewModel.settings.textColor.opacity(0.7) : viewModel.settings.textColor)
                                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(
            Group {
                if viewModel.settings.backgroundMaterialEnabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(viewModel.settings.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(viewModel.settings.opacity))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .popover(isPresented: $showingSettings) {
            SubtitleSettingsView(viewModel: viewModel)
        }
    }
}

public struct SubtitleSettingsView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @State private var availableDisplays: [DisplayInfo] = []

    public init(viewModel: SubtitleViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("字幕浮窗设置")
                .font(.headline)

            Divider()

            // Opacity slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("背景透明度")
                    Spacer()
                    Text(String(format: "%.0f%%", viewModel.settings.opacity * 100))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.settings.opacity, in: 0.1...1.0, step: 0.05)
            }

            // Font size
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("字号大小")
                    Spacer()
                    Text("\(Int(viewModel.settings.fontSize)) pt")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.settings.fontSize, in: 12...36, step: 1)
            }

            // Max lines
            Stepper(value: $viewModel.settings.maxLines, in: 1...10) {
                HStack {
                    Text("最大显示行数")
                    Spacer()
                    Text("\(viewModel.settings.maxLines) 行")
                        .foregroundStyle(.secondary)
                }
            }

            // Background Material
            Toggle("开启毛玻璃效果", isOn: $viewModel.settings.backgroundMaterialEnabled)

            // Text color presets
            VStack(alignment: .leading, spacing: 6) {
                Text("文字颜色")
                HStack(spacing: 12) {
                    ColorButton(hex: "#FFFFFF", name: "纯白", current: viewModel.settings.textColorHex) {
                        viewModel.settings.textColorHex = "#FFFFFF"
                    }
                    ColorButton(hex: "#FFD700", name: "暖黄", current: viewModel.settings.textColorHex) {
                        viewModel.settings.textColorHex = "#FFD700"
                    }
                    ColorButton(hex: "#00FFFF", name: "青蓝", current: viewModel.settings.textColorHex) {
                        viewModel.settings.textColorHex = "#00FFFF"
                    }
                    ColorButton(hex: "#90EE90", name: "浅绿", current: viewModel.settings.textColorHex) {
                        viewModel.settings.textColorHex = "#90EE90"
                    }
                }
            }

            // Display Selector
            VStack(alignment: .leading, spacing: 6) {
                Text("显示器选择")
                Picker("选择显示器", selection: $viewModel.settings.selectedDisplayId) {
                    ForEach(availableDisplays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            availableDisplays = DisplayInfo.availableDisplays()
        }
    }
}

private struct ColorButton: View {
    let hex: String
    let name: String
    let current: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: hex) ?? .white)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(current == hex ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                    )
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
