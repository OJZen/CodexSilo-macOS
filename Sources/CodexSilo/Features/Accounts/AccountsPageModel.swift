import Foundation
import Combine

@MainActor
final class AccountsPageModel: ObservableObject {
    private enum WindowPresentationRefreshPolicy {
        static let minimumInterval: TimeInterval = 60
    }

    private let coordinator: AccountsCoordinator
    private let manualRefreshService: AccountsManualRefreshServiceProtocol?
    private let localAccountsMutationSyncService: AccountsLocalMutationSyncServiceProtocol?
    private let currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol?
    private let onLocalAccountsChanged: (([AccountSummary]) -> Void)?
    private let nowProvider: () -> Date
    private let logger: AppLogger
    private let noticeScheduler = NoticeAutoDismissScheduler()
    private var prefersCollapsedOverview = false
    private var hasLoaded = false
    private var addAccountTask: Task<Void, Never>?
    private var lastWindowPresentationRefreshAt: Date?

    @Published var state: ViewState<[AccountSummary]>
    @Published private(set) var sortMode: AccountsSortMode = .remainingUsage
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }
    @Published private var isManualRefreshing = false
    @Published private(set) var isRemoteUsageRefreshing = false
    @Published var isImporting = false
    @Published var isAdding = false
    @Published var switchingAccountID: String?
    @Published private(set) var collapsedAccountIDs: Set<String> = []
    @Published var accountEditor: AccountConfigurationDraft?

    init(
        coordinator: AccountsCoordinator,
        manualRefreshService: AccountsManualRefreshServiceProtocol? = nil,
        localAccountsMutationSyncService: AccountsLocalMutationSyncServiceProtocol? = nil,
        currentAccountSelectionSyncService: CurrentAccountSelectionSyncServiceProtocol? = nil,
        onLocalAccountsChanged: (([AccountSummary]) -> Void)? = nil,
        nowProvider: @escaping () -> Date = Date.init,
        logger: AppLogger = NoopAppLogger.shared,
        initialAccounts: [AccountSummary]? = nil,
        initialOverviewCollapsed: Bool = false
    ) {
        self.coordinator = coordinator
        self.manualRefreshService = manualRefreshService
        self.localAccountsMutationSyncService = localAccountsMutationSyncService
        self.currentAccountSelectionSyncService = currentAccountSelectionSyncService
        self.onLocalAccountsChanged = onLocalAccountsChanged
        self.nowProvider = nowProvider
        self.logger = logger
        self.prefersCollapsedOverview = initialOverviewCollapsed
        self.state = initialAccounts.map { initialAccounts in
            Self.makeViewState(accounts: initialAccounts, sortMode: .remainingUsage)
        } ?? .loading
        if initialOverviewCollapsed, let initialAccounts {
            self.collapsedAccountIDs = Set(initialAccounts.map(\.id))
        }
    }

    func loadIfNeeded() async {
        if !hasLoaded {
            await load()
        }
    }

    func load() async {
        do {
            let accounts = try await coordinator.listAccounts()
            prefersCollapsedOverview = try await coordinator.accountsOverviewCollapsed()
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            hasLoaded = true
            logger.debug(
                category: .accounts,
                event: "page_load_succeeded",
                message: "Accounts page loaded.",
                metadata: ["accounts": String(accounts.count)]
            )
        } catch {
            state = .error(message: error.localizedDescription)
            hasLoaded = true
            logger.error(
                category: .accounts,
                event: "page_load_failed",
                message: "Accounts page failed to load.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func refreshAccountsOnWindowPresentation() async {
        guard !isManualRefreshing else {
            logger.debug(
                category: .accounts,
                event: "window_refresh_skipped",
                message: "Skipped window refresh because a manual refresh is in progress."
            )
            return
        }

        let now = nowProvider()
        if let lastWindowPresentationRefreshAt,
           now.timeIntervalSince(lastWindowPresentationRefreshAt) < WindowPresentationRefreshPolicy.minimumInterval {
            logger.debug(
                category: .accounts,
                event: "window_refresh_throttled",
                message: "Skipped window refresh because the minimum interval has not elapsed."
            )
            return
        }
        lastWindowPresentationRefreshAt = now

        if !hasLoaded {
            await load()
        }
        await refreshUsage(showSuccessNotice: false)
    }

    func importCurrentAuth() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let imported = try await coordinator.importCurrentAuthAccount(customLabel: nil)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            notice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.imported_format", imported.label))
            logger.info(
                category: .accounts,
                event: "import_current_auth_succeeded",
                message: "Imported current auth from the accounts page.",
                metadata: ["label": imported.label]
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .accounts,
                event: "import_current_auth_failed",
                message: "Failed to import current auth from the accounts page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    deinit {
        addAccountTask?.cancel()
    }

    func addAccountViaLogin() {
        guard addAccountTask == nil else { return }
        isAdding = true
        logger.info(
            category: .accounts,
            event: "page_add_account_started",
            message: "Started add-account flow from the accounts page."
        )
        addAccountTask = Task { [weak self] in
            guard let self else { return }

            do {
                let imported = try await self.coordinator.addAccountViaLogin(customLabel: nil)
                let accounts = try await self.coordinator.listAccounts()
                await MainActor.run {
                    self.applyAccounts(accounts)
                    self.publishAndSyncLocalAccountsMutation(accounts)
                    self.notice = NoticeMessage(
                        style: .success,
                        text: L10n.tr("accounts.notice.imported_new_format", imported.label)
                    )
                    self.logger.info(
                        category: .accounts,
                        event: "page_add_account_succeeded",
                        message: "Add-account flow completed from the accounts page.",
                        metadata: ["label": imported.label]
                    )
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        self.notice = NoticeMessage(style: .info, text: "当前登录流程已取消。")
                        self.logger.warning(
                            category: .accounts,
                            event: "page_add_account_cancelled",
                            message: "Add-account flow was cancelled from the accounts page."
                        )
                    }
                } else {
                    await MainActor.run {
                        self.notice = NoticeMessage(style: .error, text: error.localizedDescription)
                        self.logger.error(
                            category: .accounts,
                            event: "page_add_account_failed",
                            message: "Add-account flow failed from the accounts page.",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
            }

            await MainActor.run {
                self.isAdding = false
                self.addAccountTask = nil
            }
        }
    }

    func cancelAddAccountViaLogin() {
        addAccountTask?.cancel()
    }

    func importAuthDocument(from url: URL, setAsCurrent: Bool) async {
        if setAsCurrent {
            isImporting = true
        } else {
            isAdding = true
        }
        defer {
            if setAsCurrent {
                isImporting = false
            } else {
                isAdding = false
            }
        }

        do {
            let imported = try await coordinator.importAccountFile(
                from: url,
                customLabel: nil,
                setAsCurrent: setAsCurrent
            )
            if setAsCurrent {
                syncCurrentAccountSelectionInBackground(accountID: imported.variantKey)
            }
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            let key = setAsCurrent
                ? "accounts.notice.imported_format"
                : "accounts.notice.imported_new_format"
            notice = NoticeMessage(style: .success, text: L10n.tr(key, imported.label))
            logger.info(
                category: .accounts,
                event: "import_document_succeeded",
                message: "Imported account document from the accounts page.",
                metadata: [
                    "label": imported.label,
                    "set_as_current": setAsCurrent ? "true" : "false"
                ]
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .accounts,
                event: "import_document_failed",
                message: "Failed to import account document from the accounts page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func reportImportSelectionFailure(_ error: Error) {
        notice = NoticeMessage(style: .error, text: error.localizedDescription)
    }

    func presentCustomImportEditor() {
        accountEditor = .customImportTemplate()
    }

    func editAccount(id: String) async {
        do {
            accountEditor = try await coordinator.accountConfigurationDraft(id: id)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func dismissAccountEditor() {
        accountEditor = nil
    }

    func saveAccountEditor(_ draft: AccountConfigurationDraft) async -> String? {
        do {
            let savedAccount = try await coordinator.saveAccountConfiguration(draft)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            if savedAccount.isCurrent || draft.setAsCurrent {
                syncCurrentAccountSelectionInBackground(accountID: savedAccount.variantKey)
            }
            notice = NoticeMessage(style: .success, text: "账户配置已保存。")
            logger.info(
                category: .accounts,
                event: "save_account_editor_succeeded",
                message: "Saved account configuration from the accounts page.",
                metadata: ["label": savedAccount.label]
            )
            return nil
        } catch {
            logger.error(
                category: .accounts,
                event: "save_account_editor_failed",
                message: "Failed to save account configuration from the accounts page.",
                metadata: ["error": error.localizedDescription]
            )
            return error.localizedDescription
        }
    }

    func refreshUsage() async {
        await refreshUsage(showSuccessNotice: true)
    }

    private func refreshUsage(showSuccessNotice: Bool) async {
        guard !isManualRefreshing else {
            logger.debug(
                category: .accounts,
                event: "manual_refresh_skipped",
                message: "Skipped manual refresh because another refresh is in progress."
            )
            return
        }
        isManualRefreshing = true
        defer { isManualRefreshing = false }
        let operationID = UUID().uuidString
        logger.info(
            category: .accounts,
            event: "manual_refresh_started",
            message: "Started manual accounts refresh.",
            operationID: operationID
        )

        do {
            let result: AccountsRefreshResult
            if let manualRefreshService {
                result = try await manualRefreshService.performManualRefresh(
                    onPartialUpdate: { [weak self] accounts in
                        guard let self else { return }
                        self.applyAccounts(accounts)
                        self.publishLocalAccounts(accounts)
                    }
                )
            } else {
                result = try await coordinator.refreshAllUsageResult(
                    force: true,
                    onPartialUpdate: { [weak self] accounts in
                        guard let self else { return }
                        await MainActor.run {
                            self.applyAccounts(accounts)
                            self.publishLocalAccounts(accounts)
                        }
                    }
                )
            }
            let accounts = result.accounts
            applyAccounts(accounts)
            publishLocalAccounts(accounts)
            if let failure = result.failure {
                notice = NoticeMessage(style: .error, text: refreshFailureNoticeText(for: failure))
            } else if showSuccessNotice {
                let noticeKey = manualRefreshService == nil
                    ? "accounts.notice.usage_refreshed"
                    : "accounts.notice.accounts_refreshed"
                notice = NoticeMessage(style: .info, text: L10n.tr(noticeKey))
            }
            logger.info(
                category: .accounts,
                event: "manual_refresh_completed",
                message: "Manual accounts refresh completed.",
                metadata: [
                    "accounts": String(accounts.count),
                    "result": result.failure == nil ? "success" : "partial_or_failed"
                ],
                operationID: operationID
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .accounts,
                event: "manual_refresh_failed",
                message: "Manual accounts refresh failed.",
                metadata: ["error": error.localizedDescription],
                operationID: operationID
            )
        }
    }

    func deleteAccount(id: String) async {
        do {
            try await coordinator.deleteAccount(id: id)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.account_deleted"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func saveTeamAlias(id: String, alias: String?) async {
        do {
            _ = try await coordinator.updateTeamAlias(id: id, alias: alias)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            notice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.team_name_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func switchAccount(id: String) async {
        switchingAccountID = id
        defer { switchingAccountID = nil }

        do {
            try await coordinator.switchAccountAndApplySettings(id: id)
            let accounts = try await coordinator.listAccounts()
            guard let selectedAccount = accounts.first(where: { $0.id == id }) else {
                throw AppError.invalidData(L10n.tr("error.accounts.account_not_found_for_switch"))
            }
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            syncCurrentAccountSelectionInBackground(accountID: selectedAccount.variantKey)
            notice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.switch_done"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func smartSwitch() async {
        do {
            let accountsBefore = try await coordinator.listAccounts()
            let sorted = AccountRanking.sortByRemaining(accountsBefore)
            guard let best = sorted.first else {
                notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.no_switch_target"))
                return
            }
            if best.isCurrent {
                notice = NoticeMessage(style: .info, text: L10n.tr("accounts.notice.already_best"))
                return
            }

            try await coordinator.switchAccountAndApplySettings(id: best.id)
            let accounts = try await coordinator.listAccounts()
            applyAccounts(accounts)
            publishAndSyncLocalAccountsMutation(accounts)
            syncCurrentAccountSelectionInBackground(accountID: best.variantKey)
            var switchNotice = NoticeMessage(style: .success, text: L10n.tr("accounts.notice.switch_done"))
            switchNotice.text = L10n.tr("accounts.notice.smart_switched_prefix_format", best.label, switchNotice.text)
            notice = switchNotice
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func isAccountCollapsed(_ id: String) -> Bool {
        collapsedAccountIDs.contains(id)
    }

    var areAllAccountsCollapsed: Bool {
        guard case .content(let accounts) = state else { return false }
        let ids = Set(accounts.map(\.id))
        guard !ids.isEmpty else { return false }
        return collapsedAccountIDs.isSuperset(of: ids)
    }

    var canImportCurrentAuthAction: Bool {
        !isImporting && !isAdding
    }

    var canAddAccountAction: Bool {
        !isImporting && !isAdding
    }

    var canCancelAddAccountAction: Bool {
        addAccountTask != nil
    }

    var canSmartSwitchAction: Bool {
        !isImporting && !isAdding && switchingAccountID == nil
    }

    var canRefreshUsageAction: Bool {
        !isAdding
    }

    var canEditAccountConfiguration: Bool {
        !isImporting && !isAdding && switchingAccountID == nil
    }

    func toggleAllAccountsCollapsed() {
        let nextCollapsed = !areAllAccountsCollapsed
        prefersCollapsedOverview = nextCollapsed

        if case .content(let accounts) = state {
            collapsedAccountIDs = nextCollapsed ? Set(accounts.map(\.id)) : []
        } else if !nextCollapsed {
            collapsedAccountIDs = []
        }

        Task { [coordinator] in
            try? await coordinator.setAccountsOverviewCollapsed(nextCollapsed)
        }
    }

    func setSortMode(_ value: AccountsSortMode) {
        guard sortMode != value else { return }
        sortMode = value

        guard case .content(let accounts) = state else { return }
        state = Self.makeViewState(accounts: accounts, sortMode: sortMode)
    }

    var hasResolvedInitialState: Bool {
        if case .loading = state {
            return false
        }
        return true
    }

    /// Applies account snapshots produced by the global background refresh pipeline.
    /// This keeps the Accounts page in sync without creating a duplicate timer.
    func syncFromBackgroundRefresh(_ accounts: [AccountSummary]) {
        applyAccounts(accounts)
    }

    func syncRemoteUsageRefreshActivity(isRefreshing: Bool) {
        guard isRemoteUsageRefreshing != isRefreshing else { return }
        isRemoteUsageRefreshing = isRefreshing
    }

    static func makeViewState(
        accounts: [AccountSummary],
        sortMode: AccountsSortMode = .remainingUsage
    ) -> ViewState<[AccountSummary]> {
        let sorted = AccountRanking.sortForDisplay(accounts, mode: sortMode)
        if sorted.isEmpty {
            return .empty(message: L10n.tr("accounts.empty.message.no_accounts"))
        }
        return .content(sorted)
    }

    private func applyAccounts(_ accounts: [AccountSummary]) {
        let sorted = AccountRanking.sortForDisplay(accounts, mode: sortMode)
        let availableIDs = Set(sorted.map(\.id))
        let nextCollapsed = prefersCollapsedOverview ? availableIDs : []
        if nextCollapsed != collapsedAccountIDs {
            collapsedAccountIDs = nextCollapsed
        }

        let nextState = AccountsPageModel.makeViewState(
            accounts: sorted,
            sortMode: sortMode
        )
        if state != nextState {
            state = nextState
        }
    }

    private func syncCurrentAccountSelection(accountID: String) async {
        guard let currentAccountSelectionSyncService else { return }
        do {
            try await currentAccountSelectionSyncService.recordLocalSelection(accountID: accountID)
            try await currentAccountSelectionSyncService.pushLocalSelectionIfNeeded()
        } catch {
            #if DEBUG
            // print("Current account selection sync skipped:", error.localizedDescription)
            #endif
        }
    }

    private func syncCurrentAccountSelectionInBackground(accountID: String) {
        Task {
            await syncCurrentAccountSelection(accountID: accountID)
        }
    }

    private func publishLocalAccounts(_ accounts: [AccountSummary]) {
        onLocalAccountsChanged?(AccountRanking.sortForDisplay(accounts, mode: sortMode))
    }

    private func publishAndSyncLocalAccountsMutation(_ accounts: [AccountSummary]) {
        publishLocalAccounts(accounts)
        Task { @MainActor [weak self] in
            await self?.localAccountsMutationSyncService?.syncLocalAccountsMutationNow()
        }
    }

    var isRefreshing: Bool {
        isManualRefreshing || isRemoteUsageRefreshing
    }

    var isRefreshSpinnerActive: Bool {
        isManualRefreshing
    }

    private func refreshFailureNoticeText(for failure: AccountsRefreshFailure) -> String {
        switch failure {
        case .complete(let reason):
            return L10n.tr("accounts.notice.refresh_failed_format", reason)
        case .partial(let reason):
            return L10n.tr("accounts.notice.refresh_partially_failed_format", reason)
        }
    }
}
