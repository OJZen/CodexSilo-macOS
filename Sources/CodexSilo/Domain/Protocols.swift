import Foundation

protocol AccountsStoreRepository: Sendable {
    func loadStore() throws -> AccountsStore
    func saveStore(_ store: AccountsStore) throws
}

protocol AuthRepository: Sendable {
    func readCurrentAuth() throws -> JSONValue
    func readCurrentAuthOptional() throws -> JSONValue?
    func readAuth(from url: URL) throws -> JSONValue
    func writeCurrentAuth(_ auth: JSONValue) throws
    func removeCurrentAuth() throws
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth
    func currentAuthAccountID() -> String?
    func currentAuthAccountKey() -> String?
    func currentAuthVariantKey() -> String?
}

protocol UsageService: Sendable {
    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot
}

protocol WorkspaceMetadataService: Sendable {
    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata]
}

protocol DateProviding: Sendable {
    func unixSecondsNow() -> Int64
    func unixMillisecondsNow() -> Int64
}

extension DateProviding {
    func unixMillisecondsNow() -> Int64 {
        unixSecondsNow() * 1_000
    }
}

protocol ProxyRuntimeService: Sendable {
    func status() async -> ApiProxyStatus
    func start(preferredPort: Int?) async throws -> ApiProxyStatus
    func stop() async -> ApiProxyStatus
    func refreshAPIKey() async throws -> ApiProxyStatus
    func syncAccountsStore() async throws
}

protocol UpdateCheckingService: Sendable {
    func checkForUpdates(currentVersion: String) async throws -> PendingUpdateInfo?
}

protocol ChatGPTOAuthLoginServiceProtocol: Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens
}

protocol LaunchAtStartupServiceProtocol: Sendable {
    func setEnabled(_ enabled: Bool) throws
    func syncWithStoreValue(_ enabled: Bool) throws
}

protocol AccountsCloudSyncServiceProtocol: Sendable {
    func pushLocalAccountsIfNeeded() async throws
    func pullRemoteAccountsIfNeeded(
        currentTime: Int64,
        maximumSnapshotAgeSeconds: Int64
    ) async throws -> AccountsCloudSyncPullResult
    func ensurePushSubscriptionIfNeeded() async throws
}

protocol CloudSyncAvailabilityServiceProtocol: Sendable {
    func isICloudAvailable() async -> Bool
}

protocol CurrentAccountSelectionSyncServiceProtocol: Sendable {
    func recordLocalSelection(accountID: String) async throws
    func pushLocalSelectionIfNeeded() async throws
    func pullRemoteSelectionIfNeeded() async throws -> CurrentAccountSelectionPullResult
    func ensurePushSubscriptionIfNeeded() async throws
}

@MainActor
protocol AccountsManualRefreshServiceProtocol: AnyObject {
    func performManualRefresh() async throws -> [AccountSummary]
    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary]
}

extension AccountsManualRefreshServiceProtocol {
    func performManualRefresh() async throws -> [AccountSummary] {
        try await performManualRefresh(onPartialUpdate: { _ in })
    }
}

extension AuthRepository {
    func currentAuthAccountKey() -> String? {
        if let auth = try? readCurrentAuthOptional(),
           let extracted = try? extractAuth(from: auth) {
            return extracted.accountKey
        }

        return currentAuthAccountID()
    }

    func currentAuthVariantKey() -> String? {
        if let auth = try? readCurrentAuthOptional(),
           let extracted = try? extractAuth(from: auth) {
            return extracted.variantKey
        }

        return nil
    }
}

@MainActor
protocol AccountsLocalMutationSyncServiceProtocol: AnyObject {
    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary])
    func syncLocalAccountsMutationNow() async
}
