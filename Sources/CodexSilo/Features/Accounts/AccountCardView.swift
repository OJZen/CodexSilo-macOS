import SwiftUI

struct AccountCardView: View {
    let account: AccountSummary
    let isCollapsed: Bool
    let switching: Bool
    let onSwitch: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isShowingUsageErrorDetails = false
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = AccountCardPresentation(
            account: account,
            isCollapsed: isCollapsed,
            locale: locale
        )
        let toneColor = toneColor(for: presentation.accent)
        let healthPalette = AccountCardHealthPalette(health: presentation.health, colorScheme: colorScheme)

        VStack(alignment: .leading, spacing: isCollapsed ? 7 : 8) {
            header(presentation)

            if isCollapsed {
                compactUsageSection(presentation)
            } else {
                Divider()
                expandedUsageSection(presentation)
            }

            Spacer(minLength: 0)
            footer(presentation)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(isCollapsed ? 10 : 12)
        .background { healthBackdrop(healthPalette) }
        .cardSurface(cornerRadius: LayoutRules.cardRadius, tint: cardSurfaceTint(healthPalette: healthPalette, toneColor: toneColor))
        .shadow(
            color: account.isCurrent ? currentShadowColor : .clear,
            radius: account.isCurrent ? 20 : 0,
            y: account.isCurrent ? 10 : 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: LayoutRules.cardRadius, style: .continuous)
                .strokeBorder(account.isCurrent ? currentBorderColor : .clear, lineWidth: account.isCurrent ? 1.5 : 1)
        )
    }

    private func header(_ presentation: AccountCardPresentation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if account.isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(currentBadgeColor)
                    }

                    Text(presentation.displayAccountName)
                        .font(isCollapsed ? .headline : .headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let subtitleText = presentation.subtitleText {
                    Text(subtitleText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                if usageErrorMessage != nil {
                    usageErrorIndicator
                }

                headerActionButton(
                    titleKey: "common.edit",
                    systemImage: "pencil",
                    accessibilityTitleKey: "common.edit",
                    action: onEdit
                )

                headerActionButton(
                    titleKey: "common.remove",
                    systemImage: "trash",
                    role: .destructive,
                    tint: .red,
                    accessibilityTitleKey: "common.remove",
                    action: onDelete
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .frame(minHeight: isCollapsed ? 34 : 44, alignment: .topLeading)
    }

    private func compactUsageSection(_ presentation: AccountCardPresentation) -> some View {
        HStack(spacing: 10) {
            CompactUsageMetric(
                title: presentation.fiveHourWindow.title,
                remainingPercent: presentation.compactUsage.fiveHourRemainingPercent,
                tint: usageTint(for: presentation.compactUsage.fiveHourRemainingPercent)
            )
            CompactUsageMetric(
                title: presentation.oneWeekWindow.title,
                remainingPercent: presentation.compactUsage.oneWeekRemainingPercent,
                tint: usageTint(for: presentation.compactUsage.oneWeekRemainingPercent)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expandedUsageSection(_ presentation: AccountCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            usageSection(presentation.fiveHourWindow)
            usageSection(presentation.oneWeekWindow)
        }
    }

    private func footer(_ presentation: AccountCardPresentation) -> some View {
        HStack(spacing: 6) {
            if account.isCurrent {
                currentBadge
            } else {
                switchButton(labelStyle: isCollapsed ? .iconOnly : .expanded)
            }

            Spacer(minLength: 0)

            footerMeta(presentation)
        }
        .frame(minHeight: isCollapsed ? 22 : 28, alignment: .bottomLeading)
    }

    private func footerMeta(_ presentation: AccountCardPresentation) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(verbatim: presentation.refreshedAtText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func switchButton(labelStyle: SwitchButtonLabelStyle) -> some View {
        Button(action: onSwitch) {
            if switching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
            } else {
                switch labelStyle {
                case .iconOnly:
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                case .expanded:
                    Label(L10n.tr("accounts.card.switch_to_this"), systemImage: "arrow.left.arrow.right.circle.fill")
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(switching)
        .accessibilityLabel(Text(L10n.tr("accounts.card.switch_to_this")))
    }

    @ViewBuilder
    private func headerActionButton(
        titleKey: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        accessibilityTitleKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            if isCollapsed {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            } else {
                Label(titleKey, systemImage: systemImage)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(tint)
        .accessibilityLabel(Text(L10n.tr(accessibilityTitleKey)))
    }

    private func usageSection(_ window: AccountWindowPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.title)
                .font(.callout.weight(.medium))

            ProgressView(value: window.remainingPercent, total: 100)
                .tint(usageTint(for: window.remainingPercent))
                .controlSize(.small)

            HStack(alignment: .firstTextBaseline) {
                Text(window.remainingText)
                Spacer(minLength: 0)
                Text(window.resetText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var usageErrorIndicator: some View {
        Button {
            isShowingUsageErrorDetails = true
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: isCollapsed ? 28 : 30, height: isCollapsed ? 28 : 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(usageErrorMessage ?? "")
        .accessibilityLabel(Text(L10n.tr("accounts.card.view_error")))
        .popover(isPresented: $isShowingUsageErrorDetails, arrowEdge: .top) {
            usageErrorPopover
        }
    }

    private var usageErrorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.tr("accounts.card.error_title"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)

            Text(usageErrorMessage ?? "")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack {
                Spacer(minLength: 0)

                Button(L10n.tr("common.close")) {
                    isShowingUsageErrorDetails = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var usageErrorMessage: String? {
        let message = account.usageError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }

    private func toneColor(for accent: AccountCardAccent) -> Color {
        switch accent {
        case .orange:
            .orange
        case .pink:
            .pink
        case .gray:
            .gray
        case .indigo:
            .indigo
        case .teal:
            .teal
        }
    }

    private func usageTint(for remainingPercent: Double?) -> Color {
        guard let remainingPercent else { return .green }
        switch remainingPercent {
        case ..<20:
            return .red
        case ..<50:
            return .orange
        default:
            return .green
        }
    }

    @ViewBuilder
    private func healthBackdrop(_ healthPalette: AccountCardHealthPalette?) -> some View {
        if let palette = healthPalette {
            let shape = RoundedRectangle(cornerRadius: LayoutRules.cardRadius, style: .continuous)

            shape
                .fill(
                    LinearGradient(
                        colors: [palette.gradientTop, palette.gradientBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    shape
                        .fill(
                            RadialGradient(
                                colors: [palette.highlight, .clear],
                                center: .topLeading,
                                startRadius: 6,
                                endRadius: 260
                            )
                        )
                }
        }
    }

    private func cardSurfaceTint(
        healthPalette: AccountCardHealthPalette?,
        toneColor: Color
    ) -> Color? {
        if let palette = healthPalette {
            return palette.surfaceTint
        }

        guard account.isCurrent else { return nil }
        return toneColor.opacity(0.04)
    }

    private var currentBorderColor: Color {
        currentBadgeColor.opacity(colorScheme == .dark ? 0.72 : 0.42)
    }

    private var currentBadge: some View {
        Label(L10n.tr("accounts.card.current"), systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(currentBadgeColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(currentBadgeColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
            }
    }

    private var currentBadgeColor: Color {
        .accentColor
    }

    private var currentShadowColor: Color {
        currentBadgeColor.opacity(colorScheme == .dark ? 0.16 : 0.12)
    }
}

private enum SwitchButtonLabelStyle {
    case iconOnly
    case expanded
}

private struct AccountCardHealthPalette {
    let surfaceTint: Color
    let gradientTop: Color
    let gradientBottom: Color
    let highlight: Color
    let border: Color

    init?(health: AccountCardHealth, colorScheme: ColorScheme) {
        switch health {
        case .neutral:
            return nil
        case .success:
            surfaceTint = Color(.sRGB, red: 0.64, green: 0.84, blue: 0.70, opacity: colorScheme == .dark ? 0.06 : 0.05)
            gradientTop = Color(.sRGB, red: 0.78, green: 0.95, blue: 0.84, opacity: colorScheme == .dark ? 0.12 : 0.28)
            gradientBottom = Color(.sRGB, red: 0.95, green: 0.99, blue: 0.96, opacity: colorScheme == .dark ? 0.02 : 0.16)
            highlight = Color(.sRGB, red: 0.98, green: 1.00, blue: 0.99, opacity: colorScheme == .dark ? 0.06 : 0.18)
            border = .green
        case .warning:
            surfaceTint = Color(.sRGB, red: 0.93, green: 0.79, blue: 0.46, opacity: colorScheme == .dark ? 0.06 : 0.05)
            gradientTop = Color(.sRGB, red: 0.99, green: 0.93, blue: 0.73, opacity: colorScheme == .dark ? 0.12 : 0.26)
            gradientBottom = Color(.sRGB, red: 1.00, green: 0.97, blue: 0.90, opacity: colorScheme == .dark ? 0.02 : 0.14)
            highlight = Color(.sRGB, red: 1.00, green: 0.99, blue: 0.94, opacity: colorScheme == .dark ? 0.05 : 0.16)
            border = .orange
        case .critical:
            surfaceTint = Color(.sRGB, red: 0.90, green: 0.62, blue: 0.62, opacity: colorScheme == .dark ? 0.06 : 0.05)
            gradientTop = Color(.sRGB, red: 0.99, green: 0.86, blue: 0.86, opacity: colorScheme == .dark ? 0.11 : 0.24)
            gradientBottom = Color(.sRGB, red: 1.00, green: 0.95, blue: 0.95, opacity: colorScheme == .dark ? 0.02 : 0.13)
            highlight = Color(.sRGB, red: 1.00, green: 0.98, blue: 0.98, opacity: colorScheme == .dark ? 0.04 : 0.14)
            border = .red
        }
    }
}

private struct CompactUsageMetric: View {
    let title: String
    let remainingPercent: Double?
    let tint: Color

    private var clampedProgress: Double {
        guard let remainingPercent else { return 0 }
        return max(0, min(1, remainingPercent / 100))
    }

    private var percentText: String {
        guard let remainingPercent else { return "--" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }

            ProgressView(value: clampedProgress)
                .tint(tint)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}
