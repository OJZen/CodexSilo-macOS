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
    private var accountsListCache: AccountsListCache?

    init(
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository,
        usageService: UsageService,
        workspaceMetadataService: WorkspaceMetadataService? = nil,
        chatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.usageService = usageService
        self.workspaceMetadataService = workspaceMetadataService
        self.chatGPTOAuthLoginService = chatGPTOAuthLoginService
        self.dateProvider = dateProvider
    }

    func listAccounts() async throws -> [AccountSummary] {
        var store = try storeRepository.loadStore()
        let currentAuthSelection = currentAuthSelectionIdentifiers()
        if let accountsListCache,
           accountsListCache.matches(store: store, currentAuthSelection: currentAuthSelection) {
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
        var extracted = try authRepository.extractAuth(from: authJSON)

        var usage: UsageSnapshot?
        var usageError: String?

        do {
            usage = try await usageService.fetchUsage(accessToken: extracted.accessToken, accountID: extracted.accountID)
        } catch {
            usageError = error.localizedDescription
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

        if shouldSetAsCurrent {
            store.currentSelection = CurrentAccountSelection(
                accountID: extracted.accountID,
                accountKey: extracted.accountKey,
                variantKey: extracted.variantKey,
                selectedAt: dateProvider.unixMillisecondsNow(),
                sourceDeviceID: "macos-local"
            )
        }

        try storeRepository.saveStore(store)
        let savedAccount: StoredAccount
        if let existingIndex {
            savedAccount = store.accounts[existingIndex]
        } else {
            savedAccount = store.accounts.last!
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
        return toSummary(
            savedAccount,
            currentAccountKey: effectiveCurrentAccountKey,
            currentVariantKey: effectiveCurrentVariantKey
        )
    }

    func deleteAccount(id: String) throws {
        var store = try storeRepository.loadStore()
        store.accounts.removeAll { $0.id == id }
        try storeRepository.saveStore(store)
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
        let tokens = try await chatGPTOAuthLoginService.signInWithChatGPT(timeoutSeconds: timeoutSeconds)
        let authJSON = try authRepository.makeChatGPTAuth(from: tokens)
        return try await importAccount(authJSON: authJSON, customLabel: customLabel)
    }

    func refreshAllUsage() async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .parallel, force: false, onPartialUpdate: nil)
    }

    func refreshAllUsageSerially() async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .serial, force: false, onPartialUpdate: nil)
    }

    func refreshAllUsage(force: Bool) async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .parallel, force: force, onPartialUpdate: nil)
    }

    func refreshAllUsageSerially(force: Bool) async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .serial, force: force, onPartialUpdate: nil)
    }

    func refreshAllUsage(
        force: Bool,
        onPartialUpdate: @escaping @Sendable ([AccountSummary]) async -> Void
    ) async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .parallel, force: force, onPartialUpdate: onPartialUpdate)
    }

    func refreshAllUsageSerially(
        force: Bool,
        onPartialUpdate: @escaping @Sendable ([AccountSummary]) async -> Void
    ) async throws -> [AccountSummary] {
        try await refreshAllUsage(using: .serial, force: force, onPartialUpdate: onPartialUpdate)
    }

    private func refreshAllUsage(
        using mode: UsageRefreshExecutionMode,
        force: Bool,
        onPartialUpdate: (@Sendable ([AccountSummary]) async -> Void)?
    ) async throws -> [AccountSummary] {
        let now = dateProvider.unixSecondsNow()
        let snapshot = try storeRepository.loadStore()
        let authRepository = self.authRepository
        let usageService = self.usageService
        let currentAuthSelection = currentAuthSelectionIdentifiers()
        let shouldPersistPartialUpdates = onPartialUpdate != nil

        var latest = snapshot
        var didChangeStore = false
        switch mode {
        case .parallel:
            try await withThrowingTaskGroup(of: StoredAccount.self, returning: Void.self) { group in
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
                    let didChange = Self.mergeRefreshedAccount(refreshed, into: &latest)
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
                let didChange = Self.mergeRefreshedAccount(refreshed, into: &latest)
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
        return summaries
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
        return summaries
    }

    private static func refreshAccount(
        _ account: StoredAccount,
        now: Int64,
        forceRefresh: Bool,
        authRepository: AuthRepository,
        usageService: UsageService
    ) async -> StoredAccount {
        var account = account
        guard forceRefresh || UsageRefreshPolicy.shouldRefresh(account.usage, now: now) else {
            return account
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
        } catch {
            account.usageError = error.localizedDescription
        }

        account.updatedAt = now
        return account
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

        if allowUnknownPlanWhenForced && normalizedPlan.isEmpty {
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

        store.currentSelection = CurrentAccountSelection(
            accountID: account.accountID,
            accountKey: account.accountKey,
            variantKey: account.variantKey,
            selectedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: "macos-local"
        )
        try storeRepository.saveStore(store)

        try authRepository.writeCurrentAuth(account.authJSON)
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
