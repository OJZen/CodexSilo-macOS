import XCTest
@testable import CodexSilo

@MainActor
final class ProxyPageModelTests: XCTestCase {
    func testLoadIfNeededUsesStoredAutoStartSettingAndRefreshesStatus() async {
        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: 9001,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:9001",
                availableAccounts: 2,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(
            runtimeService: runtimeService,
            store: AccountsStore(
                settings: AppSettings(
                    launchAtStartup: false,
                    autoRefreshAccounts: true,
                    autoSmartSwitch: false,
                    autoStartApiProxy: true,
                    locale: AppLocale.english.identifier
                )
            ),
            dateProvider: FixedDateProvider(unixSeconds: 1_763_216_000)
        )

        await model.loadIfNeeded()

        XCTAssertTrue(model.autoStartProxy)
        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.preferredPortText, "9001")
        XCTAssertEqual(model.lastRefreshedAt, 1_763_216_000)
    }

    func testBootstrapStartsProxyWhenAutoStartEnabledAndProxyIsStopped() async {
        let runtimeService = StubProxyRuntimeService(
            statusResult: .idle,
            startResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787",
                availableAccounts: 1,
                activeAccountID: nil,
                activeAccountLabel: nil,
                lastError: nil
            )
        )
        let model = makeModel(
            runtimeService: runtimeService,
            dateProvider: FixedDateProvider(unixSeconds: 1_763_216_100)
        )

        await model.bootstrapOnAppLaunch(
            using: AppSettings(
                launchAtStartup: false,
                autoRefreshAccounts: true,
                autoSmartSwitch: false,
                autoStartApiProxy: true,
                locale: AppLocale.english.identifier
            )
        )

        XCTAssertEqual(runtimeService.startCalls, [nil])
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.preferredPortText, "8787")
    }

    func testStartProxyUsesPreferredPortAndPublishesSuccessNotice() async {
        let runtimeService = StubProxyRuntimeService(
            startResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787",
                availableAccounts: 3,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(runtimeService: runtimeService)
        model.preferredPortText = "8787"

        await model.startProxy()

        XCTAssertEqual(runtimeService.startCalls, [8787])
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(model.notice?.text, L10n.tr("proxy.notice.api_proxy_started"))
    }

    func testSetAutoStartProxyRevertsValueWhenSettingsUpdateFails() async {
        let model = makeModel(storeRepository: FailingAccountsStoreRepository())

        XCTAssertFalse(model.autoStartProxy)

        await model.setAutoStartProxy(true)

        XCTAssertFalse(model.autoStartProxy)
        XCTAssertEqual(model.notice?.style, .error)
    }

    private func makeModel(
        runtimeService: StubProxyRuntimeService = StubProxyRuntimeService(),
        store: AccountsStore = AccountsStore(),
        storeRepository: AccountsStoreRepository? = nil,
        launchAtStartupService: StubLaunchAtStartupService = StubLaunchAtStartupService(),
        dateProvider: DateProviding = FixedDateProvider(unixSeconds: 1_763_216_000)
    ) -> ProxyPageModel {
        let proxyCoordinator = ProxyCoordinator(proxyService: runtimeService)
        let settingsCoordinator = SettingsCoordinator(
            storeRepository: storeRepository ?? InMemoryAccountsStoreRepository(store: store),
            launchAtStartupService: launchAtStartupService
        )

        return ProxyPageModel(
            coordinator: proxyCoordinator,
            settingsCoordinator: settingsCoordinator,
            dateProvider: dateProvider
        )
    }
}

private struct FailingAccountsStoreRepository: AccountsStoreRepository {
    func loadStore() throws -> AccountsStore {
        AccountsStore()
    }

    func saveStore(_ store: AccountsStore) throws {
        _ = store
        throw AppError.io("boom")
    }
}

private final class InMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
    }
}

private struct FixedDateProvider: DateProviding {
    let unixSeconds: Int64

    func unixSecondsNow() -> Int64 {
        unixSeconds
    }
}

private struct StubLaunchAtStartupService: LaunchAtStartupServiceProtocol {
    var setEnabledError: Error? = nil

    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
        if let setEnabledError {
            throw setEnabledError
        }
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        _ = enabled
    }
}

private final class StubProxyRuntimeService: ProxyRuntimeService, @unchecked Sendable {
    var statusResult: ApiProxyStatus
    var startResult: ApiProxyStatus
    var stopResult: ApiProxyStatus
    var refreshAPIKeyResult: ApiProxyStatus
    private(set) var startCalls: [Int?] = []
    private(set) var syncAccountsStoreCallCount = 0

    init(
        statusResult: ApiProxyStatus = .idle,
        startResult: ApiProxyStatus = .idle,
        stopResult: ApiProxyStatus = .idle,
        refreshAPIKeyResult: ApiProxyStatus = .idle
    ) {
        self.statusResult = statusResult
        self.startResult = startResult
        self.stopResult = stopResult
        self.refreshAPIKeyResult = refreshAPIKeyResult
    }

    func status() async -> ApiProxyStatus {
        statusResult
    }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        startCalls.append(preferredPort)
        return startResult
    }

    func stop() async -> ApiProxyStatus {
        stopResult
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        refreshAPIKeyResult
    }

    func syncAccountsStore() async throws {
        syncAccountsStoreCallCount += 1
    }
}
