//
//  ClickyDashboardLogsSection.swift
//  leanring-buddy
//
//  Structured local log viewer for the Clicky dashboard.
//

import SwiftUI

struct ClickyDashboardLogsSection: View {
    let recentLogEntries: [ClickyMessageLogDisplayEntry]
    let logDirectory: URL
    let refreshLogs: () -> Void
    let openLogsFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ClickyDashboardCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local structured logs")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(DS.Colors.textPrimary)

                        Text(logDirectory.path)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: refreshLogs) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()

                    Button(action: openLogsFolder) {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .pointerCursor()
                }
            }

            ClickyDashboardCard(title: "Recent events", subtitle: "Newest events first. Sensitive key-like fields are redacted before writing.") {
                if recentLogEntries.isEmpty {
                    ClickyDashboardEmptyState(text: "No log entries yet. Computer-use refreshes and dashboard actions will appear here.")
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(recentLogEntries) { logEntry in
                            ClickyDashboardLogEntryRow(logEntry: logEntry)
                        }
                    }
                }
            }
        }
    }
}

struct ClickyDashboardLogEntryRow: View {
    let logEntry: ClickyMessageLogDisplayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(logEntry.lane)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(DS.Colors.accentSubtle))

                Text(logEntry.direction)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                Text(logEntry.event)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text("\(logEntry.sourceFileName):\(logEntry.sourceLineNumber)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if !logEntry.fieldsSummary.isEmpty {
                Text(logEntry.fieldsSummary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            Text(logEntry.timestamp)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }
}
