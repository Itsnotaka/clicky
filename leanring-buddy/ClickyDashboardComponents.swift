//
//  ClickyDashboardComponents.swift
//  leanring-buddy
//
//  Shared native SwiftUI components for the Clicky dashboard.
//

import SwiftUI

struct ClickyDashboardCard<Content: View>: View {
    private let title: String?
    private let subtitle: String?
    private let content: () -> Content

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(DS.Colors.textPrimary)
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 12, y: 6)
    }
}

struct ClickyDashboardMetricCard: View {
    let title: String
    let value: String
    let systemImageName: String

    var body: some View {
        ClickyDashboardCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImageName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DS.Colors.accentSubtle))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text(value)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

struct ClickyDashboardPermissionMetricCard: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        ClickyDashboardMetricCard(
            title: title,
            value: isGranted ? "Granted" : "Missing",
            systemImageName: isGranted ? "checkmark.shield" : "exclamationmark.triangle"
        )
    }
}

struct ClickyDashboardControlRow<TrailingContent: View>: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    private let trailingContent: () -> TrailingContent

    init(
        title: String,
        subtitle: String,
        systemImageName: String,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.trailingContent = trailingContent
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            trailingContent()
        }
        .padding(.vertical, 10)
    }
}

struct ClickyDashboardInfoRow: View {
    let title: String
    let value: String
    let systemImageName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImageName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

struct ClickyDashboardEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}

struct ClickyDashboardBackground: View {
    var body: some View {
        ZStack {
            DS.Colors.background

            RadialGradient(
                colors: [DS.Colors.accent.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
            .allowsHitTesting(false)

            LinearGradient(
                colors: [Color.black.opacity(0.12), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}
