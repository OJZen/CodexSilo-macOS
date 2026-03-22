import XCTest
@testable import CodexSilo

final class AccountCardPresentationTests: XCTestCase {
    func testCollapsedPresentationHidesTeamNameButKeepsEmail() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Primary",
            email: "dev@example.com",
            accountID: "account-1",
            planType: "business",
            teamName: "workspace-a",
            teamAlias: "Alias A",
            addedAt: 1,
            updatedAt: 2,
            usage: UsageSnapshot(
                fetchedAt: 3,
                planType: "business",
                fiveHour: UsageWindow(usedPercent: 27.2, windowSeconds: 18_000, resetAt: 1_763_216_000),
                oneWeek: UsageWindow(usedPercent: 52.6, windowSeconds: 604_800, resetAt: 1_763_820_800),
                credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "128")
            ),
            usageError: nil,
            isCurrent: true
        )

        let presentation = AccountCardPresentation(
            account: account,
            isCollapsed: true,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.accent, .indigo)
        XCTAssertEqual(presentation.health, .warning)
        XCTAssertEqual(presentation.planLabel, "BUSINESS")
        XCTAssertEqual(presentation.displayAccountName, "Primary")
        XCTAssertEqual(presentation.subtitleText, "dev@example.com")
        XCTAssertEqual(presentation.fiveHourWindow.remainingPercent, 73)
        XCTAssertEqual(presentation.oneWeekWindow.remainingPercent, 47)
        XCTAssertEqual(presentation.compactUsage.fiveHourRemainingPercent, 73)
        XCTAssertEqual(presentation.compactUsage.oneWeekRemainingPercent, 47)
    }

    func testExpandedPresentationShowsTeamNameAndEmail() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Primary",
            email: "dev@example.com",
            accountID: "account-1",
            planType: "business",
            teamName: "workspace-a",
            teamAlias: "Alias A",
            addedAt: 1,
            updatedAt: 2,
            usage: UsageSnapshot(
                fetchedAt: 3,
                planType: "business",
                fiveHour: UsageWindow(usedPercent: 27.2, windowSeconds: 18_000, resetAt: 1_763_216_000),
                oneWeek: UsageWindow(usedPercent: 52.6, windowSeconds: 604_800, resetAt: 1_763_820_800),
                credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "128")
            ),
            usageError: nil,
            isCurrent: true
        )

        let presentation = AccountCardPresentation(
            account: account,
            isCollapsed: false,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.displayAccountName, "Primary")
        XCTAssertEqual(presentation.subtitleText, "Alias A · dev@example.com")
    }

    func testExpandedPresentationFallsBackToTeamAccentAndMissingWindowDefaults() {
        let account = AccountSummary(
            id: "acct-2",
            label: "Backup",
            email: nil,
            accountID: "account-2",
            planType: nil,
            teamName: nil,
            teamAlias: nil,
            addedAt: 1,
            updatedAt: 2,
            usage: UsageSnapshot(
                fetchedAt: 3,
                planType: nil,
                fiveHour: nil,
                oneWeek: nil,
                credits: CreditSnapshot(hasCredits: false, unlimited: true, balance: nil)
            ),
            usageError: nil,
            isCurrent: false
        )

        let presentation = AccountCardPresentation(
            account: account,
            isCollapsed: false,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.accent, .teal)
        XCTAssertEqual(presentation.health, .neutral)
        XCTAssertEqual(presentation.planLabel, "TEAM")
        XCTAssertEqual(presentation.displayAccountName, "Backup")
        XCTAssertNil(presentation.subtitleText)
        XCTAssertEqual(presentation.fiveHourWindow.usedPercent, 100)
        XCTAssertEqual(presentation.fiveHourWindow.remainingPercent, 0)
        XCTAssertEqual(presentation.fiveHourWindow.resetText, L10n.tr("accounts.window.reset_at_format", "--"))
    }

    func testHealthBecomesSuccessWhenBothWindowsStayAboveFiftyPercent() {
        let account = AccountSummary(
            id: "acct-3",
            label: "Healthy",
            email: "healthy@example.com",
            accountID: "account-3",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            addedAt: 1,
            updatedAt: 2,
            usage: UsageSnapshot(
                fetchedAt: 3,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 12, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 31, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            ),
            usageError: nil,
            isCurrent: false
        )

        let presentation = AccountCardPresentation(
            account: account,
            isCollapsed: false,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.health, .success)
    }

    func testHealthBecomesCriticalWhenAnyWindowDropsBelowTwentyPercent() {
        let account = AccountSummary(
            id: "acct-4",
            label: "Critical",
            email: "critical@example.com",
            accountID: "account-4",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            addedAt: 1,
            updatedAt: 2,
            usage: UsageSnapshot(
                fetchedAt: 3,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 82, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 10, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            ),
            usageError: nil,
            isCurrent: false
        )

        let presentation = AccountCardPresentation(
            account: account,
            isCollapsed: false,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(presentation.health, .critical)
    }
}
