import Foundation

enum AccountsSortMode: String, CaseIterable, Identifiable {
    case remainingUsage
    case accountName
    case emailName
    case teamName

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .remainingUsage:
            "accounts.sort.remaining_usage"
        case .accountName:
            "accounts.sort.account_name"
        case .emailName:
            "accounts.sort.email"
        case .teamName:
            "accounts.sort.team_name"
        }
    }

    var title: String {
        L10n.tr(titleKey)
    }
}

enum AccountRanking {
    private static let exhaustedThreshold = 100.0

    static func remainingScore(for account: AccountSummary) -> Double {
        let oneWeekUsed = account.usage?.oneWeek?.usedPercent ?? 100
        let fiveHourUsed = account.usage?.fiveHour?.usedPercent ?? 100

        let oneWeekRemaining = max(0, 100 - oneWeekUsed)
        let fiveHourRemaining = max(0, 100 - fiveHourUsed)

        return oneWeekRemaining * 0.7 + fiveHourRemaining * 0.3
    }

    static func sortByRemaining(_ accounts: [AccountSummary]) -> [AccountSummary] {
        sortForDisplay(accounts, mode: .remainingUsage)
    }

    static func sortForDisplay(
        _ accounts: [AccountSummary],
        mode: AccountsSortMode = .remainingUsage
    ) -> [AccountSummary] {
        accounts.sorted { left, right in
            switch mode {
            case .remainingUsage:
                let leftScore = remainingScore(for: left)
                let rightScore = remainingScore(for: right)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
            case .accountName:
                if let orderedAscending = compareText(left.label, right.label) {
                    return orderedAscending
                }
            case .emailName:
                if let orderedAscending = compareText(left.email, right.email) {
                    return orderedAscending
                }
            case .teamName:
                if let orderedAscending = compareText(left.displayTeamName, right.displayTeamName) {
                    return orderedAscending
                }
            }

            if let orderedAscending = compareText(left.label, right.label) {
                return orderedAscending
            }

            if let orderedAscending = compareText(left.email, right.email) {
                return orderedAscending
            }

            if let orderedAscending = compareText(left.displayTeamName, right.displayTeamName) {
                return orderedAscending
            }

            let leftScore = remainingScore(for: left)
            let rightScore = remainingScore(for: right)
            if leftScore != rightScore {
                return leftScore > rightScore
            }

            if left.addedAt != right.addedAt {
                return left.addedAt < right.addedAt
            }

            return left.id < right.id
        }
    }

    static func pickBestAccount(_ accounts: [AccountSummary]) -> AccountSummary? {
        sortByRemaining(accounts).first
    }

    static func isQuotaExhausted(_ account: AccountSummary) -> Bool {
        isWindowExhausted(account.usage?.fiveHour) || isWindowExhausted(account.usage?.oneWeek)
    }

    static func pickAutoSwitchTarget(_ accounts: [AccountSummary]) -> AccountSummary? {
        guard let current = accounts.first(where: \.isCurrent), isQuotaExhausted(current) else {
            return nil
        }

        let alternatives = accounts.filter { $0.id != current.id }
        return pickBestAccount(alternatives)
    }

    private static func isWindowExhausted(_ window: UsageWindow?) -> Bool {
        guard let window else { return false }
        return window.usedPercent >= exhaustedThreshold
    }

    private static func compareText(_ left: String?, _ right: String?) -> Bool? {
        let normalizedLeft = normalizedText(left)
        let normalizedRight = normalizedText(right)

        switch (normalizedLeft, normalizedRight) {
        case let (left?, right?):
            let comparison = left.localizedStandardCompare(right)
            guard comparison != .orderedSame else { return nil }
            return comparison == .orderedAscending
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return nil
        }
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
