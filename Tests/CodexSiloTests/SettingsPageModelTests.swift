import XCTest
@testable import CodexSilo

@MainActor
final class SettingsPageModelTests: XCTestCase {
    func testLoadIfNeededLoadsSettingsAndLogs() async {
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
        let appLogger = SettingsTestAppLogger(
            entries: [
                AppLogEntry(
                    id: "entry-1",
                    timestamp: Date(timeIntervalSince1970: 1_763_216_300),
                    level: .warning,
                    scope: "accounts.refresh_failed",
                    message: "Refresh failed.",
                    metadataSummary: "reason=timeout",
                    rawLine: "raw"
                )
            ]
        )
        let model = makeModel(storeRepository: repository, appLogger: appLogger)

        await model.loadIfNeeded()

        XCTAssertTrue(model.settings.launchAtStartup)
        XCTAssertEqual(model.liveTestLogs.count, 1)
        XCTAssertEqual(model.liveTestLogs.first?.message, "HTTP 400: invalid request")
        XCTAssertEqual(model.appLogs.count, 1)
        XCTAssertEqual(model.appLogs.first?.scope, "accounts.refresh_failed")
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

    func testClearAppLogsClearsLoggerBackedEntries() async throws {
        let repository = SettingsInMemoryAccountsStoreRepository(store: AccountsStore())
        let appLogger = SettingsTestAppLogger(
            entries: [
                AppLogEntry(
                    id: "entry-1",
                    timestamp: Date(),
                    level: .info,
                    scope: "app.bootstrap_succeeded",
                    message: "Bootstrap completed.",
                    metadataSummary: nil,
                    rawLine: "raw"
                )
            ]
        )
        let model = makeModel(storeRepository: repository, appLogger: appLogger)

        await model.loadIfNeeded()
        XCTAssertEqual(model.appLogs.count, 1)

        await model.clearAppLogs()

        XCTAssertTrue(model.appLogs.isEmpty)
        let remainingEntries = try await appLogger.loadEntries(limit: 10)
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertFalse(appLogger.loggedEvents.contains("clear_file_logs_succeeded"))
    }

    private func makeModel(
        storeRepository: SettingsInMemoryAccountsStoreRepository,
        appLogger: AppLogger = NoopAppLogger.shared
    ) -> SettingsPageModel {
        SettingsPageModel(
            settingsCoordinator: SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: SettingsSpyLaunchAtStartupService()
            ),
            appLogger: appLogger
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

private final class SettingsTestAppLogger: AppLogger, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SettingsTestAppLogger")
    private var entries: [AppLogEntry]
    private var events: [(level: LogLevel, category: LogCategory, event: String, message: String)] = []
    private let directoryURL: URL

    init(
        entries: [AppLogEntry] = [],
        directoryURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) {
        self.entries = entries
        self.directoryURL = directoryURL
    }

    func log(
        _ level: LogLevel,
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String],
        operationID: String?
    ) {
        _ = metadata
        _ = operationID
        queue.sync {
            events.append((level: level, category: category, event: event, message: message))
        }
    }

    func loadEntries(limit: Int) async throws -> [AppLogEntry] {
        queue.sync {
            Array(entries.prefix(limit))
        }
    }

    func loadCombinedText(limit: Int) async throws -> String {
        queue.sync {
            entries.prefix(limit).map(\.rawLine).joined(separator: "\n")
        }
    }

    func clearLogs() async throws {
        queue.sync {
            entries = []
        }
    }

    func logsDirectoryURL() -> URL {
        directoryURL
    }

    var loggedEvents: [String] {
        queue.sync {
            events.map(\.event)
        }
    }
}
