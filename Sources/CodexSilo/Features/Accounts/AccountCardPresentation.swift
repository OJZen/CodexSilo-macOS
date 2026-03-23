import Foundation

enum AccountCardAccent: Equatable {
    case orange
    case pink
    case gray
    case indigo
    case teal
}

enum AccountCardHealth: Equatable {
    case neutral
    case success
    case warning
    case critical
}

struct AccountWindowPresentation: Equatable {
    let title: String
    let usedPercent: Double
    let remainingPercent: Double
    let usedText: String
    let remainingText: String
    let resetText: String
}

struct AccountCompactUsagePresentation: Equatable {
    let fiveHourRemainingPercent: Double?
    let oneWeekRemainingPercent: Double?
}

struct AccountCardPresentation: Equatable {
    let accent: AccountCardAccent
    let health: AccountCardHealth
    let planLabel: String
    let displayAccountName: String
    let subtitleText: String?
    let refreshedAtText: String
    let fiveHourWindow: AccountWindowPresentation
    let oneWeekWindow: AccountWindowPresentation
    let compactUsage: AccountCompactUsagePresentation

    init(account: AccountSummary, isCollapsed: Bool, locale: Locale) {
        let planLabel = account.normalizedPlanLabel
        let fiveHourRemainingPercent = Self.compactRemainingPercent(account.usage?.fiveHour)
        let oneWeekRemainingPercent = Self.compactRemainingPercent(account.usage?.oneWeek)

        self.planLabel = planLabel
        accent = Self.accent(for: planLabel)
        health = Self.health(
            fiveHourRemainingPercent: fiveHourRemainingPercent,
            oneWeekRemainingPercent: oneWeekRemainingPercent
        )
        displayAccountName = Self.primaryDisplayName(for: account, isCollapsed: isCollapsed)
        subtitleText = Self.subtitleText(for: account, isCollapsed: isCollapsed)
        refreshedAtText = Self.formatRefreshAt(account.usage?.fetchedAt ?? account.updatedAt, locale: locale)
        fiveHourWindow = Self.windowPresentation(
            title: L10n.tr("accounts.window.five_hour"),
            window: account.usage?.fiveHour,
            locale: locale
        )
        oneWeekWindow = Self.windowPresentation(
            title: L10n.tr("accounts.window.one_week"),
            window: account.usage?.oneWeek,
            locale: locale
        )
        compactUsage = AccountCompactUsagePresentation(
            fiveHourRemainingPercent: fiveHourRemainingPercent,
            oneWeekRemainingPercent: oneWeekRemainingPercent
        )
    }

    private static func accent(for planLabel: String) -> AccountCardAccent {
        switch planLabel {
        case "PRO":
            .orange
        case "PLUS":
            .pink
        case "FREE":
            .gray
        case "ENTERPRISE", "BUSINESS":
            .indigo
        default:
            .teal
        }
    }

    private static func primaryDisplayName(for account: AccountSummary, isCollapsed: Bool) -> String {
        let label = trimmed(account.label)
        if !label.isEmpty {
            return label
        }

        let raw = trimmed(account.email ?? account.accountID)
        guard isCollapsed,
              let atIndex = raw.firstIndex(of: "@"),
              atIndex > raw.startIndex else {
            return raw
        }
        return String(raw[..<atIndex])
    }

    private static func subtitleText(for account: AccountSummary, isCollapsed: Bool) -> String? {
        let teamName = trimmed(account.displayTeamName)
        let email = trimmed(account.email)
        let hasExplicitLabel = !trimmed(account.label).isEmpty

        if isCollapsed {
            guard hasExplicitLabel, !email.isEmpty else { return nil }
            return email
        }

        var parts: [String] = []

        if !teamName.isEmpty {
            parts.append(teamName)
        }

        if hasExplicitLabel, !email.isEmpty {
            parts.append(email)
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private static func windowPresentation(
        title: String,
        window: UsageWindow?,
        locale: Locale
    ) -> AccountWindowPresentation {
        let usedRaw = clamped(window?.usedPercent, fallback: 100)
        let used = roundedPercent(usedRaw)
        let remaining = max(0, 100 - used)
        return AccountWindowPresentation(
            title: title,
            usedPercent: used,
            remainingPercent: remaining,
            usedText: L10n.tr("accounts.window.used_format", percent(used)),
            remainingText: L10n.tr("accounts.window.remaining_format", percent(remaining)),
            resetText: L10n.tr("accounts.window.reset_at_format", formatResetAt(window?.resetAt, locale: locale))
        )
    }

    private static func compactRemainingPercent(_ window: UsageWindow?) -> Double? {
        guard let used = window?.usedPercent else { return nil }
        return roundedPercent(max(0, 100 - clamped(used, fallback: used)))
    }

    private static func health(
        fiveHourRemainingPercent: Double?,
        oneWeekRemainingPercent: Double?
    ) -> AccountCardHealth {
        let remainingValues = [fiveHourRemainingPercent, oneWeekRemainingPercent].compactMap { $0 }
        guard !remainingValues.isEmpty else { return .neutral }

        if remainingValues.contains(where: { $0 < 20 }) {
            return .critical
        }

        if remainingValues.contains(where: { $0 < 50 }) {
            return .warning
        }

        return remainingValues.count == 2 ? .success : .neutral
    }

    private static func clamped(_ value: Double?, fallback: Double) -> Double {
        guard let value else { return fallback }
        return max(0, min(100, value))
    }

    private static func roundedPercent(_ value: Double) -> Double {
        Double(Int(value.rounded()))
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatResetAt(_ epoch: Int64?, locale: Locale) -> String {
        guard let epoch else { return "--" }
        return LocalizedDateFormatterCache.shared.string(
            from: Date(timeIntervalSince1970: TimeInterval(epoch)),
            locale: locale,
            dateStyle: .short,
            timeStyle: .medium
        )
    }

    private static func formatRefreshAt(_ epoch: Int64, locale: Locale) -> String {
        guard epoch > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return LocalizedDateFormatterCache.shared.string(
            from: date,
            locale: locale,
            dateStyle: Calendar.autoupdatingCurrent.isDateInToday(date) ? .none : .short,
            timeStyle: .short
        )
    }
}
