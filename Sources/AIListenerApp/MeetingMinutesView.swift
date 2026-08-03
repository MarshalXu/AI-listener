import AIListenerCore
import SwiftUI

public struct MeetingMinutesView: View {
    public let minutes: MeetingMinutes
    public var onSelectTimestamp: ((Int64) -> Void)?

    public init(minutes: MeetingMinutes, onSelectTimestamp: ((Int64) -> Void)? = nil) {
        self.minutes = minutes
        self.onSelectTimestamp = onSelectTimestamp
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(minutes.overview.title)
                            .font(.title2)
                            .bold()
                        Text("风格：\(minutes.style.displayName) | 识别模式：\(minutes.kind == .incremental ? "增量纪要" : "完整纪要")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 4)

                Divider()

                // Overview
                GroupBox(label: Label("会议概览", systemImage: "info.circle.fill")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !minutes.overview.participantSummary.isEmpty {
                            Text(minutes.overview.participantSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(minutes.overview.generalSummary)
                            .font(.body)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Core Summary
                if !minutes.coreSummary.isEmpty {
                    GroupBox(label: Label("核心要点", systemImage: "star.fill")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(minutes.coreSummary, id: \.self) { item in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").bold()
                                    Text(item)
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Topics
                if !minutes.topics.isEmpty {
                    GroupBox(label: Label("章节/议题讨论", systemImage: "list.bullet.indent")) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(minutes.topics) { topic in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(topic.title)
                                        .font(.headline)
                                    Text(topic.summary)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    ForEach(topic.keyPoints, id: \.self) { kp in
                                        Text("  - \(kp)")
                                            .font(.caption)
                                    }
                                }
                                if topic.id != minutes.topics.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Decisions
                if !minutes.decisions.isEmpty {
                    GroupBox(label: Label("关键决策", systemImage: "checkmark.seal.fill")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(minutes.decisions, id: \.self) { decision in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(decision)
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Action Items
                if !minutes.actionItems.isEmpty {
                    GroupBox(label: Label("待办事项", systemImage: "square.and.pencil")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(minutes.actionItems) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.task)
                                            .font(.body)
                                        HStack(spacing: 8) {
                                            if let assignee = item.assignee, !assignee.isEmpty {
                                                Text("负责人: \(assignee)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let dueDate = item.dueDate, !dueDate.isEmpty {
                                                Text("截止时间: \(dueDate)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    if let ts = item.timestampMs, ts > 0, let onSelectTimestamp {
                                        Button {
                                            onSelectTimestamp(ts)
                                        } label: {
                                            Label(formatTimestamp(ts), systemImage: "play.circle")
                                                .font(.caption.monospacedDigit())
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Timestamp References
                if !minutes.timestampReferences.isEmpty {
                    GroupBox(label: Label("原文引语与时间点", systemImage: "clock.fill")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(minutes.timestampReferences) { ref in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("“\(ref.text)”")
                                            .font(.subheadline)
                                            .italic()
                                        Text(ref.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let onSelectTimestamp {
                                        Button {
                                            onSelectTimestamp(ref.startMs)
                                        } label: {
                                            Label(formatTimestamp(ref.startMs), systemImage: "play.circle.fill")
                                                .font(.caption.monospacedDigit())
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
    }

    private func formatTimestamp(_ ms: Int64) -> String {
        let totalSeconds = ms / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
