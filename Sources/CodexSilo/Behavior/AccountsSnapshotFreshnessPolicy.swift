import Foundation

struct AccountsSnapshotFreshnessPolicy: Sendable {
    let remoteSnapshotFreshnessWindowSeconds: Int64

    init(remoteSnapshotFreshnessWindowSeconds: Int64 = 30) {
        self.remoteSnapshotFreshnessWindowSeconds = remoteSnapshotFreshnessWindowSeconds
    }

    func isRemoteSnapshotFresh(
        remoteSyncedAt: Int64?,
        now: Int64
    ) -> Bool {
        guard let remoteSyncedAt else {
            return false
        }
        return now - remoteSyncedAt <= remoteSnapshotFreshnessWindowSeconds
    }

    func shouldRefreshUsage(
        forceRefresh: Bool,
        remoteSyncedAt: Int64?,
        now: Int64
    ) -> Bool {
        if forceRefresh {
            return true
        }

        guard let remoteSyncedAt else {
            return true
        }

        return !isRemoteSnapshotFresh(remoteSyncedAt: remoteSyncedAt, now: now)
    }
}

enum AccountsCloudSyncMode: Sendable {
    case disabled
    case pushLocalAccounts
    case pullRemoteAccounts
}

struct AccountsSyncExecutionDecision: Equatable, Sendable {
    let shouldRefreshLocalUsage: Bool
    let shouldPushLocalSnapshot: Bool

    static let noRefreshNoPush = AccountsSyncExecutionDecision(
        shouldRefreshLocalUsage: false,
        shouldPushLocalSnapshot: false
    )
}

struct AccountsSyncExecutionPolicy: Sendable {
    private let snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy

    init(snapshotFreshnessPolicy: AccountsSnapshotFreshnessPolicy = AccountsSnapshotFreshnessPolicy()) {
        self.snapshotFreshnessPolicy = snapshotFreshnessPolicy
    }

    func decision(
        cloudSyncMode: AccountsCloudSyncMode,
        forceUsageRefresh: Bool,
        remoteSyncedAt: Int64?,
        now: Int64
    ) -> AccountsSyncExecutionDecision {
        let shouldRefreshByFreshness = snapshotFreshnessPolicy.shouldRefreshUsage(
            forceRefresh: forceUsageRefresh,
            remoteSyncedAt: remoteSyncedAt,
            now: now
        )

        switch cloudSyncMode {
        case .disabled:
            return AccountsSyncExecutionDecision(
                shouldRefreshLocalUsage: shouldRefreshByFreshness,
                shouldPushLocalSnapshot: false
            )
        case .pushLocalAccounts:
            return AccountsSyncExecutionDecision(
                shouldRefreshLocalUsage: shouldRefreshByFreshness,
                shouldPushLocalSnapshot: shouldRefreshByFreshness
            )
        case .pullRemoteAccounts:
            return AccountsSyncExecutionDecision(
                shouldRefreshLocalUsage: shouldRefreshByFreshness,
                shouldPushLocalSnapshot: shouldRefreshByFreshness
            )
        }
    }
}
