import XCTest
@testable import CodexSilo

@MainActor
final class SettingsPageModelTests: XCTestCase {
    func testLoadIfNeededLoadsSettingsAndProxyLogs() async {
        let repository = SettingsInMemoryAccountsStoreRepository(
            store: AccountsStore(
                proxyLiveTestLogs: [
                    ProxyLiveTestLogEntry(
                        id: "log-1",
                        createdAt: 1_763_216_300,
                        model: "gpt-5.4",
                        status: .error,
                        message: "HTTP 400: invalid request"
                    )
                ],
                settings: AppSettings(
                    launchAtStartup: true,
                    autoRefreshAccounts: true,
                    autoSmartSwitch: false,
                    autoStartApiProxy: false,
                    locale: AppLocale.english.identifier
                )
            )
        )
        let model = makeModel(storeRepository: repository)

        await model.loadIfNeeded()

        XCTAssertTrue(model.settings.launchAtStartup)
        XCTAssertEqual(model.liveTestLogs.count, 1)
        XCTAssertEqual(model.liveTestLogs.first?.message, "HTTP 400: invalid request")
    }

    func testClearProxyLiveTestLogsRemovesPersistedHistory() async throws {
        let repository = SettingsInMemoryAccountsStoreRepository(
            store: AccountsStore(
                proxyLiveTestLogs: [
                    ProxyLiveTestLogEntry(
                        id: "log-1",
                        createdAt: 1_763_216_300,
                        model: "gpt-5.4",
                        status: .success,
                        message: "OK"
                    )
                ]
            )
        )
        let model = makeModel(storeRepository: repository)

        await model.loadIfNeeded()
        XCTAssertEqual(model.liveTestLogs.count, 1)

        await model.clearProxyLiveTestLogs()

        XCTAssertTrue(model.liveTestLogs.isEmpty)
        XCTAssertTrue(try repository.loadStore().proxyLiveTestLogs.isEmpty)
    }

    func testSetAllowLanProxyAccessUpdatesStoreAndPublishesRestartNotice() async throws {
        let repository = SettingsInMemoryAccountsStoreRepository(store: AccountsStore())
        let model = makeModel(storeRepository: repository)

        await model.loadIfNeeded()
        model.setAllowLanProxyAccess(true)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(model.settings.allowLanProxyAccess)
        XCTAssertEqual(
            model.notice?.text,
            L10n.tr("settings.notice.proxy_lan_access_updated")
        )
        XCTAssertTrue(try repository.loadStore().settings.allowLanProxyAccess)
    }

    private func makeModel(
        storeRepository: SettingsInMemoryAccountsStoreRepository
    ) -> SettingsPageModel {
        SettingsPageModel(
            settingsCoordinator: SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: SettingsSpyLaunchAtStartupService()
            )
        )
    }
}

private final class SettingsInMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
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

private final class SettingsSpyLaunchAtStartupService: LaunchAtStartupServiceProtocol, @unchecked Sendable {
    func setEnabled(_ enabled: Bool) throws {}
    func syncWithStoreValue(_ enabled: Bool) throws {}
}
