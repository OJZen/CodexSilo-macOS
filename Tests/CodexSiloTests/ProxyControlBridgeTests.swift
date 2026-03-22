import XCTest
@testable import CodexSilo

final class ProxyControlBridgeTests: XCTestCase {
    func testStartRunsBridgeLoopInCurrentBuild() async throws {
        let cloudSyncService = SpyProxyControlCloudSyncService()
        let bridge = makeBridge(
            cloudSyncService: cloudSyncService,
            runtimePlatform: .macOS
        )

        await bridge.start()
        try? await Task.sleep(for: .milliseconds(150))
        await bridge.stop()

        let metrics = await cloudSyncService.readMetrics()
        XCTAssertGreaterThanOrEqual(metrics.ensurePushSubscriptionCallCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.pushLocalSnapshotCallCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.pullPendingCommandCallCount, 1)
    }

    func testStartRunsBridgeLoopOnMacOS() async throws {
        let cloudSyncService = SpyProxyControlCloudSyncService()
        let bridge = makeBridge(
            cloudSyncService: cloudSyncService,
            runtimePlatform: .macOS
        )

        await bridge.start()
        try? await Task.sleep(for: .milliseconds(150))
        await bridge.stop()

        let metrics = await cloudSyncService.readMetrics()
        XCTAssertGreaterThanOrEqual(metrics.ensurePushSubscriptionCallCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.pullPendingCommandCallCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.pushLocalSnapshotCallCount, 1)
    }

    func testStartPublishesSnapshotWithoutWaitingForSlowRemoteStatuses() async throws {
        let cloudSyncService = SpyProxyControlCloudSyncService()
        let slowRemoteService = SlowRemoteProxyService(delay: .milliseconds(600))
        let bridge = makeBridge(
            cloudSyncService: cloudSyncService,
            runtimePlatform: .macOS,
            remoteService: slowRemoteService,
            store: AccountsStore(
                settings: AppSettings(
                    launchAtStartup: false,
                    launchCodexAfterSwitch: true,
                    autoRefreshAccounts: true,
                    autoSmartSwitch: false,
                    syncOpencodeOpenaiAuth: false,
                    restartEditorsOnSwitch: false,
                    restartEditorTargets: [],
                    autoStartApiProxy: false,
                    remoteServers: [makeRemoteServer()],
                    locale: AppLocale.systemDefault.identifier
                )
            )
        )

        await bridge.start()
        try? await Task.sleep(for: .milliseconds(150))

        let metrics = await cloudSyncService.readMetrics()
        XCTAssertGreaterThanOrEqual(metrics.pushLocalSnapshotCallCount, 1)

        await bridge.stop()
    }

    func testRemoteStatusRefreshPublishesUpdatedSnapshotInParallel() async throws {
        let cloudSyncService = SpyProxyControlCloudSyncService()
        let slowRemoteService = SlowRemoteProxyService(delay: .milliseconds(300))
        let bridge = makeBridge(
            cloudSyncService: cloudSyncService,
            runtimePlatform: .macOS,
            remoteService: slowRemoteService,
            store: AccountsStore(
                settings: AppSettings(
                    launchAtStartup: false,
                    launchCodexAfterSwitch: true,
                    autoRefreshAccounts: true,
                    autoSmartSwitch: false,
                    syncOpencodeOpenaiAuth: false,
                    restartEditorsOnSwitch: false,
                    restartEditorTargets: [],
                    autoStartApiProxy: false,
                    remoteServers: [
                        makeRemoteServer(id: "server-1", label: "Tokyo"),
                        makeRemoteServer(id: "server-2", label: "Seoul"),
                        makeRemoteServer(id: "server-3", label: "Paris"),
                    ],
                    locale: AppLocale.systemDefault.identifier
                )
            )
        )

        await bridge.start()
        try? await Task.sleep(for: .milliseconds(550))

        let metrics = await cloudSyncService.readMetrics()
        XCTAssertGreaterThanOrEqual(metrics.pushLocalSnapshotCallCount, 2)
        XCTAssertEqual(metrics.lastSnapshotRemoteStatusCount, 3)

        await bridge.stop()
    }

    func testPerformLocalCommandPushesSnapshotImmediately() async throws {
        let cloudSyncService = SpyProxyControlCloudSyncService()
        let bridge = makeBridge(
            cloudSyncService: cloudSyncService,
            runtimePlatform: .macOS
        )

        let command = ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: 1_763_216_000_000,
            sourceDeviceID: "macos-proxy-control",
            kind: .refreshStatus,
            preferredProxyPort: nil,
            autoStartProxy: nil,
            cloudflaredInput: nil,
            remoteServer: nil,
            remoteServerID: nil,
            logLines: nil
        )

        _ = try await bridge.performLocalCommand(command)

        let metrics = await cloudSyncService.readMetrics()
        XCTAssertEqual(metrics.pushLocalSnapshotCallCount, 1)
    }

    private func makeBridge(
        cloudSyncService: ProxyControlCloudSyncServiceProtocol?,
        runtimePlatform: RuntimePlatform,
        remoteService: RemoteProxyServiceProtocol = StubRemoteProxyService(),
        store: AccountsStore = AccountsStore()
    ) -> ProxyControlBridge {
        let proxyCoordinator = ProxyCoordinator(
            proxyService: StubProxyRuntimeService(),
            cloudflaredService: StubCloudflaredService(),
            remoteService: remoteService
        )
        let settingsCoordinator = SettingsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: store),
            launchAtStartupService: StubLaunchAtStartupService()
        )

        return ProxyControlBridge(
            proxyCoordinator: proxyCoordinator,
            settingsCoordinator: settingsCoordinator,
            cloudSyncService: cloudSyncService,
            runtimePlatform: runtimePlatform
        )
    }

    private func makeRemoteServer(
        id: String = "server-1",
        label: String = "Tokyo"
    ) -> RemoteServerConfig {
        RemoteServerConfig(
            id: id,
            label: label,
            host: "1.2.3.4",
            sshPort: 22,
            sshUser: "root",
            authMode: "keyPath",
            identityFile: "~/.ssh/id_ed25519",
            privateKey: nil,
            password: nil,
            remoteDir: "/opt/codex-tools",
            listenPort: 8787
        )
    }
}

private struct CloudSyncMetrics {
    var ensurePushSubscriptionCallCount: Int
    var pushLocalSnapshotCallCount: Int
    var pullPendingCommandCallCount: Int
    var lastSnapshotRemoteStatusCount: Int
}

private actor SpyProxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol {
    private var ensurePushSubscriptionCallCount = 0
    private var pushLocalSnapshotCallCount = 0
    private var pullPendingCommandCallCount = 0
    private var lastSnapshotRemoteStatusCount = 0

    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws {
        pushLocalSnapshotCallCount += 1
        lastSnapshotRemoteStatusCount = snapshot.remoteStatuses.count
    }

    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot? {
        nil
    }

    func enqueueCommand(_ command: ProxyControlCommand) async throws {
        _ = command
    }

    func pullPendingCommand() async throws -> ProxyControlCommand? {
        pullPendingCommandCallCount += 1
        return nil
    }

    func ensurePushSubscriptionIfNeeded() async throws {
        ensurePushSubscriptionCallCount += 1
    }

    func readMetrics() -> CloudSyncMetrics {
        CloudSyncMetrics(
            ensurePushSubscriptionCallCount: ensurePushSubscriptionCallCount,
            pushLocalSnapshotCallCount: pushLocalSnapshotCallCount,
            pullPendingCommandCallCount: pullPendingCommandCallCount,
            lastSnapshotRemoteStatusCount: lastSnapshotRemoteStatusCount
        )
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

private struct StubLaunchAtStartupService: LaunchAtStartupServiceProtocol {
    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        _ = enabled
    }
}

private struct StubProxyRuntimeService: ProxyRuntimeService {
    func status() async -> ApiProxyStatus { .idle }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        _ = preferredPort
        return .idle
    }

    func stop() async -> ApiProxyStatus { .idle }

    func refreshAPIKey() async throws -> ApiProxyStatus { .idle }

    func syncAccountsStore() async throws {}
}

private struct StubCloudflaredService: CloudflaredServiceProtocol {
    func status() async -> CloudflaredStatus { .idle }

    func install() async throws -> CloudflaredStatus { .idle }

    func start(_ input: StartCloudflaredTunnelInput) async throws -> CloudflaredStatus {
        _ = input
        return .idle
    }

    func stop() async -> CloudflaredStatus { .idle }
}

private struct StubRemoteProxyService: RemoteProxyServiceProtocol {
    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        _ = server
        return RemoteProxyStatus(
            installed: false,
            serviceInstalled: false,
            running: false,
            enabled: false,
            serviceName: "",
            pid: nil,
            baseURL: "",
            apiKey: nil,
            lastError: nil
        )
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        _ = server
        _ = lines
        return ""
    }
}

private final class SlowRemoteProxyService: RemoteProxyServiceProtocol, @unchecked Sendable {
    private let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        _ = server
        try? await Task.sleep(for: delay)
        return RemoteProxyStatus(
            installed: true,
            serviceInstalled: true,
            running: true,
            enabled: true,
            serviceName: "codex-tools-proxyd.service",
            pid: 42,
            baseURL: "http://1.2.3.4:8787/v1",
            apiKey: "key",
            lastError: nil
        )
    }

    func deploy(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func start(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func stop(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        await status(server: server)
    }

    func readLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        _ = server
        _ = lines
        return ""
    }
}
