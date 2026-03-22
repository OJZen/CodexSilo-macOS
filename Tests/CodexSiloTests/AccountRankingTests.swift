import XCTest
@testable import CodexSilo

final class AccountRankingTests: XCTestCase {
    func testPickBestAccountChoosesMostRemainingQuota() {
        let best = makeAccount(id: "a", weekUsed: 15, hourUsed: 30)
        let medium = makeAccount(id: "b", weekUsed: 40, hourUsed: 30)
        let worst = makeAccount(id: "c", weekUsed: 80, hourUsed: 90)

        let picked = AccountRanking.pickBestAccount([worst, medium, best])

        XCTAssertEqual(picked?.id, best.id)
    }

    func testSortForDisplayByRemainingOrdersHighestRemainingFirst() {
        let current = makeAccount(id: "current", weekUsed: 95, hourUsed: 95, isCurrent: true)
        let best = makeAccount(id: "best", weekUsed: 10, hourUsed: 10)
        let medium = makeAccount(id: "medium", weekUsed: 40, hourUsed: 40)

        let sorted = AccountRanking.sortForDisplay([medium, best, current], mode: .remainingUsage)

        XCTAssertEqual(sorted.map(\.id), ["best", "medium", "current"])
    }

    func testSortForDisplayByAccountNameOrdersAlphabetically() {
        let zeta = makeAccount(id: "zeta", label: "Zeta", weekUsed: 20, hourUsed: 20)
        let alpha = makeAccount(id: "alpha", label: "Alpha", weekUsed: 90, hourUsed: 90)
        let beta = makeAccount(id: "beta", label: "beta", weekUsed: 10, hourUsed: 10)

        let sorted = AccountRanking.sortForDisplay([zeta, beta, alpha], mode: .accountName)

        XCTAssertEqual(sorted.map(\.id), ["alpha", "beta", "zeta"])
    }

    func testSortForDisplayByEmailOrdersAlphabeticallyAndPlacesMissingLast() {
        let missing = makeAccount(id: "missing", label: "Missing", email: nil, weekUsed: 10, hourUsed: 10)
        let bravo = makeAccount(id: "bravo", label: "Bravo", email: "bravo@example.com", weekUsed: 80, hourUsed: 80)
        let alpha = makeAccount(id: "alpha", label: "Alpha", email: "alpha@example.com", weekUsed: 60, hourUsed: 60)

        let sorted = AccountRanking.sortForDisplay([missing, bravo, alpha], mode: .emailName)

        XCTAssertEqual(sorted.map(\.id), ["alpha", "bravo", "missing"])
    }

    func testSortForDisplayByTeamNameUsesAliasOrTeamNameAndPlacesMissingLast() {
        let missing = makeAccount(id: "missing", label: "Missing", teamName: nil, teamAlias: nil, weekUsed: 10, hourUsed: 10)
        let omega = makeAccount(id: "omega", label: "Omega", teamName: "Omega Team", teamAlias: nil, weekUsed: 60, hourUsed: 60)
        let alpha = makeAccount(id: "alpha", label: "Alpha", teamName: "Zeta Team", teamAlias: "Alpha Team", weekUsed: 80, hourUsed: 80)

        let sorted = AccountRanking.sortForDisplay([missing, omega, alpha], mode: .teamName)

        XCTAssertEqual(sorted.map(\.id), ["alpha", "omega", "missing"])
    }

    func testAutoSwitchTargetIsNilWhenCurrentAccountNotExhausted() {
        let current = makeAccount(id: "current", weekUsed: 60, hourUsed: 70, isCurrent: true)
        let better = makeAccount(id: "better", weekUsed: 10, hourUsed: 15)

        let target = AccountRanking.pickAutoSwitchTarget([current, better])

        XCTAssertNil(target)
    }

    func testAutoSwitchTargetChoosesBestAlternativeWhenCurrentIsExhausted() {
        let exhaustedCurrent = makeAccount(id: "current", weekUsed: 100, hourUsed: 95, isCurrent: true)
        let bestAlternative = makeAccount(id: "best", weekUsed: 20, hourUsed: 15)
        let otherAlternative = makeAccount(id: "other", weekUsed: 40, hourUsed: 25)

        let target = AccountRanking.pickAutoSwitchTarget([exhaustedCurrent, otherAlternative, bestAlternative])

        XCTAssertEqual(target?.id, bestAlternative.id)
    }

    func testAutoSwitchTargetIsNilWhenNoCurrentAccount() {
        let accountA = makeAccount(id: "a", weekUsed: 100, hourUsed: 100)
        let accountB = makeAccount(id: "b", weekUsed: 5, hourUsed: 5)

        let target = AccountRanking.pickAutoSwitchTarget([accountA, accountB])

        XCTAssertNil(target)
    }

    func testAutoSwitchTargetIsNilWhenCurrentExhaustedButNoAlternative() {
        let current = makeAccount(id: "current", weekUsed: 100, hourUsed: 100, isCurrent: true)

        let target = AccountRanking.pickAutoSwitchTarget([current])

        XCTAssertNil(target)
    }

    private func makeAccount(
        id: String,
        label: String? = nil,
        email: String? = nil,
        teamName: String? = nil,
        teamAlias: String? = nil,
        weekUsed: Double,
        hourUsed: Double,
        isCurrent: Bool = false
    ) -> AccountSummary {
        AccountSummary(
            id: id,
            label: label ?? id,
            email: email,
            accountID: id,
            planType: nil,
            teamName: teamName,
            teamAlias: teamAlias,
            addedAt: 0,
            updatedAt: 0,
            usage: UsageSnapshot(
                fetchedAt: 0,
                planType: nil,
                fiveHour: UsageWindow(usedPercent: hourUsed, windowSeconds: 5 * 60 * 60, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: weekUsed, windowSeconds: 7 * 24 * 60 * 60, resetAt: nil),
                credits: nil
            ),
            usageError: nil,
            isCurrent: isCurrent
        )
    }
}
