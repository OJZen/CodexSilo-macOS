import XCTest
@testable import CodexSilo

final class AccountsCoordinatorTests: XCTestCase {
    func testListAccountsBackfillsWorkspaceNameFromRemoteMetadata() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Team",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil,
                settings: .defaultValue
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testListAccountsReconcilesStoredWorkspaceMetadataFromAuthJSON() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: nil,
                        accountID: "account-1",
                        planType: nil,
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil,
                settings: .defaultValue
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.email, "test@example.com")
        XCTAssertEqual(accounts.first?.planType, "pro")
        XCTAssertEqual(accounts.first?.teamName, "workspace-x")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "workspace-x")
    }

    func testListAccountsDoesNotClearStoredWorkspaceNameWhenAuthLacksTeamName() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Test",
                        email: "test@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "remote-space",
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil,
                settings: .defaultValue
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.listAccounts()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testListAccountsReusesPreparedResultsWhenStoreIsUnchanged() async throws {
        let now: Int64 = 1_763_216_000
        let authRepository = CountingMultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": ExtractedAuth(
                    accountID: "account-1",
                    accessToken: "token-1",
                    email: "first@example.com",
                    planType: "team",
                    teamName: nil
                ),
                "account-2": ExtractedAuth(
                    accountID: "account-2",
                    accessToken: "token-2",
                    email: "second@example.com",
                    planType: "team",
                    teamName: nil
                )
            ],
            currentAccountID: "account-1"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "First",
                        email: nil,
                        accountID: "account-1",
                        planType: nil,
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["account_id": .string("account-1")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Second",
                        email: nil,
                        accountID: "account-2",
                        planType: nil,
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["account_id": .string("account-2")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil,
                settings: .defaultValue
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [
                    WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-1", structure: "workspace"),
                    WorkspaceMetadata(accountID: "account-2", workspaceName: "remote-2", structure: "workspace")
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let first = try await coordinator.listAccounts()
        let second = try await coordinator.listAccounts()

        XCTAssertEqual(first, second)
        XCTAssertEqual(authRepository.extractCallCount, 2)
    }

    func testImportCurrentAuthPrefersRemoteWorkspaceMetadata() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let imported = try await coordinator.importCurrentAuthAccount(customLabel: nil)
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(imported.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testAddAccountViaLoginPrefersRemoteWorkspaceMetadataAfterUsageBackfillsPlan() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: LoginRemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: StubWorkspaceMetadataService(
                metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let imported = try await coordinator.addAccountViaLogin(customLabel: nil)
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(imported.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testForcedRefreshBypassesUsageThrottle() async throws {
        let now: Int64 = 1_763_216_000
        let existingUsage = UsageSnapshot(
            fetchedAt: now,
            planType: "pro",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: UsageWindow(usedPercent: 20, windowSeconds: 604_800, resetAt: nil),
            credits: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "Test",
                    email: "test@example.com",
                    accountID: "account-1",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: now,
                    updatedAt: now,
                    usage: existingUsage,
                    usageError: nil
                )
            ],
            currentSelection: nil,
            settings: .defaultValue
        )
        let usageService = CountingUsageService(result: existingUsage)
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            authRepository: StubAuthRepository(),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshAllUsage()
        XCTAssertEqual(usageService.callCount, 0)

        _ = try await coordinator.refreshAllUsage(force: true)
        XCTAssertEqual(usageService.callCount, 1)
    }

    func testRefreshAllUsageDoesNotClearStoredWorkspaceNameWhenAuthLacksTeamName() async throws {
        let now: Int64 = 1_763_216_000
        let existingUsage = UsageSnapshot(
            fetchedAt: now - 60,
            planType: "team",
            fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
            oneWeek: nil,
            credits: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "Test",
                    email: "test@example.com",
                    accountID: "account-1",
                    planType: "team",
                    teamName: "remote-space",
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: now,
                    updatedAt: now,
                    usage: existingUsage,
                    usageError: nil
                )
            ],
            currentSelection: nil,
            settings: .defaultValue
        )
        let storeRepository = InMemoryAccountsStoreRepository(store: store)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.refreshAllUsage(force: true)
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(accounts.first?.teamName, "remote-space")
        XCTAssertEqual(savedStore.accounts.first?.teamName, "remote-space")
    }

    func testRefreshAllUsageDoesNotBlockOnWorkspaceMetadataLookup() async throws {
        let now: Int64 = 1_763_216_000
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "Test",
                    email: nil,
                    accountID: "account-1",
                    planType: nil,
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: now,
                    updatedAt: now,
                    usage: nil,
                    usageError: nil
                )
            ],
            currentSelection: nil,
            settings: .defaultValue
        )
        let metadataService = RecordingWorkspaceMetadataService(
            metadata: [WorkspaceMetadata(accountID: "account-1", workspaceName: "remote-space", structure: "workspace")]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            authRepository: RemoteLookupAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            workspaceMetadataService: metadataService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.refreshAllUsage(force: true)

        XCTAssertEqual(metadataService.callCount, 0)
        XCTAssertNil(accounts.first?.teamName)

        let enrichedAccounts = try await coordinator.refreshWorkspaceMetadata(forceRemoteCheck: true)
        XCTAssertEqual(metadataService.callCount, 1)
        XCTAssertEqual(enrichedAccounts.first?.teamName, "remote-space")
    }

    func testRefreshAllUsageSeriallyStreamsPartialAccountUpdates() async throws {
        let now: Int64 = 1_763_216_000
        let store = AccountsStore(
            version: 1,
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "First",
                    email: "first@example.com",
                    accountID: "account-1",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object(["account_id": .string("account-1")]),
                    addedAt: now,
                    updatedAt: now,
                    usage: nil,
                    usageError: nil
                ),
                StoredAccount(
                    id: "acct-2",
                    label: "Second",
                    email: "second@example.com",
                    accountID: "account-2",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object(["account_id": .string("account-2")]),
                    addedAt: now,
                    updatedAt: now,
                    usage: nil,
                    usageError: nil
                )
            ],
            currentSelection: nil,
            settings: .defaultValue
        )
        let usageService = AccountIDUsageService(
            results: [
                "account-1": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 10, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                ),
                "account-2": UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 80, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                )
            ]
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "first@example.com",
                        planType: "pro",
                        teamName: nil
                    ),
                    "account-2": ExtractedAuth(
                        accountID: "account-2",
                        accessToken: "token-2",
                        email: "second@example.com",
                        planType: "pro",
                        teamName: nil
                    )
                ],
                currentAccountID: "account-1"
            ),
            usageService: usageService,
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let recorder = PartialUpdateRecorder()
        let accounts = try await coordinator.refreshAllUsageSerially(
            force: true,
            onPartialUpdate: { accounts in
                await recorder.record(accounts)
            }
        )
        let partialUpdates = await recorder.values()

        XCTAssertEqual(partialUpdates.count, 2)
        XCTAssertEqual(partialUpdates.first?.count, 2)
        XCTAssertNotNil(partialUpdates.first?[0].usage)
        XCTAssertNil(partialUpdates.first?[1].usage)
        XCTAssertNotNil(partialUpdates.last?[0].usage)
        XCTAssertNotNil(partialUpdates.last?[1].usage)
        XCTAssertEqual(accounts, partialUpdates.last)
    }

    func testRefreshAllUsagePersistsOnceWhenPartialUpdatesAreNotRequested() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                version: 1,
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "First",
                        email: "first@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Second",
                        email: "second@example.com",
                        accountID: "account-2",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: nil,
                settings: .defaultValue
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: MultiAccountAuthRepository(
                extractedByAccountID: [
                    "account-1": ExtractedAuth(
                        accountID: "account-1",
                        accessToken: "token-1",
                        email: "first@example.com",
                        planType: "pro",
                        teamName: nil
                    ),
                    "account-2": ExtractedAuth(
                        accountID: "account-2",
                        accessToken: "token-2",
                        email: "second@example.com",
                        planType: "pro",
                        teamName: nil
                    )
                ],
                currentAccountID: "account-1"
            ),
            usageService: AccountIDUsageService(
                results: [
                    "account-1": UsageSnapshot(
                        fetchedAt: now,
                        planType: "pro",
                        fiveHour: UsageWindow(usedPercent: 20, windowSeconds: 18_000, resetAt: nil),
                        oneWeek: nil,
                        credits: nil
                    ),
                    "account-2": UsageSnapshot(
                        fetchedAt: now,
                        planType: "pro",
                        fiveHour: UsageWindow(usedPercent: 80, windowSeconds: 18_000, resetAt: nil),
                        oneWeek: nil,
                        credits: nil
                    )
                ]
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        _ = try await coordinator.refreshAllUsage(force: true)

        XCTAssertEqual(storeRepository.saveCount, 1)
    }

    @MainActor
    func testAccountsPageModelBootstrapsFromInitialAccounts() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Bootstrap",
            email: "bootstrap@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            addedAt: 1,
            updatedAt: 1,
            usage: nil,
            usageError: nil,
            isCurrent: true
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            onLocalAccountsChanged: nil,
            initialAccounts: [account]
        )

        XCTAssertTrue(model.hasResolvedInitialState)
        XCTAssertEqual(model.state, AccountsPageModel.makeViewState(accounts: [account]))
    }

    @MainActor
    func testAccountsPageModelBootstrapsCollapsedOverviewFromInitialPreference() {
        let account = AccountSummary(
            id: "acct-1",
            label: "Bootstrap",
            email: "bootstrap@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            addedAt: 1,
            updatedAt: 1,
            usage: nil,
            usageError: nil,
            isCurrent: true
        )
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            onLocalAccountsChanged: nil,
            initialAccounts: [account],
            initialOverviewCollapsed: true
        )

        XCTAssertTrue(model.isAccountCollapsed(account.id))
        XCTAssertTrue(model.areAllAccountsCollapsed)
    }

    func testAccountsOverviewCollapsedPersistsToStore() async throws {
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )

        let initialOverviewCollapsed = try await coordinator.accountsOverviewCollapsed()
        XCTAssertFalse(initialOverviewCollapsed)

        try await coordinator.setAccountsOverviewCollapsed(true)

        XCTAssertTrue(try storeRepository.loadStore().accountsOverviewCollapsed)
        let persistedOverviewCollapsed = try await coordinator.accountsOverviewCollapsed()
        XCTAssertTrue(persistedOverviewCollapsed)
    }

    @MainActor
    func testAccountsPageModelRemoteRefreshActivityDoesNotDriveToolbarSpinner() {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )
        let model = AccountsPageModel(
            coordinator: coordinator,
            manualRefreshService: StubAccountsManualRefreshService()
        )

        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)

        model.syncRemoteUsageRefreshActivity(isRefreshing: true)
        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)

        model.syncRemoteUsageRefreshActivity(isRefreshing: false)
        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)
    }

    @MainActor
    func testAccountsPageModelManualRefreshShowsSpinnerAndRestoresActionState() async {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )

        let started = expectation(description: "manual refresh started")
        let gate = ManualRefreshGate()
        let callCounter = ManualRefreshCallCounter()
        let model = AccountsPageModel(
            coordinator: coordinator,
            manualRefreshService: BlockingAccountsManualRefreshService(
                gate: gate,
                callCounter: callCounter,
                onStart: { started.fulfill() }
            )
        )

        let refreshTask = Task { await model.refreshUsage() }
        await fulfillment(of: [started], timeout: 1.0)

        XCTAssertTrue(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)

        // Toolbar button stays tappable while a refresh is in progress,
        // but refresh action is guarded against concurrent re-entry.
        await model.refreshUsage()
        let callCountDuringRefresh = await callCounter.value
        XCTAssertEqual(callCountDuringRefresh, 1)

        await gate.open()
        _ = await refreshTask.result

        XCTAssertFalse(model.isRefreshSpinnerActive)
        XCTAssertTrue(model.canRefreshUsageAction)
    }

    @MainActor
    func testTrayMenuRefreshNowReusesPulledAccountsWithoutSecondListPass() async {
        let now: Int64 = 1_763_216_000
        let authRepository = CountingMultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": ExtractedAuth(
                    accountID: "account-1",
                    accessToken: "token-1",
                    email: "tray@example.com",
                    planType: "pro",
                    teamName: nil
                )
            ],
            currentAccountID: "account-1"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Tray",
                        email: "tray@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["account_id": .string("account-1")]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                settings: .defaultValue
            )
        )
        let accountsCoordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = TrayMenuModel(
            accountsCoordinator: accountsCoordinator,
            settingsCoordinator: SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: StubAccountsCloudSyncService(
                pullResult: AccountsCloudSyncPullResult(
                    didUpdateAccounts: true,
                    remoteSyncedAt: now
                )
            ),
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .seconds(1),
                cloudReconciliationInterval: .seconds(1),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .disabled,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now)
        )

        await model.refreshNow(forceUsageRefresh: false)

        XCTAssertEqual(authRepository.extractCallCount, 1)
    }

    @MainActor
    func testTrayMenuRefreshNowReusesUsageRefreshResultWithoutSecondListPass() async {
        let now: Int64 = 1_763_216_000
        let authRepository = CountingMultiAccountAuthRepository(
            extractedByAccountID: [
                "account-1": ExtractedAuth(
                    accountID: "account-1",
                    accessToken: "token-1",
                    email: "tray@example.com",
                    planType: "pro",
                    teamName: nil
                )
            ],
            currentAccountID: "account-1"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Tray",
                        email: "tray@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["account_id": .string("account-1")]),
                        addedAt: now,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    )
                ],
                settings: .defaultValue
            )
        )
        let accountsCoordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: nil),
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )
        let model = TrayMenuModel(
            accountsCoordinator: accountsCoordinator,
            settingsCoordinator: SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            cloudSyncService: nil,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .seconds(1),
                cloudReconciliationInterval: .seconds(1),
                usageRefreshInterval: .seconds(30),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .disabled,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now)
        )

        await model.refreshNow(forceUsageRefresh: true)

        XCTAssertEqual(authRepository.extractCallCount, 1)
    }

    @MainActor
    func testTrayMenuConfigFileMonitorForcesUsageRefresh() async {
        let now: Int64 = 1_763_216_000
        let usageService = CountingUsageService(
            result: UsageSnapshot(
                fetchedAt: now,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 25, windowSeconds: 18_000, resetAt: nil),
                oneWeek: nil,
                credits: nil
            )
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Tray",
                        email: "tray@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["account_id": .string("account-1")]),
                        addedAt: now,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    )
                ],
                settings: .defaultValue
            )
        )
        let configMonitor = TestLocalFileMonitorService()
        let model = TrayMenuModel(
            accountsCoordinator: AccountsCoordinator(
                storeRepository: storeRepository,
                authRepository: StubAuthRepository(),
                usageService: usageService,
                chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
                dateProvider: FixedDateProvider(now: now)
            ),
            settingsCoordinator: SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: StubLaunchAtStartupService()
            ),
            localAuthFileMonitor: nil,
            localConfigFileMonitor: configMonitor,
            cloudSyncService: nil,
            currentAccountSelectionSyncService: nil,
            backgroundRefreshPolicy: .init(
                initialRefreshDelay: .seconds(3_600),
                cloudReconciliationInterval: .seconds(3_600),
                usageRefreshInterval: .seconds(3_600),
                refreshUsageOnRecurringTick: false,
                cloudSyncMode: .disabled,
                applyRemoteSelectionSwitchEffects: false
            ),
            dateProvider: FixedDateProvider(now: now)
        )
        defer { model.stopBackgroundRefresh() }

        model.startBackgroundRefresh()
        XCTAssertEqual(configMonitor.startCallCount, 1)
        XCTAssertEqual(usageService.callCount, 0)

        configMonitor.triggerChange()

        for _ in 0..<20 where usageService.callCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(usageService.callCount, 1)
        XCTAssertEqual(model.accounts.first?.usage?.fiveHour?.usedPercent, 25)
    }

    @MainActor
    func testAccountsPageModelLocalMutationTriggersImmediateCloudSync() async {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: "workspace-x",
                        teamAlias: nil,
                        authJSON: .object([:]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )
        let syncSpy = SpyAccountsLocalMutationSyncService()
        let model = AccountsPageModel(
            coordinator: coordinator,
            localAccountsMutationSyncService: syncSpy,
            onLocalAccountsChanged: { accounts in
                syncSpy.acceptLocalAccountsSnapshot(accounts)
            }
        )

        await model.saveTeamAlias(id: "acct-1", alias: "Renamed")

        for _ in 0..<10 where syncSpy.syncCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(syncSpy.syncCallCount, 1)
        XCTAssertEqual(syncSpy.acceptedSnapshots.last?.first?.teamAlias, "Renamed")
    }

    func testAccountConfigurationDraftUsesPrettyPrintedAuthJSON() async throws {
        let now: Int64 = 1_763_216_000
        let authJSON = JSONValue.object([
            "OPENAI_API_KEY": .null,
            "auth_mode": .string("chatgpt"),
            "last_refresh": .string("2026-03-20T03:28:39.748160Z"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "account_id": .string("account-1"),
                "id_token": .string("id-token"),
                "refresh_token": .string("refresh-token")
            ])
        ])
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: "workspace-x",
                        teamAlias: "Studio",
                        authJSON: authJSON,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-1",
                    selectedAt: 1,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let draft = try await coordinator.accountConfigurationDraft(id: "acct-1")

        XCTAssertEqual(draft.label, "Primary")
        XCTAssertEqual(draft.teamAlias, "Studio")
        XCTAssertTrue(draft.setAsCurrent)
        XCTAssertTrue(draft.authJSONString.contains("\"OPENAI_API_KEY\""))
        XCTAssertTrue(draft.authJSONString.contains("\"account_id\""))
        XCTAssertTrue(draft.authJSONString.contains("\"refresh_token\""))
    }

    func testAccountConfigurationDraftFallsBackToTeamNameWhenAliasMissing() async throws {
        let now: Int64 = 1_763_216_000
        let authJSON = JSONValue.object([
            "OPENAI_API_KEY": .null,
            "tokens": .object([
                "access_token": .string("access-token"),
                "account_id": .string("account-1")
            ])
        ])
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-x",
                        teamAlias: nil,
                        authJSON: authJSON,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let draft = try await coordinator.accountConfigurationDraft(id: "acct-1")

        XCTAssertEqual(draft.teamAlias, "workspace-x")
    }

    func testSaveAccountConfigurationPersistsEditedAuthJSON() async throws {
        let now: Int64 = 1_763_216_000
        let originalAuth = JSONValue.object([
            "OPENAI_API_KEY": .null,
            "auth_mode": .string("chatgpt"),
            "last_refresh": .string("2026-03-20T03:28:39.748160Z"),
            "tokens": .object([
                "access_token": .string("old-access"),
                "account_id": .string("account-1"),
                "id_token": .string("old-id"),
                "refresh_token": .string("old-refresh")
            ])
        ])
        let editedAuthString = """
        {
          "OPENAI_API_KEY": null,
          "auth_mode": "chatgpt",
          "last_refresh": "2026-03-20T06:00:00.000000Z",
          "tokens": {
            "access_token": "new-access",
            "account_id": "account-2",
            "id_token": "new-id",
            "refresh_token": "new-refresh"
          }
        }
        """
        let expectedAuthJSON = try JSONValue.authJSONObject(from: editedAuthString)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: "workspace-x",
                        teamAlias: nil,
                        authJSON: originalAuth,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-1",
                    selectedAt: 1,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = JSONEchoAuthRepository(currentAccountID: "account-1")
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let saved = try await coordinator.saveAccountConfiguration(
            AccountConfigurationDraft(
                storedAccountID: "acct-1",
                label: "Edited",
                teamAlias: "Studio",
                setAsCurrent: true,
                authJSONString: editedAuthString
            )
        )
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(saved.accountID, "account-2")
        XCTAssertEqual(saved.label, "Edited")
        XCTAssertEqual(saved.displayTeamName, "Studio")
        XCTAssertEqual(savedStore.accounts.first?.authJSON, expectedAuthJSON)
        XCTAssertEqual(savedStore.accounts.first?.teamAlias, "Studio")
        XCTAssertEqual(savedStore.currentSelection?.accountID, "account-2")
        XCTAssertEqual(authRepository.writtenAuth, expectedAuthJSON)
    }

    func testSwitchAccountBackfillsLiveAuthIntoCurrentStoredAccount() async throws {
        let now: Int64 = 1_763_216_000
        let staleCurrentAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("stale-access"),
                "account_id": .string("account-1"),
                "id_token": .string("stale-id"),
                "refresh_token": .string("stale-refresh")
            ])
        ])
        let liveCurrentAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("live-access"),
                "account_id": .string("account-1"),
                "id_token": .string("live-id"),
                "refresh_token": .string("live-refresh")
            ])
        ])
        let targetAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("target-access"),
                "account_id": .string("account-2"),
                "id_token": .string("target-id"),
                "refresh_token": .string("target-refresh")
            ])
        ])
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Current",
                        email: "current@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: staleCurrentAuth,
                        addedAt: now - 100,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Target",
                        email: "target@example.com",
                        accountID: "account-2",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: targetAuth,
                        addedAt: now - 100,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-1",
                    selectedAt: 1,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = JSONEchoAuthRepository(
            currentAccountID: "account-1",
            currentAuth: liveCurrentAuth
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        try await coordinator.switchAccountAndApplySettings(id: "acct-2")
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(savedStore.accounts.first(where: { $0.id == "acct-1" })?.authJSON, liveCurrentAuth)
        XCTAssertEqual(savedStore.accounts.first(where: { $0.id == "acct-1" })?.updatedAt, now)
        XCTAssertEqual(savedStore.currentSelection?.accountID, "account-2")
        XCTAssertEqual(authRepository.writtenAuth, targetAuth)
    }

    func testSaveAccountConfigurationSetAsCurrentPreservesEditedTargetAuthWhenLiveAuthExists() async throws {
        let now: Int64 = 1_763_216_000
        let originalAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("old-access"),
                "account_id": .string("account-1"),
                "id_token": .string("old-id"),
                "refresh_token": .string("old-refresh")
            ])
        ])
        let liveCurrentAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("live-access"),
                "account_id": .string("account-1"),
                "id_token": .string("live-id"),
                "refresh_token": .string("live-refresh")
            ])
        ])
        let editedAuthString = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "new-access",
            "account_id": "account-2",
            "id_token": "new-id",
            "refresh_token": "new-refresh"
          }
        }
        """
        let expectedAuthJSON = try JSONValue.authJSONObject(from: editedAuthString)
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: "workspace-x",
                        teamAlias: nil,
                        authJSON: originalAuth,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-1",
                    selectedAt: 1,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = JSONEchoAuthRepository(
            currentAccountID: "account-1",
            currentAuth: liveCurrentAuth
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let saved = try await coordinator.saveAccountConfiguration(
            AccountConfigurationDraft(
                storedAccountID: "acct-1",
                label: "Edited",
                teamAlias: "Studio",
                setAsCurrent: true,
                authJSONString: editedAuthString
            )
        )
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(saved.accountID, "account-2")
        XCTAssertEqual(savedStore.accounts.first?.authJSON, expectedAuthJSON)
        XCTAssertEqual(savedStore.currentSelection?.accountID, "account-2")
        XCTAssertEqual(authRepository.writtenAuth, expectedAuthJSON)
    }

    func testSyncCurrentAuthSnapshotFromDiskBackfillsLiveAuthAndUpdatesSelection() async throws {
        let now: Int64 = 1_763_216_000
        let accountOneAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("account-1-access"),
                "account_id": .string("account-1"),
                "id_token": .string("account-1-id"),
                "refresh_token": .string("account-1-refresh")
            ])
        ])
        let staleAccountTwoAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("stale-account-2-access"),
                "account_id": .string("account-2"),
                "id_token": .string("stale-account-2-id"),
                "refresh_token": .string("stale-account-2-refresh")
            ])
        ])
        let liveAccountTwoAuth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("live-account-2-access"),
                "account_id": .string("account-2"),
                "id_token": .string("live-account-2-id"),
                "refresh_token": .string("live-account-2-refresh")
            ])
        ])
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "First",
                        email: "first@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: accountOneAuth,
                        addedAt: now - 100,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    ),
                    StoredAccount(
                        id: "acct-2",
                        label: "Second",
                        email: "second@example.com",
                        accountID: "account-2",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: staleAccountTwoAuth,
                        addedAt: now - 100,
                        updatedAt: now - 100,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-1",
                    selectedAt: 1,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = JSONEchoAuthRepository(
            currentAccountID: "account-1",
            currentAuth: liveAccountTwoAuth
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.syncCurrentAuthSnapshotFromDisk()
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(savedStore.accounts.first(where: { $0.id == "acct-2" })?.authJSON, liveAccountTwoAuth)
        XCTAssertEqual(savedStore.currentSelection?.accountID, "account-2")
        XCTAssertEqual(accounts.first(where: { $0.id == "acct-2" })?.isCurrent, true)
        XCTAssertEqual(accounts.first(where: { $0.id == "acct-1" })?.isCurrent, false)
    }

    func testSyncCurrentAuthSnapshotFromDiskClearsCurrentSelectionWhenLiveAuthIsMissing() async throws {
        let now: Int64 = 1_763_216_000
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: JSONValue.object([
                            "auth_mode": .string("chatgpt"),
                            "tokens": .object([
                                "access_token": .string("access"),
                                "account_id": .string("account-1"),
                                "id_token": .string("id"),
                                "refresh_token": .string("refresh")
                            ])
                        ]),
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ],
                currentSelection: CurrentAccountSelection(
                    accountID: "account-1",
                    selectedAt: 1,
                    sourceDeviceID: "macos-local"
                )
            )
        )
        let authRepository = JSONEchoAuthRepository(currentAccountID: nil, currentAuth: nil)
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: authRepository,
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let accounts = try await coordinator.syncCurrentAuthSnapshotFromDisk()
        let savedStore = try storeRepository.loadStore()

        XCTAssertNil(savedStore.currentSelection)
        XCTAssertEqual(accounts.first?.isCurrent, false)
    }

    func testSaveAccountConfigurationAllowsClearingEditedTeamName() async throws {
        let now: Int64 = 1_763_216_000
        let authJSON = JSONValue.object([
            "OPENAI_API_KEY": .null,
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "account_id": .string("account-1")
            ])
        ])
        let authString = try authJSON.prettyPrintedJSONString()
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "primary@example.com",
                        accountID: "account-1",
                        planType: "team",
                        teamName: "workspace-x",
                        teamAlias: "Studio",
                        authJSON: authJSON,
                        addedAt: now,
                        updatedAt: now,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: JSONEchoAuthRepository(currentAccountID: nil),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "team",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let saved = try await coordinator.saveAccountConfiguration(
            AccountConfigurationDraft(
                storedAccountID: "acct-1",
                label: "Primary",
                teamAlias: "   ",
                authJSONString: authString
            )
        )
        let savedStore = try storeRepository.loadStore()

        XCTAssertNil(saved.teamAlias)
        XCTAssertEqual(saved.displayTeamName, saved.teamName)
        XCTAssertNil(savedStore.accounts.first?.teamAlias)
        XCTAssertEqual(savedStore.accounts.first?.teamName, saved.teamName)
    }

    func testSaveAccountConfigurationRejectsNonObjectJSON() async {
        let coordinator = AccountsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            authRepository: StubAuthRepository(),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: 1,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
        )

        do {
            _ = try await coordinator.saveAccountConfiguration(
                AccountConfigurationDraft(
                    authJSONString: """
                    [
                      "invalid"
                    ]
                    """
                )
            )
            XCTFail("Expected saveAccountConfiguration to reject non-object JSON")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("JSON 对象"))
        }
    }

    func testSaveAccountConfigurationCreatesNewCustomImportWhenAccountIDIsUnique() async throws {
        let now: Int64 = 1_763_216_000
        let existing = StoredAccount(
            id: "acct-1",
            label: "Existing",
            email: "json@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: "workspace-a",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(accounts: [existing])
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: JSONEchoAuthRepository(currentAccountID: nil),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let saved = try await coordinator.saveAccountConfiguration(
            AccountConfigurationDraft(
                label: "Custom Import",
                authJSONString: """
                {
                  "tokens": {
                    "access_token": "access-custom",
                    "account_id": "account-2"
                  }
                }
                """
            )
        )
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(saved.accountID, "account-2")
        XCTAssertEqual(savedStore.accounts.count, 2)
        XCTAssertEqual(savedStore.accounts.last?.label, "Custom Import")
        XCTAssertEqual(savedStore.accounts.last?.accountID, "account-2")
    }

    func testSaveAccountConfigurationRejectsCustomImportWhenAccountIDAlreadyExists() async {
        let now: Int64 = 1_763_216_000
        let existing = StoredAccount(
            id: "acct-1",
            label: "Existing",
            principalID: "json@example.com",
            email: "json@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: "workspace-a",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(accounts: [existing])
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: JSONEchoAuthRepository(currentAccountID: nil),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        do {
            _ = try await coordinator.saveAccountConfiguration(
                AccountConfigurationDraft(
                    label: "Duplicate Import",
                    authJSONString: """
                    {
                      "tokens": {
                        "access_token": "access-duplicate",
                        "account_id": "account-1"
                      }
                    }
                    """
                )
            )
            XCTFail("Expected duplicate custom import to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("编辑功能"))
        }
    }

    func testSaveAccountConfigurationAllowsCustomImportWhenSameAccountIDBelongsToDifferentPrincipal() async throws {
        let now: Int64 = 1_763_216_000
        let existing = StoredAccount(
            id: "acct-1",
            label: "Existing",
            principalID: "existing@example.com",
            email: "existing@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: "workspace-a",
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(accounts: [existing])
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: JSONEchoAuthRepository(currentAccountID: nil),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "pro",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let saved = try await coordinator.saveAccountConfiguration(
            AccountConfigurationDraft(
                label: "Different Principal",
                authJSONString: """
                {
                  "tokens": {
                    "access_token": "access-duplicate",
                    "account_id": "account-1"
                  }
                }
                """
            )
        )
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(saved.accountID, "account-1")
        XCTAssertEqual(savedStore.accounts.count, 2)
    }

    func testSaveAccountConfigurationCreatesSeparateVariantWhenPlanTypeDiffersForSameAccountKey() async throws {
        let now: Int64 = 1_763_216_000
        let existing = StoredAccount(
            id: "acct-1",
            label: "Existing Pro",
            principalID: "same@example.com",
            email: "same@example.com",
            accountID: "account-1",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: now,
            updatedAt: now,
            usage: nil,
            usageError: nil
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(accounts: [existing])
        )
        let coordinator = AccountsCoordinator(
            storeRepository: storeRepository,
            authRepository: PlanVariantAuthRepository(planType: "plus", email: "same@example.com"),
            usageService: CountingUsageService(
                result: UsageSnapshot(
                    fetchedAt: now,
                    planType: "plus",
                    fiveHour: nil,
                    oneWeek: nil,
                    credits: nil
                )
            ),
            chatGPTOAuthLoginService: StubChatGPTOAuthLoginService(),
            dateProvider: FixedDateProvider(now: now)
        )

        let saved = try await coordinator.saveAccountConfiguration(
            AccountConfigurationDraft(
                label: "Same User Plus",
                authJSONString: """
                {
                  "tokens": {
                    "access_token": "access-plus",
                    "account_id": "account-1"
                  }
                }
                """
            )
        )
        let savedStore = try storeRepository.loadStore()

        XCTAssertEqual(saved.accountID, "account-1")
        XCTAssertEqual(saved.planType, "plus")
        XCTAssertEqual(savedStore.accounts.count, 2)
        XCTAssertNotEqual(savedStore.accounts[0].variantKey, savedStore.accounts[1].variantKey)
    }
}

private final class InMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore
    private(set) var saveCount = 0

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
        saveCount += 1
    }
}

private final class CountingUsageService: UsageService, @unchecked Sendable {
    private(set) var callCount = 0
    private let result: UsageSnapshot

    init(result: UsageSnapshot) {
        self.result = result
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        _ = accountID
        callCount += 1
        return result
    }
}

private final class AccountIDUsageService: UsageService, @unchecked Sendable {
    private let results: [String: UsageSnapshot]

    init(results: [String: UsageSnapshot]) {
        self.results = results
    }

    func fetchUsage(accessToken: String, accountID: String) async throws -> UsageSnapshot {
        _ = accessToken
        guard let result = results[accountID] else {
            throw AppError.invalidData("Missing usage snapshot for \(accountID)")
        }
        return result
    }
}

private struct FixedDateProvider: DateProviding {
    let now: Int64

    func unixSecondsNow() -> Int64 {
        now
    }
}

private final class StubWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private let metadata: [WorkspaceMetadata]

    init(metadata: [WorkspaceMetadata]) {
        self.metadata = metadata
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        _ = accessToken
        return metadata
    }
}

private final class RecordingWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private(set) var callCount = 0
    private let metadata: [WorkspaceMetadata]

    init(metadata: [WorkspaceMetadata]) {
        self.metadata = metadata
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        _ = accessToken
        callCount += 1
        return metadata
    }
}

private final class StubAccountsManualRefreshService: AccountsManualRefreshServiceProtocol, @unchecked Sendable {
    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary] {
        _ = onPartialUpdate
        return []
    }
}

@MainActor
private final class SpyAccountsLocalMutationSyncService: AccountsLocalMutationSyncServiceProtocol {
    private(set) var acceptedSnapshots: [[AccountSummary]] = []
    private(set) var syncCallCount = 0

    func acceptLocalAccountsSnapshot(_ accounts: [AccountSummary]) {
        acceptedSnapshots.append(accounts)
    }

    func syncLocalAccountsMutationNow() async {
        syncCallCount += 1
    }
}

private actor ManualRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ManualRefreshCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct StubLaunchAtStartupService: LaunchAtStartupServiceProtocol {
    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        _ = enabled
    }
}

private final class StubAccountsCloudSyncService: AccountsCloudSyncServiceProtocol, @unchecked Sendable {
    private let pullResult: AccountsCloudSyncPullResult

    init(pullResult: AccountsCloudSyncPullResult) {
        self.pullResult = pullResult
    }

    func pushLocalAccountsIfNeeded() async throws {}

    func pullRemoteAccountsIfNeeded(
        currentTime: Int64,
        maximumSnapshotAgeSeconds: Int64
    ) async throws -> AccountsCloudSyncPullResult {
        _ = currentTime
        _ = maximumSnapshotAgeSeconds
        return pullResult
    }

    func ensurePushSubscriptionIfNeeded() async throws {}
}

private final class TestLocalFileMonitorService: LocalFileMonitorServiceProtocol, @unchecked Sendable {
    private var onChange: (@Sendable () -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        startCallCount += 1
    }

    func stop() {
        onChange = nil
        stopCallCount += 1
    }

    func triggerChange() {
        onChange?()
    }
}

private final class BlockingAccountsManualRefreshService: AccountsManualRefreshServiceProtocol, @unchecked Sendable {
    private let gate: ManualRefreshGate
    private let callCounter: ManualRefreshCallCounter
    private let onStart: @Sendable () -> Void

    init(
        gate: ManualRefreshGate,
        callCounter: ManualRefreshCallCounter,
        onStart: @escaping @Sendable () -> Void
    ) {
        self.gate = gate
        self.callCounter = callCounter
        self.onStart = onStart
    }

    func performManualRefresh(
        onPartialUpdate: @escaping @MainActor ([AccountSummary]) -> Void
    ) async throws -> [AccountSummary] {
        _ = onPartialUpdate
        await callCounter.increment()
        onStart()
        await gate.wait()
        return []
    }
}

private final class StubAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: "pro",
            teamName: "workspace-x"
        )
    }
    func currentAuthAccountID() -> String? { "account-1" }
}

private final class RemoteLookupAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .object([:]) }
    func readCurrentAuthOptional() throws -> JSONValue? { .object([:]) }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .object([:])
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .object([:])
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: "team",
            teamName: nil
        )
    }
    func currentAuthAccountID() -> String? { "account-1" }
}

private final class LoginRemoteLookupAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .object([:]) }
    func readCurrentAuthOptional() throws -> JSONValue? { .object([:]) }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .object([:])
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .object([:])
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: nil,
            teamName: nil
        )
    }
    func currentAuthAccountID() -> String? { "account-1" }
}

private final class RecordingAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var writtenAccountCount = 0
    private let currentAccountIDValue: String?

    init(currentAccountID: String?) {
        self.currentAccountIDValue = currentAccountID
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
        writtenAccountCount += 1
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        return ExtractedAuth(
            accountID: "account-1",
            accessToken: "token-1",
            email: "test@example.com",
            planType: "pro",
            teamName: "workspace-x"
        )
    }
    func currentAuthAccountID() -> String? { currentAccountIDValue }
}

private final class JSONEchoAuthRepository: AuthRepository, @unchecked Sendable {
    private(set) var writtenAuth: JSONValue?
    private let currentAccountIDValue: String?
    private var currentAuth: JSONValue?

    init(currentAccountID: String?, currentAuth: JSONValue? = nil) {
        self.currentAccountIDValue = currentAccountID
        self.currentAuth = currentAuth
    }

    func readCurrentAuth() throws -> JSONValue { currentAuth ?? .null }
    func readCurrentAuthOptional() throws -> JSONValue? { currentAuth }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        writtenAuth = auth
        currentAuth = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let tokens = auth["tokens"]?.objectValue,
              let accountID = tokens["account_id"]?.stringValue,
              let accessToken = tokens["access_token"]?.stringValue else {
            throw AppError.invalidData("Missing token payload for test auth")
        }

        return ExtractedAuth(
            accountID: accountID,
            accessToken: accessToken,
            email: "json@example.com",
            planType: "pro",
            teamName: "workspace-json"
        )
    }
    func currentAuthAccountID() -> String? { currentAccountIDValue }
}

private final class MultiAccountAuthRepository: AuthRepository, @unchecked Sendable {
    private let extractedByAccountID: [String: ExtractedAuth]
    private let currentAccountIDValue: String?

    init(extractedByAccountID: [String: ExtractedAuth], currentAccountID: String?) {
        self.extractedByAccountID = extractedByAccountID
        self.currentAccountIDValue = currentAccountID
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"],
              let extracted = extractedByAccountID[accountID] else {
            throw AppError.invalidData("Missing extracted auth for test payload")
        }
        return extracted
    }
    func currentAuthAccountID() -> String? { currentAccountIDValue }
}

private final class CountingMultiAccountAuthRepository: AuthRepository, @unchecked Sendable {
    private let extractedByAccountID: [String: ExtractedAuth]
    private let currentAccountIDValue: String?
    private(set) var extractCallCount = 0

    init(extractedByAccountID: [String: ExtractedAuth], currentAccountID: String?) {
        self.extractedByAccountID = extractedByAccountID
        self.currentAccountIDValue = currentAccountID
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        extractCallCount += 1
        guard case .object(let payload) = auth,
              case .string(let accountID)? = payload["account_id"],
              let extracted = extractedByAccountID[accountID] else {
            throw AppError.invalidData("Missing extracted auth for test payload")
        }
        return extracted
    }
    func currentAuthAccountID() -> String? { currentAccountIDValue }
}

private final class PlanVariantAuthRepository: AuthRepository, @unchecked Sendable {
    private let planTypeValue: String
    private let emailValue: String

    init(planType: String, email: String) {
        self.planTypeValue = planType
        self.emailValue = email
    }

    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {
        _ = auth
    }
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        guard let tokens = auth["tokens"]?.objectValue,
              let accountID = tokens["account_id"]?.stringValue,
              let accessToken = tokens["access_token"]?.stringValue else {
            throw AppError.invalidData("Missing token payload for test auth")
        }

        return ExtractedAuth(
            principalID: emailValue,
            accountID: accountID,
            accessToken: accessToken,
            email: emailValue,
            planType: planTypeValue,
            teamName: nil
        )
    }
    func currentAuthAccountID() -> String? { nil }
}

private actor PartialUpdateRecorder {
    private var snapshots: [[AccountSummary]] = []

    func record(_ accounts: [AccountSummary]) {
        snapshots.append(accounts)
    }

    func values() -> [[AccountSummary]] {
        snapshots
    }
}

private final class StubChatGPTOAuthLoginService: ChatGPTOAuthLoginServiceProtocol, @unchecked Sendable {
    func signInWithChatGPT(timeoutSeconds: TimeInterval) async throws -> ChatGPTOAuthTokens {
        _ = timeoutSeconds
        return ChatGPTOAuthTokens(accessToken: "", refreshToken: "", idToken: "", apiKey: nil)
    }
}
