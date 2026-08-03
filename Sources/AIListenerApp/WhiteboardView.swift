import SwiftUI
import AIListenerCore

public struct WhiteboardView: View {
    let whiteboardService: WhiteboardService
    @State private var nodes: [WhiteboardNode] = []
    @State private var connections: [WhiteboardConnection] = []
    @State private var isPaused: Bool = false
    @State private var diagnosticCode: String? = nil

    public init(whiteboardService: WhiteboardService) {
        self.whiteboardService = whiteboardService
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar Controls
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "paintpalette.fill")
                        .foregroundStyle(.blue)
                    Text("实时 AI 画板")
                        .font(.headline)
                }

                Spacer()

                if let diag = diagnosticCode {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(diag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                }

                // Pause / Resume
                Button(action: {
                    if isPaused {
                        whiteboardService.resume()
                    } else {
                        whiteboardService.pause()
                    }
                    syncState()
                }) {
                    Label(
                        isPaused ? "恢复更新" : "暂停更新",
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.bordered)
                .tint(isPaused ? .green : .orange)

                // Undo
                Button(action: {
                    whiteboardService.undo()
                    syncState()
                }) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("撤销")

                // Redo
                Button(action: {
                    whiteboardService.redo()
                    syncState()
                }) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.bordered)
                .help("重做")

                // Clear
                Button(action: {
                    whiteboardService.clear()
                    syncState()
                }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("清空画板")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Canvas WebView
            ZStack {
                WhiteboardWebView(
                    nodes: nodes,
                    connections: connections,
                    onUserEditedNode: { updatedNode in
                        let action = WhiteboardAction(kind: .updateNode, node: updatedNode)
                        whiteboardService.applyActions([action], recordUndo: true)
                        syncState()
                    }
                )

                if nodes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.dashed")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("等待 ASR 稳定逐字稿增量生成画板节点…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            syncState()
        }
    }

    private func syncState() {
        nodes = whiteboardService.nodes
        connections = whiteboardService.connections
        isPaused = whiteboardService.isPaused
        diagnosticCode = whiteboardService.lastDiagnosticCode
    }
}
