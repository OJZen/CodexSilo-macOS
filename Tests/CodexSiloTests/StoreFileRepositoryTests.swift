import XCTest
@testable import CodexSilo

final class StoreFileRepositoryTests: XCTestCase {
    func testAccountsDataTransferCodecRoundTripsStoreArchive() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("accounts.\(AccountsDataTransferCodec.archiveFileExtension)")
        let store = makeSampleStore(launchAtStartup: true)
        let codec = AccountsDataTransferCodec(
            dateProvider: FixedDateProvider(unixSeconds: 1_717_171_717),
            configuration: .init(
                pbkdf2Iterations: 8,
                keyLength: 32,
                saltLength: 16
            )
        )

        try codec.export(store: store, to: archiveURL, password: "correct-horse-battery-staple")
        let importedStore = try codec.importStore(from: archiveURL, password: "correct-horse-battery-staple")

        XCTAssertEqual(importedStore, store)
    }

    func testAccountsDataTransferCodecRejectsWrongPassword() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("accounts.\(AccountsDataTransferCodec.archiveFileExtension)")
        let codec = AccountsDataTransferCodec(
            dateProvider: FixedDateProvider(unixSeconds: 1_717_171_717),
            configuration: .init(
                pbkdf2Iterations: 8,
                keyLength: 32,
                saltLength: 16
            )
        )

        try codec.export(store: makeSampleStore(), to: archiveURL, password: "secret-passphrase")

        XCTAssertThrowsError(
            try codec.importStore(from: archiveURL, password: "wrong-passphrase")
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                L10n.tr("error.transfer.decrypt_failed")
            )
        }
    }

    func testSettingsCoordinatorImportPersistsStoreAndSyncsLaunchAtStartup() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("accounts.\(AccountsDataTransferCodec.archiveFileExtension)")
        let importedStore = makeSampleStore(launchAtStartup: true)
        let repository = TestInMemoryAccountsStoreRepository(store: makeSampleStore(launchAtStartup: false))
        let authRepository = SpyAuthRepository()
        let launchAtStartupService = SpyLaunchAtStartupService()
        let codec = AccountsDataTransferCodec(
            dateProvider: FixedDateProvider(unixSeconds: 1_717_171_717),
            configuration: .init(
                pbkdf2Iterations: 8,
                keyLength: 32,
                saltLength: 16
            )
        )
        try codec.export(store: importedStore, to: archiveURL, password: "sync-me")

        let coordinator = SettingsCoordinator(
            storeRepository: repository,
            authRepository: authRepository,
            launchAtStartupService: launchAtStartupService,
            dataTransferCodec: codec
        )

        let restoredStore = try await coordinator.importAccountData(from: archiveURL, password: "sync-me")

        XCTAssertEqual(restoredStore, importedStore)
        XCTAssertEqual(try repository.loadStore(), importedStore)
        XCTAssertEqual(launchAtStartupService.readSyncedValues(), [true])
        XCTAssertEqual(authRepository.readWrittenAuth(), importedStore.accounts[0].authJSON)
    }

    func testExtractFirstJSONObjectDataCanRecoverTrailingGarbage() throws {
        let malformed = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}} trailing text".data(using: .utf8)!

        let recovered = StoreFileRepository.extractFirstJSONObjectData(from: malformed)

        XCTAssertNotNil(recovered)
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(AccountsStore.self, from: recovered!))
    }

    func testLoadStoreRecoversWhenTrailingGarbageExists() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let raw = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}}\nINVALID".data(using: .utf8)!
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()

        XCTAssertEqual(store.version, 1)
        XCTAssertEqual(store.accounts.count, 0)
    }

    func testLoadStoreDetectsExternalFileReplacement() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false)
        )

        let repository = StoreFileRepository(paths: paths)
        XCTAssertEqual(try repository.loadStore().accounts.count, 0)

        let updatedStore = AccountsStore(
            accounts: [
                StoredAccount(
                    id: "acct-1",
                    label: "External",
                    principalID: "user@example.com",
                    email: "user@example.com",
                    accountID: "external-account",
                    planType: "pro",
                    teamName: nil,
                    teamAlias: nil,
                    authJSON: .object([:]),
                    addedAt: 1,
                    updatedAt: 2,
                    usage: nil,
                    usageError: nil
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updatedStore).write(to: storePath, options: .atomic)

        let reloadedStore = try repository.loadStore()
        XCTAssertEqual(reloadedStore.accounts.map(\.label), ["External"])
    }

    func testAccountSummariesPreferStoredCurrentSelectionOverAuthFallback() {
        let account = StoredAccount(
            id: "acct-1",
            label: "Remote Selected",
            email: "remote@example.com",
            accountID: "remote-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let otherAccount = StoredAccount(
            id: "acct-2",
            label: "Local Auth",
            email: "local@example.com",
            accountID: "local-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [account, otherAccount],
            currentSelection: CurrentAccountSelection(
                accountID: "remote-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: .defaultValue
        )

        let summaries = store.accountSummaries(currentAccountID: "local-account")

        XCTAssertEqual(
            summaries.first(where: { $0.accountID == "remote-account" })?.isCurrent,
            true
        )
        XCTAssertEqual(
            summaries.first(where: { $0.accountID == "local-account" })?.isCurrent,
            false
        )
    }

    func testAccountSummariesPreferCurrentVariantKeyWhenSameAccountHasMultiplePlans() {
        let plusAccount = StoredAccount(
            id: "acct-plus",
            label: "Plus",
            principalID: "same@example.com",
            email: "same@example.com",
            accountID: "shared-account",
            planType: "plus",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let proAccount = StoredAccount(
            id: "acct-pro",
            label: "Pro",
            principalID: "same@example.com",
            email: "same@example.com",
            accountID: "shared-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [plusAccount, proAccount],
            currentSelection: CurrentAccountSelection(
                accountID: plusAccount.accountID,
                accountKey: plusAccount.accountKey,
                variantKey: plusAccount.variantKey,
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: .defaultValue
        )

        let summaries = store.accountSummaries(
            currentAccountKey: plusAccount.accountKey,
            currentVariantKey: plusAccount.variantKey
        )

        XCTAssertEqual(summaries.first(where: { $0.id == "acct-plus" })?.isCurrent, true)
        XCTAssertEqual(summaries.first(where: { $0.id == "acct-pro" })?.isCurrent, false)
    }

    func testAccountSummariesDeriveSelectionIdentityFromAuthJSONWhenPrincipalIDIsMissing() {
        let plusAccount = StoredAccount(
            id: "acct-plus",
            label: "Plus",
            principalID: nil,
            email: nil,
            accountID: "shared-account",
            planType: "plus",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object(["principal_id": .string("same@example.com")]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let proAccount = StoredAccount(
            id: "acct-pro",
            label: "Pro",
            principalID: nil,
            email: nil,
            accountID: "shared-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object(["principal_id": .string("same@example.com")]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [plusAccount, proAccount],
            currentSelection: CurrentAccountSelection(
                accountID: plusAccount.accountID,
                accountKey: plusAccount.accountKey,
                variantKey: plusAccount.variantKey,
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: .defaultValue
        )

        let summaries = store.accountSummaries(
            currentAccountKey: plusAccount.accountKey,
            currentVariantKey: plusAccount.variantKey
        )

        XCTAssertEqual(summaries.first(where: { $0.id == "acct-plus" })?.isCurrent, true)
        XCTAssertEqual(summaries.first(where: { $0.id == "acct-pro" })?.isCurrent, false)
    }

    private func makeSampleStore(launchAtStartup: Bool = true) -> AccountsStore {
        let selectedAccount = StoredAccount(
            id: "acct-1",
            label: "Primary",
            principalID: "primary@example.com",
            email: "primary@example.com",
            accountID: "acct-primary",
            planType: "pro",
            teamName: "Core Team",
            teamAlias: "Core",
            authJSON: .object([
                "OPENAI_API_KEY": .string("sk-live-primary"),
                "account_id": .string("acct-primary"),
                "principal_id": .string("primary@example.com")
            ]),
            addedAt: 100,
            updatedAt: 200,
            usage: nil,
            usageError: nil
        )
        let secondaryAccount = StoredAccount(
            id: "acct-2",
            label: "Secondary",
            principalID: "secondary@example.com",
            email: "secondary@example.com",
            accountID: "acct-secondary",
            planType: "plus",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "OPENAI_API_KEY": .string("sk-live-secondary"),
                "account_id": .string("acct-secondary"),
                "principal_id": .string("secondary@example.com")
            ]),
            addedAt: 300,
            updatedAt: 400,
            usage: nil,
            usageError: nil
        )

        return AccountsStore(
            version: 1,
            accounts: [selectedAccount, secondaryAccount],
            currentSelection: CurrentAccountSelection(
                accountID: selectedAccount.accountID,
                accountKey: selectedAccount.accountKey,
                variantKey: selectedAccount.variantKey,
                selectedAt: 777,
                sourceDeviceID: "device-a"
            ),
            accountsOverviewCollapsed: true,
            settings: AppSettings(
                launchAtStartup: launchAtStartup,
                autoRefreshAccounts: false,
                autoSmartSwitch: true,
                autoStartApiProxy: true,
                locale: "zh-Hans"
            )
        )
    }
}

private struct FixedDateProvider: DateProviding {
    let unixSeconds: Int64

    func unixSecondsNow() -> Int64 {
        unixSeconds
    }
}

private final class TestInMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    func saveStore(_ store: AccountsStore) throws {
        lock.lock()
        self.store = store
        lock.unlock()
    }
}

private final class SpyLaunchAtStartupService: LaunchAtStartupServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var syncedValues: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        lock.lock()
        syncedValues.append(enabled)
        lock.unlock()
    }

    func readSyncedValues() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return syncedValues
    }
}

private final class SpyAuthRepository: AuthRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var writtenAuth: JSONValue?

    func readCurrentAuth() throws -> JSONValue {
        throw AppError.fileNotFound("unused")
    }

    func readCurrentAuthOptional() throws -> JSONValue? {
        nil
    }

    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        throw AppError.fileNotFound("unused")
    }

    func writeCurrentAuth(_ auth: JSONValue) throws {
        lock.lock()
        writtenAuth = auth
        lock.unlock()
    }

    func removeCurrentAuth() throws {}

    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        throw AppError.invalidData("unused")
    }

    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        _ = auth
        throw AppError.invalidData("unused")
    }

    func currentAuthAccountID() -> String? {
        nil
    }

    func readWrittenAuth() -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return writtenAuth
    }
}
