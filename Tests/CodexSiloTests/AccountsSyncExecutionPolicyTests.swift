import XCTest
@testable import CodexSilo

final class AccountsSyncExecutionPolicyTests: XCTestCase {
    func testPrimaryWriterRefreshesAndPushesWhenRemoteSnapshotIsStale() {
        let policy = AccountsSyncExecutionPolicy(
            snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy(remoteSnapshotFreshnessWindowSeconds: 30)
        )

        let decision = policy.decision(
            cloudSyncMode: .pushLocalAccounts,
            forceUsageRefresh: false,
            remoteSyncedAt: 1_000,
            now: 1_031
        )

        XCTAssertTrue(decision.shouldRefreshLocalUsage)
        XCTAssertTrue(decision.shouldPushLocalSnapshot)
    }

    func testFollowerRefreshesAndPushesWhenRemoteSnapshotIsStale() {
        let policy = AccountsSyncExecutionPolicy(
            snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy(remoteSnapshotFreshnessWindowSeconds: 30)
        )

        let decision = policy.decision(
            cloudSyncMode: .pullRemoteAccounts,
            forceUsageRefresh: false,
            remoteSyncedAt: 1_000,
            now: 1_031
        )

        XCTAssertTrue(decision.shouldRefreshLocalUsage)
        XCTAssertTrue(decision.shouldPushLocalSnapshot)
    }

    func testFollowerSkipsRefreshAndPushWhenRemoteSnapshotIsFresh() {
        let policy = AccountsSyncExecutionPolicy(
            snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy(remoteSnapshotFreshnessWindowSeconds: 30)
        )

        let decision = policy.decision(
            cloudSyncMode: .pullRemoteAccounts,
            forceUsageRefresh: false,
            remoteSyncedAt: 1_000,
            now: 1_029
        )

        XCTAssertEqual(decision, .noRefreshNoPush)
    }

    func testFollowerCanRefreshWhenRemoteSnapshotMissing() {
        let policy = AccountsSyncExecutionPolicy(
            snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy(remoteSnapshotFreshnessWindowSeconds: 30)
        )

        let decision = policy.decision(
            cloudSyncMode: .pullRemoteAccounts,
            forceUsageRefresh: false,
            remoteSyncedAt: nil,
            now: 1_500
        )

        XCTAssertTrue(decision.shouldRefreshLocalUsage)
        XCTAssertTrue(decision.shouldPushLocalSnapshot)
    }

    func testDisabledCloudSyncStillAllowsLocalRefreshWithoutPush() {
        let policy = AccountsSyncExecutionPolicy(
            snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy(remoteSnapshotFreshnessWindowSeconds: 30)
        )

        let decision = policy.decision(
            cloudSyncMode: .disabled,
            forceUsageRefresh: false,
            remoteSyncedAt: nil,
            now: 1_500
        )

        XCTAssertTrue(decision.shouldRefreshLocalUsage)
        XCTAssertFalse(decision.shouldPushLocalSnapshot)
    }
}
