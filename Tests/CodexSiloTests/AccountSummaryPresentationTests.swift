import XCTest
@testable import CodexSilo

final class AccountSummaryPresentationTests: XCTestCase {
    func testWorkspaceTagIsShownForBusinessPlan() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Business",
            email: nil,
            accountID: "account-1",
            planType: "business",
            teamName: "workspace-a",
            teamAlias: nil,
            addedAt: 0,
            updatedAt: 0,
            usage: nil,
            usageError: nil,
            isCurrent: false
        )

        XCTAssertEqual(account.normalizedPlanLabel, "BUSINESS")
        XCTAssertTrue(account.shouldDisplayWorkspaceTag)
        XCTAssertEqual(account.displayTeamName, "workspace-a")
    }

    func testWorkspaceTagStaysHiddenForProPlan() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Pro",
            email: nil,
            accountID: "account-1",
            planType: "pro",
            teamName: "workspace-a",
            teamAlias: nil,
            addedAt: 0,
            updatedAt: 0,
            usage: nil,
            usageError: nil,
            isCurrent: false
        )

        XCTAssertEqual(account.normalizedPlanLabel, "PRO")
        XCTAssertFalse(account.shouldDisplayWorkspaceTag)
    }
}
