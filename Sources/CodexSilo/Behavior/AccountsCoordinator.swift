import Foundation

actor AccountsCoordinator {
    private struct AccountsListCache {
        let accounts: [StoredAccount]
        let currentSelection: CurrentAccountSelection?
        let currentAuthAccountKey: String?
        let currentAuthVariantKey: String?
        let summaries: [AccountSummary]

        func matches(
            store: AccountsStore,
            currentAuthSelection: (accountKey: String?, variantKey: String?)
        ) -> Bool {
            accounts == store.accounts
                && currentSelection == store.currentSelection
                && currentAuthAccountKey == currentAuthSelection.accountKey
                && currentAuthVariantKey == currentAuthSelection.variantKey
        }
    }

    private struct RefreshAccountResult {
        let account: StoredAccount
        let attemptedRefresh: Bool
        let didRefreshSucceed: Bool
        let transientFailureReason: String?
    }

    private enum UsageRefreshPolicy {
        static let minimumRefreshIntervalSeconds: Int64 = 25

        static func shouldRefresh(_ snapshot: UsageSnapshot?, now: Int64) -> Bool {
            guard let snapshot else { return true }
            return now - snapshot.fetchedAt >= minimumRefreshIntervalSeconds
        }
    }

    private enum UsageRefreshExecutionMode {
        case parallel
        case serial
    }

    private let storeRepository: AccountsStoreRepository
    private let authRepository: AuthRepository
    private let usageService: UsageService
    private let workspaceMetadataService: WorkspaceMetadataService?
    private let chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol
    private let dateProvider: DateProviding
    private let logger: AppLogger
    private var accountsListCache: AccountsListCache?

    init(
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository,
        usageService: UsageService,
        workspaceMetadataService: WorkspaceMetadataService? = nil,
        chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol,
        dateProvider: DateProviding = SystemDateProvider(),
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.usageService = usageService
        self.workspaceMetadataService = workspaceMetadataService
        self.chatGPTOAuthLoginService = chatGPTOAuthLoginService
        self.dateProvider = dateProvider
        self.logger = logger
    }

    func listAccounts() async throws -> [AccountSummary] {
        var store = try storeRepository.loadStore()
        let currentAuthSelection = currentAuthSelectionIdentifiers()
        if let accountsListCache,
           accountsListCache.matches(store: store, currentAuthSelection: currentAuthSelection) {
            logger.debug(
                category: .accounts,
                event: "list_cache_hit",
                message: "Returning cached account summaries.",
                metadata: ["accounts": String(accountsListCache.summaries.count)]
            )
            return accountsListCache.summaries
        }
        let reconciliation = Self.reconcileStoredAccountMetadata(
            in: &store,
            authRepository: authRepository
        )
        let didEnrich = await enrichStoredWorkspaceMetadataIfNeeded(
            in: &store,
            forceRemoteCheck: false,
            extractedAuthByStoredAccountID: reconciliation.extractedAuthByStoredAccountID
        )
        if reconciliation.didChange || didEnrich {
            try storeRepository.saveStore(store)
        }
        let summaries = store.accountSummaries(
            currentAccountKey: currentAuthSelection.accountKey,
            currentVariantKey: currentAuthSelection.variantKey
        )
        cacheAccountsList(store: store, currentAuthSelection: currentAuthSelection, summaries: summaries)
        logger.debug(
            category: .accounts,
            event: "list_succeeded",
            message: "Account summaries loaded.",
            metadata: ["accounts": String(summaries.count)]
        )
        return summaries
    }

    func syncCurrentAuthSnapshotFromDisk() throws -> [AccountSummary] {
        var store = try storeRepository.loadStore()
        let didChange = syncCurrentLiveAuthProjectionFromDisk(in: &store)
        if didChange {
            try storeRepository.saveStore(store)
        }

        let currentAuthSelection = currentAuthSelectionIdentifiers()
        let summaries = store.accountSummaries(
            currentAccountKey: currentAuthSelection.accountKey,
            currentVariantKey: currentAuthSelection.variantKey
        )
        cacheAccountsList(store: store, currentAuthSelection: currentAuthSelection, summaries: summaries)
        return summaries
    }

    func accountsOverviewCollapsed() throws -> Bool {
        try storeRepository.loadStore().accountsOverviewCollapsed
    }

    func setAccountsOverviewCollapsed(_ value: Bool) throws {
        var store = try storeRepository.loadStore()
        guard store.accountsOverviewCollapsed != value else { return }
        store.accountsOverviewCollapsed = value
        try storeRepository.saveStore(store)
    }

    @discardableResult
    func importCurrentAuthAccount(customLabel: String?) async throws -> AccountSummary {
        let authJSON = try authRepository.readCurrentAuth()
        return try await importAccount(authJSON: authJSON, customLabel: customLabel)
    }

    @discardableResult
    func importAccountFile(from url: URL, customLabel: String?, setAsCurrent: Bool) async throws -> AccountSummary {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let authJSON = try authRepository.readAuth(from: url)
        return try await importAccount(
            authJSON: authJSON,
            customLabel: customLabel,
            setAsCurrent: setAsCurrent
        )
    }

    func accountConfigurationDraft(id: String) throws -> AccountConfigurationDraft {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_update"))
        }

        let currentSelection = resolvedCurrentSelectionIdentifiers(in: store)
        let editableTeamName = normalizeTeamAlias(account.teamAlias)
            ?? Self.normalizedTeamName(account.teamName)
            ?? ""

        return AccountConfigurationDraft(
            storedAccountID: account.id,
            label: account.label,
            teamAlias: editableTeamName,
            setAsCurrent: account.matchesSelection(
                accountKey: currentSelection.accountKey,
                variantKey: currentSelection.variantKey
            ),
            authJSONString: try account.authJSON.prettyPrintedJSONString()
        )
    }

    @discardableResult
    func saveAccountConfiguration(_ draft: AccountConfigurationDraft) async throws -> AccountSummary {
        let authJSON = try JSONValue.authJSONObject(from: draft.authJSONString)
        return try await importAccount(
            authJSON: authJSON,
            customLabel: normalizedText(draft.label),
            preferredStoredAccountID: draft.storedAccountID,
            teamAlias: normalizeTeamAlias(draft.teamAlias),
            overwriteStoredTeamAlias: true,
            setAsCurrent: draft.setAsCurrent,
            rejectExistingMatchingAccountID: draft.storedAccountID == nil
        )
    }

    @discardableResult
    private func importAccount(
        authJSON: JSONValue,
        customLabel: String?,
        preferredStoredAccountID: String? = nil,
        teamAlias: String? = nil,
        overwriteStoredTeamAlias: Bool = false,
        setAsCurrent: Bool = false,
        rejectExistingMatchingAccountID: Bool = false
    ) async throws -> AccountSummary {
        let operationID = UUID().uuidString
        var extracted = try authRepository.extractAuth(from: authJSON)
        logger.info(
            category: .accounts,
            event: "import_started",
            message: "Starting account import.",
            metadata: [
                "email": extracted.email ?? "",
                "account_id": extracted.accountID,
                "set_as_current": setAsCurrent ? "true" : "false"
            ],
            operationID: operationID
        )

        var usage: UsageSnapshot?
        var usageError: String?

        do {
            usage = try await usageService.fetchUsage(accessToken: extracted.accessToken, accountID: extracted.accountID)
        } catch {
            usageError = error.localizedDescription
            logger.warning(
                category: .accounts,
                event: "import_usage_failed",
                message: "Usage fetch during account import failed; continuing with partial data.",
                metadata: [
                    "account_id": extracted.accountID,
                    "error": error.localizedDescription
                ],
                operationID: operationID
            )
        }
        extracted.planType = usage?.planType ?? extracted.planType
        if let remoteWorkspaceName = await resolveRemoteWorkspaceName(
            for: extracted,
            forceRemoteCheck: true,
            allowUnknownPlanWhenForced: true
        ) {
            extracted.teamName = remoteWorkspaceName
        }

        let now = dateProvider.unixSecondsNow()
        let generatedLabel = customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = generatedLabel?.isEmpty == false
            ? generatedLabel!
            : (extracted.email ?? "Codex \(String(extracted.accountID.prefix(8)))")

        var store = try storeRepository.loadStore()
        let currentSelection = resolvedCurrentSelectionIdentifiers(in: store)
        let preferredStoredAccount = preferredStoredAccountID.flatMap { id in
            store.accounts.first(where: { $0.id == id })
        }
        let shouldSetAsCurrent = setAsCurrent || preferredStoredAccount?.matchesSelection(
            accountKey: currentSelection.accountKey,
            variantKey: currentSelection.variantKey
        ) == true

        if rejectExistingMatchingAccountID,
           store.accounts.contains(where: { $0.variantKey == extracted.variantKey }) {
            throw AppError.invalidData("已有相同账户配置，请使用编辑功能修改现有配置。")
        }

        let account = StoredAccount(
            id: preferredStoredAccountID ?? UUID().uuidString,
            label: label,
            principalID: extracted.principalID,
            email: extracted.email,
            accountID: extracted.accountID,
            planType: extracted.planType,
            teamName: extracted.teamName,
            teamAlias: teamAlias,
            authJSON: authJSON,
            addedAt: now,
            updatedAt: now,
            usage: usage,
            usageError: usageError
        )

        if let preferredStoredAccountID,
           store.accounts.contains(where: { $0.variantKey == extracted.variantKey && $0.id != preferredStoredAccountID }) {
            throw AppError.invalidData("已有相同账户配置，请确认后再保存。")
        }

        let resolvedVariantKey = extracted.variantKey
        let resolvedPlanKey = AccountIdentity.normalizePlanTypeKey(extracted.planType)
        let existingIndex = preferredStoredAccountID.flatMap { id in
            store.accounts.firstIndex(where: { $0.id == id })
        } ?? store.accounts.firstIndex(where: { $0.variantKey == resolvedVariantKey })
        ?? {
            guard resolvedPlanKey != "unknown" else { return nil }
            return store.accounts.firstIndex(where: {
                $0.accountKey == extracted.accountKey
                    && AccountIdentity.normalizePlanTypeKey($0.resolvedPlanType) == "unknown"
            })
        }()

        if let existingIndex {
            var existing = store.accounts[existingIndex]
            existing.label = account.label
            existing.principalID = account.principalID
            existing.email = account.email
            existing.accountID = account.accountID
            existing.planType = account.planType
            if let teamName = Self.normalizedTeamName(account.teamName) {
                existing.teamName = teamName
            }
            if overwriteStoredTeamAlias {
                existing.teamAlias = teamAlias
            } else {
                existing.teamAlias = teamAlias ?? existing.teamAlias
            }
            existing.authJSON = account.authJSON
            existing.updatedAt = now
            existing.usage = usage ?? existing.usage
            existing.usageError = usageError
            store.accounts[existingIndex] = existing
        } else {
            store.accounts.append(account)
        }

        let targetStoredAccountID: String
        if let existingIndex {
            targetStoredAccountID = store.accounts[existingIndex].id
        } else {
            targetStoredAccountID = store.accounts.last!.id
        }

        if shouldSetAsCurrent {
            backfillCurrentLiveAuthIfNeeded(
                in: &store,
                excludingStoredAccountIDs: [targetStoredAccountID]
            )
            guard let targetAccount = store.accounts.first(where: { $0.id == targetStoredAccountID }) else {
                throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
            }
            store.currentSelection = makeCurrentAccountSelection(for: targetAccount, sourceDeviceID: "macos-local")
        }

        try storeRepository.saveStore(store)
        guard let savedAccount = store.accounts.first(where: { $0.id == targetStoredAccountID }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        if shouldSetAsCurrent {
            try authRepository.writeCurrentAuth(authJSON)
        }

        let currentAuthSelection = currentAuthSelectionIdentifiers()
        let effectiveCurrentAccountKey = shouldSetAsCurrent
            ? extracted.accountKey
            : currentAuthSelection.accountKey
        let effectiveCurrentVariantKey = shouldSetAsCurrent
            ? extracted.variantKey
            : currentAuthSelection.variantKey
        let summary = toSummary(
            savedAccount,
            currentAccountKey: effectiveCurrentAccountKey,
            currentVariantKey: effectiveCurrentVariantKey
        )
        logger.info(
            category: .accounts,
            event: "import_succeeded",
            message: "Account import completed.",
            metadata: [
                "label": summary.label,
                "email": summary.email ?? "",
                "account_id": summary.accountID,
                "is_current": summary.isCurrent ? "true" : "false"
            ],
            operationID: operationID
        )
        return summary
    }

    func deleteAccount(id: String) throws {
        var store = try storeRepository.loadStore()
        store.accounts.removeAll { $0.id == id }
        try storeRepository.saveStore(store)
        logger.info(
            category: .accounts,
            event: "delete_account",
            message: "Deleted stored account.",
            metadata: ["stored_account_id": id]
        )
    }

    func updateTeamAlias(id: String, alias: String?) throws -> AccountSummary {
        var store = try storeRepository.loadStore()
        guard let index = store.accounts.firstIndex(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_update"))
        }

        store.accounts[index].teamAlias = normalizeTeamAlias(alias)
        store.accounts[index].updatedAt = dateProvider.unixSecondsNow()
        try storeRepository.saveStore(store)
        let currentAuthSelection = currentAuthSelectionIdentifiers()
        logger.info(
            category: .accounts,
            event: "update_team_alias",
            message: "Updated account team alias.",
            metadata: [
                "stored_account_id": id,
                "has_alias": normalizeTeamAlias(alias) == nil ? "false" : "true"
            ]
        )

        return toSummary(
            store.accounts[index],
            currentAccountKey: currentAuthSelection.accountKey,
            currentVariantKey: currentAuthSelection.variantKey
        )
    }

    func switchAccount(id: String) throws {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        try updateCurrentAccountProjection(account)
    }

    func switchAccountAndApplySettings(id: String) throws {
        let store = try storeRepository.loadStore()
        guard let account = store.accounts.first(where: { $0.id == id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        try updateCurrentAccountProjection(account)
        logger.info(
            category: .accounts,
            event: "switch_account",
            message: "Switched current account.",
            metadata: [
                "stored_account_id": id,
                "email": account.email ?? "",
                "account_id": account.accountID
            ]
        )
    }

    func smartSwitch() async throws -> AccountSummary? {
        let sorted = AccountRanking.sortByRemaining(try await listAccounts())
        guard let best = sorted.first else { return nil }
        try switchAccountAndApplySettings(id: best.id)
        return best
    }

    func autoSmartSwitchIfNeeded() async throws -> AccountSummary? {
        let accounts = try await listAccounts()
        guard let target = AccountRanking.pickAutoSwitchTarget(accounts) else {
            return nil
        }
        try switchAccountAndApplySettings(id: target.id)
        return target
    }

    func addAccountViaLogin(customLabel: String?, timeoutSeconds: TimeInterval = 10 * 60) async throws -> AccountSummary {
        let operationID = UUID().uuidString
        logger.info(
            category: .accounts,
            event: "oauth_add_account_started",
            message: "Starting add-account OAuth flow.",
            metadata: ["timeout_seconds": String(Int(timeoutSeconds))],
            operationID: operationID
        )
        let tokens = try await chatGPTOAuthLoginService.signInWithChatGPT(timeoutSeconds: timeoutSeconds)
        let authJSON = try authRepository.makeChatGPTAuth(from: tokens)
        let summary = try await importAccount(authJSON: authJSON, customLabel: customLabel)
        logger.info(
            category: .accounts,
            event: "oauth_add_account_succeeded",
            message: "OAuth add-account flow completed.",
            metadata: [
                "label": summary.label,
                "email": summary.email ?? ""
            ],
            operationID: operationID
        )
        return summary
    }

    func refreshAllUsage() async throws -> [AccountSummary] {
        try await refreshAllUsageResult(using: .parallel, force: false, onPartialUpdate: nil).accounts
    }

    func refreshAllUsageSerially() async throws -> [AccountSummary] {
        try await refreshAllUsageResult(using: .serial, force: false, onPartialUpdate: nil).accounts
    }

    func refreshAllUsage(force: Bool) async throws -> [AccountSummary] {
        try await refreshAllUsageResult(using: .parallel, force: force, onPartialUpdate: nil).accounts
    }

    func refreshAllUsageSerially(force: Bool) async throws -> [AccountSummary] {
        try await refreshAllUsageResult(using: .serial, force: force, onPartialUpdate: nil).accounts
    }

    func refreshAllUsage(
        force: Bool,
        onPartialUpdate: @escaping @Sendable ([AccountSummary]) async -> Void
    ) async throws -> [AccountSummary] {
        try await refreshAllUsageResult(using: .parallel, force: force, onPartialUpdate: onPartialUpdate).accounts
    }

    func refreshAllUsageSerially(
        force: Bool,
        onPartialUpdate: @escaping @Sendable ([AccountSummary]) async -> Void
    ) async throws -> [AccountSummary] {
        try await refreshAllUsageResult(using: .serial, force: force, onPartialUpdate: onPartialUpdate).accounts
    }

    func refreshAllUsageResult(force: Bool) async throws -> AccountsRefreshResult {
        try await refreshAllUsageResult(using: .parallel, force: force, onPartialUpdate: nil)
    }

    func refreshAllUsageSeriallyResult(force: Bool) async throws -> AccountsRefreshResult {
        try await refreshAllUsageResult(using: .serial, force: force, onPartialUpdate: nil)
    }

    func refreshAllUsageResult(
        force: Bool,
        onPartialUpdate: @escaping @Sendable ([AccountSummary]) async -> Void
    ) async throws -> AccountsRefreshResult {
        try await refreshAllUsageResult(using: .parallel, force: force, onPartialUpdate: onPartialUpdate)
    }

    func refreshAllUsageSeriallyResult(
        force: Bool,
        onPartialUpdate: @escaping @Sendable ([AccountSummary]) async -> Void
    ) async throws -> AccountsRefreshResult {
        try await refreshAllUsageResult(using: .serial, force: force, onPartialUpdate: onPartialUpdate)
    }

    private func refreshAllUsageResult(
        using mode: UsageRefreshExecutionMode,
        force: Bool,
        onPartialUpdate: (@Sendable ([AccountSummary]) async -> Void)?
    ) async throws -> AccountsRefreshResult {
        let operationID = UUID().uuidString
        let startedAt = Date()
        let now = dateProvider.unixSecondsNow()
        let snapshot = try storeRepository.loadStore()
        let authRepository = self.authRepository
        let usageService = self.usageService
        let currentAuthSelection = currentAuthSelectionIdentifiers()
        let shouldPersistPartialUpdates = onPartialUpdate != nil

        var latest = snapshot
        var didChangeStore = false
        var transientFailureReasons: [String] = []
        var attemptedRefreshCount = 0
        var successfulRefreshCount = 0
        logger.info(
            category: .accounts,
            event: "refresh_usage_started",
            message: "Starting account usage refresh.",
            metadata: [
                "mode": mode == .parallel ? "parallel" : "serial",
                "force": force ? "true" : "false",
                "accounts": String(snapshot.accounts.count)
            ],
            operationID: operationID
        )
        switch mode {
        case .parallel:
            try await withThrowingTaskGroup(of: RefreshAccountResult.self, returning: Void.self) { group in
                for account in snapshot.accounts {
                    group.addTask {
                        await Self.refreshAccount(
                            account,
                            now: now,
                            forceRefresh: force,
                            authRepository: authRepository,
                            usageService: usageService
                        )
                    }
                }
                for try await refreshed in group {
                    if refreshed.attemptedRefresh {
                        attemptedRefreshCount += 1
                    }
                    if refreshed.didRefreshSucceed {
                        successfulRefreshCount += 1
                    }
                    if let reason = refreshed.transientFailureReason {
                        transientFailureReasons.append(reason)
                    }

                    let didChange = Self.mergeRefreshedAccount(refreshed.account, into: &latest)
                    guard didChange else { continue }
                    didChangeStore = true
                    if shouldPersistPartialUpdates {
                        try storeRepository.saveStore(latest)
                    }
                    if let onPartialUpdate {
                        await onPartialUpdate(
                            latest.accountSummaries(
                                currentAccountKey: currentAuthSelection.accountKey,
                                currentVariantKey: currentAuthSelection.variantKey
                            )
                        )
                    }
                }
            }
        case .serial:
            for account in snapshot.accounts {
                let refreshed = await Self.refreshAccount(
                    account,
                    now: now,
                    forceRefresh: force,
                    authRepository: authRepository,
                    usageService: usageService
                )
                if refreshed.attemptedRefresh {
                    attemptedRefreshCount += 1
                }
                if refreshed.didRefreshSucceed {
                    successfulRefreshCount += 1
                }
                if let reason = refreshed.transientFailureReason {
                    transientFailureReasons.append(reason)
                }

                let didChange = Self.mergeRefreshedAccount(refreshed.account, into: &latest)
                guard didChange else { continue }
                didChangeStore = true
                if shouldPersistPartialUpdates {
                    try storeRepository.saveStore(latest)
                }
                if let onPartialUpdate {
                    await onPartialUpdate(
                        latest.accountSummaries(
                            currentAccountKey: currentAuthSelection.accountKey,
                            currentVariantKey: currentAuthSelection.variantKey
                        )
                    )
                }
            }
        }

        if didChangeStore, !shouldPersistPartialUpdates {
            try storeRepository.saveStore(latest)
        }

        let summaries = latest.accountSummaries(
            currentAccountKey: currentAuthSelection.accountKey,
            currentVariantKey: currentAuthSelection.variantKey
        )
        cacheAccountsList(store: latest, currentAuthSelection: currentAuthSelection, summaries: summaries)
        let result = AccountsRefreshResult(
            accounts: summaries,
            failure: Self.refreshFailure(
                reasons: transientFailureReasons,
                attemptedRefreshCount: attemptedRefreshCount,
                successfulRefreshCount: successfulRefreshCount
            )
        )
        let duration = String(Int(Date().timeIntervalSince(startedAt) * 1_000))
        switch result.failure {
        case .none:
            logger.info(
                category: .accounts,
                event: "refresh_usage_succeeded",
                message: "Account usage refresh completed.",
                metadata: [
                    "attempted": String(attemptedRefreshCount),
                    "successful": String(successfulRefreshCount),
                    "duration_ms": duration
                ],
                operationID: operationID
            )
        case .some(.partial(let reason)):
            logger.warning(
                category: .accounts,
                event: "refresh_usage_partial_failure",
                message: "Account usage refresh completed with partial transient failures.",
                metadata: [
                    "attempted": String(attemptedRefreshCount),
                    "successful": String(successfulRefreshCount),
                    "duration_ms": duration,
                    "reason": reason
                ],
                operationID: operationID
            )
        case .some(.complete(let reason)):
            logger.error(
                category: .accounts,
                event: "refresh_usage_failed",
                message: "Account usage refresh failed for all attempted accounts.",
                metadata: [
                    "attempted": String(attemptedRefreshCount),
                    "successful": String(successfulRefreshCount),
                    "duration_ms": duration,
                    "reason": reason
                ],
                operationID: operationID
            )
        }
        return result
    }

    private static func mergeRefreshedAccount(
        _ refreshed: StoredAccount,
        into store: inout AccountsStore
    ) -> Bool {
        guard let index = store.accounts.firstIndex(where: { $0.id == refreshed.id }) else {
            return false
        }
        guard store.accounts[index] != refreshed else {
            return false
        }
        store.accounts[index] = refreshed
        return true
    }

    func refreshWorkspaceMetadata(forceRemoteCheck: Bool) async throws -> [AccountSummary] {
        let operationID = UUID().uuidString
        logger.debug(
            category: .accounts,
            event: "refresh_workspace_metadata_started",
            message: "Starting workspace metadata refresh.",
            metadata: ["force_remote_check": forceRemoteCheck ? "true" : "false"],
            operationID: operationID
        )
        var store = try storeRepository.loadStore()
        let didChange = await enrichStoredWorkspaceMetadataIfNeeded(
            in: &store,
            forceRemoteCheck: forceRemoteCheck
        )
        if didChange {
            try storeRepository.saveStore(store)
        }
        let currentAuthSelection = currentAuthSelectionIdentifiers()
        let summaries = store.accountSummaries(
            currentAccountKey: currentAuthSelection.accountKey,
            currentVariantKey: currentAuthSelection.variantKey
        )
        cacheAccountsList(store: store, currentAuthSelection: currentAuthSelection, summaries: summaries)
        logger.info(
            category: .accounts,
            event: "refresh_workspace_metadata_completed",
            message: "Workspace metadata refresh completed.",
            metadata: [
                "accounts": String(summaries.count),
                "did_change": didChange ? "true" : "false"
            ],
            operationID: operationID
        )
        return summaries
    }

    private static func refreshAccount(
        _ account: StoredAccount,
        now: Int64,
        forceRefresh: Bool,
        authRepository: AuthRepository,
        usageService: UsageService
    ) async -> RefreshAccountResult {
        var account = account
        guard forceRefresh || UsageRefreshPolicy.shouldRefresh(account.usage, now: now) else {
            return RefreshAccountResult(
                account: account,
                attemptedRefresh: false,
                didRefreshSucceed: false,
                transientFailureReason: nil
            )
        }

        do {
            let extracted = try authRepository.extractAuth(from: account.authJSON)
            let usage = try await usageService.fetchUsage(
                accessToken: extracted.accessToken,
                accountID: extracted.accountID
            )
            account.usage = usage
            account.usageError = nil
            account.planType = extracted.planType ?? account.planType
            if let teamName = normalizedTeamName(extracted.teamName) {
                account.teamName = teamName
            }
            account.email = extracted.email ?? account.email
            account.updatedAt = now
            return RefreshAccountResult(
                account: account,
                attemptedRefresh: true,
                didRefreshSucceed: true,
                transientFailureReason: nil
            )
        } catch {
            if let transientFailureReason = transientRefreshFailureReason(for: error) {
                account.usageError = nil
                account.updatedAt = now
                return RefreshAccountResult(
                    account: account,
                    attemptedRefresh: true,
                    didRefreshSucceed: false,
                    transientFailureReason: transientFailureReason
                )
            }

            account.usageError = error.localizedDescription
            account.updatedAt = now
            return RefreshAccountResult(
                account: account,
                attemptedRefresh: true,
                didRefreshSucceed: false,
                transientFailureReason: nil
            )
        }
    }

    private static func refreshFailure(
        reasons: [String],
        attemptedRefreshCount: Int,
        successfulRefreshCount: Int
    ) -> AccountsRefreshFailure? {
        guard attemptedRefreshCount > 0,
              let reason = primaryTransientRefreshFailureReason(from: reasons) else {
            return nil
        }

        return successfulRefreshCount == 0
            ? .complete(reason: reason)
            : .partial(reason: reason)
    }

    private static func primaryTransientRefreshFailureReason(from reasons: [String]) -> String? {
        var seen = Set<String>()
        for rawReason in reasons {
            let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, !seen.contains(reason) else { continue }
            seen.insert(reason)
            return reason
        }
        return nil
    }

    private static func transientRefreshFailureReason(for error: Error) -> String? {
        if let urlError = error as? URLError,
           isTransientNetworkError(urlError) {
            return urlError.localizedDescription
        }

        guard let appError = error as? AppError,
              case .network(let message) = appError,
              isTransientNetworkMessage(message) else {
            return nil
        }

        return message
    }

    private static func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .notConnectedToInternet,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func isTransientNetworkMessage(_ message: String) -> Bool {
        if message.contains("-> 401:") || message.contains("-> 403:") || message.contains("-> 404:")
            || message.contains("-> 429:") || message.contains("-> 500:") || message.contains("-> 502:")
            || message.contains("-> 503:") || message.contains("-> 504:") {
            return false
        }

        let lowercased = message.lowercased()
        let englishIndicators = [
            "timed out",
            "timeout",
            "could not connect",
            "cannot connect",
            "not connected to the internet",
            "internet connection appears to be offline",
            "network connection was lost",
            "dns lookup failed",
            "hostname could not be found",
            "secure connection",
            "socket is not connected"
        ]
        if englishIndicators.contains(where: { lowercased.contains($0) }) {
            return true
        }

        let localizedIndicators = [
            "超时",
            "无法连接",
            "不能连接",
            "未连接互联网",
            "网络连接已丢失",
            "网络连接丢失",
            "离线",
            "主机",
            "域名",
            "安全连接"
        ]
        return localizedIndicators.contains(where: { message.contains($0) })
    }

    private static func reconcileStoredAccountMetadata(
        in store: inout AccountsStore,
        authRepository: AuthRepository
    ) -> (didChange: Bool, extractedAuthByStoredAccountID: [String: ExtractedAuth]) {
        var didChange = false
        var extractedAuthByStoredAccountID: [String: ExtractedAuth] = [:]

        for index in store.accounts.indices {
            let storedAccount = store.accounts[index]
            guard let reconciled = try? authRepository.extractAuth(from: storedAccount.authJSON) else {
                continue
            }
            extractedAuthByStoredAccountID[storedAccount.id] = reconciled

            if store.accounts[index].email != reconciled.email {
                store.accounts[index].email = reconciled.email
                didChange = true
            }

            if store.accounts[index].principalID != reconciled.principalID {
                store.accounts[index].principalID = reconciled.principalID
                didChange = true
            }

            if store.accounts[index].accountID != reconciled.accountID {
                store.accounts[index].accountID = reconciled.accountID
                didChange = true
            }

            if store.accounts[index].planType != reconciled.planType {
                store.accounts[index].planType = reconciled.planType
                didChange = true
            }

            let reconciledTeamName = normalizedTeamName(reconciled.teamName)
            let storedTeamName = normalizedTeamName(store.accounts[index].teamName)
            if let reconciledTeamName, storedTeamName != reconciledTeamName {
                store.accounts[index].teamName = reconciledTeamName
                didChange = true
            }
        }

        return (didChange, extractedAuthByStoredAccountID)
    }

    private func enrichStoredWorkspaceMetadataIfNeeded(
        in store: inout AccountsStore,
        forceRemoteCheck: Bool,
        extractedAuthByStoredAccountID: [String: ExtractedAuth] = [:]
    ) async -> Bool {
        guard let workspaceMetadataService else { return false }

        var didChange = false
        var cachedDirectories: [String: [WorkspaceMetadata]] = [:]

        for index in store.accounts.indices {
            let storedAccount = store.accounts[index]
            let extracted = extractedAuthByStoredAccountID[storedAccount.id]
                ?? (try? authRepository.extractAuth(from: storedAccount.authJSON))
            guard let extracted else {
                #if DEBUG
                debugLog("workspace metadata lookup skipped for stored account \(storedAccount.id): failed to extract auth")
                #endif
                continue
            }
            guard shouldLookupRemoteWorkspaceName(
                storedTeamName: storedAccount.teamName,
                extracted: extracted,
                forceRemoteCheck: forceRemoteCheck,
                allowUnknownPlanWhenForced: false
            ) else {
                #if DEBUG
                debugLog(
                    "workspace metadata lookup skipped for accountID=\(storedAccount.accountID); plan=\(extracted.planType ?? "<nil>"); storedTeamName=\(storedAccount.teamName ?? "<nil>"); forceRemoteCheck=\(forceRemoteCheck)"
                )
                #endif
                continue
            }

            let directory: [WorkspaceMetadata]
            if let cached = cachedDirectories[extracted.accessToken] {
                #if DEBUG
                debugLog("workspace metadata lookup reused cached directory for accountID=\(extracted.accountID); items=\(cached.count)")
                #endif
                directory = cached
            } else {
                guard let fetched = try? await workspaceMetadataService.fetchWorkspaceMetadata(
                    accessToken: extracted.accessToken
                ) else {
                    #if DEBUG
                    debugLog("workspace metadata fetch failed for accountID=\(extracted.accountID)")
                    #endif
                    continue
                }
                cachedDirectories[extracted.accessToken] = fetched
                #if DEBUG
                debugLog("workspace metadata fetched for accountID=\(extracted.accountID); items=\(fetched.count)")
                #endif
                directory = fetched
            }

            guard let remoteWorkspaceName = Self.remoteWorkspaceName(
                for: extracted.accountID,
                in: directory
            ) else {
                #if DEBUG
                debugLog("workspace metadata returned no matching non-personal workspace for accountID=\(extracted.accountID)")
                #endif
                continue
            }

            if store.accounts[index].teamName != remoteWorkspaceName {
                store.accounts[index].teamName = remoteWorkspaceName
                didChange = true
                #if DEBUG
                debugLog("workspace metadata updated accountID=\(extracted.accountID) teamName=\(remoteWorkspaceName)")
                #endif
            } else {
                #if DEBUG
                debugLog("workspace metadata matched accountID=\(extracted.accountID) but teamName already up to date: \(remoteWorkspaceName)")
                #endif
            }
        }

        return didChange
    }

    private func cacheAccountsList(
        store: AccountsStore,
        currentAuthSelection: (accountKey: String?, variantKey: String?),
        summaries: [AccountSummary]
    ) {
        accountsListCache = AccountsListCache(
            accounts: store.accounts,
            currentSelection: store.currentSelection,
            currentAuthAccountKey: currentAuthSelection.accountKey,
            currentAuthVariantKey: currentAuthSelection.variantKey,
            summaries: summaries
        )
    }

    private func resolveRemoteWorkspaceName(
        for extracted: ExtractedAuth,
        forceRemoteCheck: Bool,
        allowUnknownPlanWhenForced: Bool = false
    ) async -> String? {
        guard let workspaceMetadataService else { return nil }
        guard shouldLookupRemoteWorkspaceName(
            storedTeamName: extracted.teamName,
            extracted: extracted,
            forceRemoteCheck: forceRemoteCheck,
            allowUnknownPlanWhenForced: allowUnknownPlanWhenForced
        ) else {
            return extracted.teamName
        }
        guard let directory = try? await workspaceMetadataService.fetchWorkspaceMetadata(
            accessToken: extracted.accessToken
        ) else {
            return extracted.teamName
        }
        return Self.remoteWorkspaceName(for: extracted.accountID, in: directory) ?? extracted.teamName
    }

    private func shouldLookupRemoteWorkspaceName(
        storedTeamName: String?,
        extracted: ExtractedAuth,
        forceRemoteCheck: Bool,
        allowUnknownPlanWhenForced: Bool
    ) -> Bool {
        let normalizedPlan = (extracted.planType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shouldCheckWithoutStoredName = forceRemoteCheck || Self.normalizedTeamName(storedTeamName) == nil

        if normalizedPlan == "team" || normalizedPlan == "business" || normalizedPlan == "enterprise" {
            return shouldCheckWithoutStoredName
        }

        if allowUnknownPlanWhenForced && forceRemoteCheck {
            return shouldCheckWithoutStoredName
        }

        return false
    }

    private static func normalizedTeamName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func remoteWorkspaceName(
        for accountID: String,
        in metadata: [WorkspaceMetadata]
    ) -> String? {
        guard let match = metadata.first(where: { $0.accountID == accountID }) else {
            return nil
        }

        let trimmed = match.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }

        if match.structure?.lowercased() == "personal" {
            return nil
        }

        return trimmed
    }

    private func toSummary(
        _ account: StoredAccount,
        currentAccountKey: String?,
        currentVariantKey: String?
    ) -> AccountSummary {
        AccountsStore(accounts: [account]).accountSummaries(
            currentAccountKey: currentAccountKey,
            currentVariantKey: currentVariantKey
        )[0]
    }

    private func updateCurrentAccountProjection(_ account: StoredAccount) throws {
        var store = try storeRepository.loadStore()
        guard store.accounts.contains(where: { $0.id == account.id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        _ = backfillCurrentLiveAuthIfNeeded(in: &store)
        guard let targetAccount = store.accounts.first(where: { $0.id == account.id }) else {
            throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
        }

        store.currentSelection = makeCurrentAccountSelection(for: targetAccount, sourceDeviceID: "macos-local")
        try storeRepository.saveStore(store)

        try authRepository.writeCurrentAuth(targetAccount.authJSON)
    }

    @discardableResult
    private func backfillCurrentLiveAuthIfNeeded(
        in store: inout AccountsStore,
        excludingStoredAccountIDs: Set<String> = []
    ) -> Bool {
        guard let liveAuth = try? authRepository.readCurrentAuthOptional(),
              let extracted = try? authRepository.extractAuth(from: liveAuth),
              let currentIndex = liveAuthBackfillAccountIndex(
                  in: store,
                  extracted: extracted,
                  excludingStoredAccountIDs: excludingStoredAccountIDs
              ) else {
            return false
        }

        var currentAccount = store.accounts[currentIndex]
        let didChange = applyLiveAuthSnapshot(liveAuth, extracted: extracted, to: &currentAccount)
        guard didChange else { return false }

        currentAccount.updatedAt = dateProvider.unixSecondsNow()
        store.accounts[currentIndex] = currentAccount
        return true
    }

    private func syncCurrentLiveAuthProjectionFromDisk(in store: inout AccountsStore) -> Bool {
        let liveAuth: JSONValue?
        do {
            liveAuth = try authRepository.readCurrentAuthOptional()
        } catch {
            return false
        }

        guard let liveAuth else {
            if store.currentSelection != nil {
                store.currentSelection = nil
                return true
            }
            return false
        }

        guard let extracted = try? authRepository.extractAuth(from: liveAuth) else {
            return false
        }

        guard let currentIndex = liveAuthBackfillAccountIndex(
            in: store,
            extracted: extracted,
            excludingStoredAccountIDs: []
        ) else {
            if store.currentSelection != nil {
                store.currentSelection = nil
                return true
            }
            return false
        }

        var currentAccount = store.accounts[currentIndex]
        var didChange = applyLiveAuthSnapshot(liveAuth, extracted: extracted, to: &currentAccount)
        if didChange {
            currentAccount.updatedAt = dateProvider.unixSecondsNow()
            store.accounts[currentIndex] = currentAccount
        }

        let nextSelection = makeCurrentAccountSelection(
            for: currentAccount,
            sourceDeviceID: "macos-live-auth-watch"
        )
        if store.currentSelection?.resolvedAccountKey != nextSelection.resolvedAccountKey
            || store.currentSelection?.resolvedVariantKey != nextSelection.resolvedVariantKey {
            store.currentSelection = nextSelection
            didChange = true
        }

        return didChange
    }

    private func applyLiveAuthSnapshot(
        _ liveAuth: JSONValue,
        extracted: ExtractedAuth,
        to account: inout StoredAccount
    ) -> Bool {
        var didChange = false

        if account.authJSON != liveAuth {
            account.authJSON = liveAuth
            didChange = true
        }

        if account.accountID != extracted.accountID {
            account.accountID = extracted.accountID
            didChange = true
        }

        if let principalID = extracted.principalID,
           account.principalID != principalID {
            account.principalID = principalID
            didChange = true
        }

        if let email = normalizedText(extracted.email),
           account.email != email {
            account.email = email
            didChange = true
        }

        if let planType = normalizedText(extracted.planType),
           account.planType != planType {
            account.planType = planType
            didChange = true
        }

        if let teamName = Self.normalizedTeamName(extracted.teamName),
           account.teamName != teamName {
            account.teamName = teamName
            didChange = true
        }

        return didChange
    }

    private func liveAuthBackfillAccountIndex(
        in store: AccountsStore,
        extracted: ExtractedAuth,
        excludingStoredAccountIDs: Set<String>
    ) -> Int? {
        let candidateIndices = store.accounts.indices.filter { index in
            !excludingStoredAccountIDs.contains(store.accounts[index].id)
        }

        let liveVariantKey = AccountIdentity.variantIdentifier(variantKey: extracted.variantKey)
        if let liveVariantKey,
           let exactVariantIndex = candidateIndices.first(where: { store.accounts[$0].variantKey == liveVariantKey }) {
            return exactVariantIndex
        }

        let liveAccountKey = AccountIdentity.normalizedAccountID(extracted.accountKey)
        if let liveAccountKey,
           let exactAccountKeyIndex = candidateIndices.first(where: { store.accounts[$0].accountKey == liveAccountKey }) {
            return exactAccountKeyIndex
        }

        let normalizedAccountID = AccountIdentity.normalizedAccountID(extracted.accountID) ?? extracted.accountID
        return candidateIndices.first(where: {
            let storedAccountID = AccountIdentity.normalizedAccountID(store.accounts[$0].accountID)
                ?? store.accounts[$0].accountID
            return storedAccountID == normalizedAccountID
        })
    }

    private func makeCurrentAccountSelection(
        for account: StoredAccount,
        sourceDeviceID: String
    ) -> CurrentAccountSelection {
        CurrentAccountSelection(
            accountID: account.accountID,
            accountKey: account.accountKey,
            variantKey: account.variantKey,
            selectedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: sourceDeviceID
        )
    }

    private func normalizeTeamAlias(_ alias: String?) -> String? {
        guard let alias else { return nil }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if DEBUG
    private func debugLog(_ message: String) {
        _ = message
        // print("AccountsCoordinator:", message)
    }
    #endif

    private func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedCurrentSelectionIdentifiers(
        in store: AccountsStore
    ) -> (accountKey: String?, variantKey: String?) {
        if let currentSelection = store.currentSelection {
            return (currentSelection.resolvedAccountKey, currentSelection.resolvedVariantKey)
        }
        return currentAuthSelectionIdentifiers()
    }

    private func currentAuthSelectionIdentifiers() -> (accountKey: String?, variantKey: String?) {
        if let auth = try? authRepository.readCurrentAuthOptional(),
           let extracted = try? authRepository.extractAuth(from: auth) {
            return (extracted.accountKey, extracted.variantKey)
        }
        return (authRepository.currentAuthAccountID(), nil)
    }
}
