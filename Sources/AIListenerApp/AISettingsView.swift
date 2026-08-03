import AIListenerCore
import SwiftUI

public struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput: String = ""
    @State private var maskedKeyDisplay: String = "未设置 Key"
    @State private var cloudConsentGranted: Bool = false
    @State private var selectedAIMode: AIMode = .incrementalAndPost
    @State private var selectedAIModel: AIModel = .localMock
    @State private var selectedMinutesStyle: MinutesStyle = .standard
    @State private var statusMessage: String?

    private let keychainManager = KeychainManager.shared
    private let settingsStore = PrivacySettingsStore.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AI 纪要与隐私设置")
                .font(.title2)
                .bold()

            GroupBox(label: Label("Gemini API Key 密钥管理 (macOS Keychain)", systemImage: "key.fill")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("当前 Key：")
                        Text(maskedKeyDisplay)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        SecureField("输入 Gemini API Key...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)

                        Button("保存 Key") {
                            saveApiKey()
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if maskedKeyDisplay != "未设置 Key" {
                            Button("清除 Key", role: .destructive) {
                                clearApiKey()
                            }
                        }
                    }

                    Text("提示：Key 安全存储于 macOS Keychain，绝不会写入本地配置文件或日志。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox(label: Label("隐私提示与模式配置", systemImage: "shield.fill")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("允许逐字稿文本上传至云端 AI 进行处理", isOn: $cloudConsentGranted)
                        .onChange(of: cloudConsentGranted) { _, _ in saveSettings() }

                    Text("注意：若使用云端 Gemini 大模型，逐字稿将离开本机传输至 Google 云端 API 处理；使用“本地 Mock”模式数据不会离开本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Picker("AI 运行模式：", selection: $selectedAIMode) {
                        ForEach(AIMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: selectedAIMode) { _, _ in saveSettings() }

                    Picker("AI 模型选择：", selection: $selectedAIModel) {
                        ForEach(AIModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .onChange(of: selectedAIModel) { _, _ in saveSettings() }

                    Picker("默认纪要风格：", selection: $selectedMinutesStyle) {
                        ForEach(MinutesStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .onChange(of: selectedMinutesStyle) { _, _ in saveSettings() }
                }
                .padding(8)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            loadInitialData()
        }
    }

    private func loadInitialData() {
        let settings = settingsStore.loadSettings()
        cloudConsentGranted = settings.cloudConsentGranted
        selectedAIMode = settings.aiMode
        selectedAIModel = settings.aiModel
        selectedMinutesStyle = settings.minutesStyle

        if let key = try? keychainManager.getApiKey() {
            maskedKeyDisplay = KeychainManager.maskedKey(key)
        } else {
            maskedKeyDisplay = "未设置 Key"
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychainManager.saveApiKey(trimmed)
            maskedKeyDisplay = KeychainManager.maskedKey(trimmed)
            apiKeyInput = ""
            statusMessage = "API Key 已成功加密存入 Keychain"
            saveSettings()
        } catch {
            statusMessage = "Keychain 保存失败: \(error.localizedDescription)"
        }
    }

    private func clearApiKey() {
        do {
            try keychainManager.deleteApiKey()
            maskedKeyDisplay = "未设置 Key"
            statusMessage = "API Key 已从 Keychain 中清除"
            saveSettings()
        } catch {
            statusMessage = "Keychain 清除失败: \(error.localizedDescription)"
        }
    }

    private func saveSettings() {
        let updated = PrivacySettings(
            aiMode: selectedAIMode,
            aiModel: selectedAIModel,
            minutesStyle: selectedMinutesStyle,
            cloudConsentGranted: cloudConsentGranted
        )
        settingsStore.saveSettings(updated)
    }
}
