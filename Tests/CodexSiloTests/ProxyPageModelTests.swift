import XCTest
import Combine
@testable import CodexSilo

@MainActor
final class ProxyPageModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testLoadIfNeededIgnoresRemoteSnapshotFlowInCurrentBuild() async {
        let snapshot = makeSnapshot()
        let cloudSyncService = StubProxyControlCloudSyncService(baseSnapshot: snapshot)
        let model = makeModel(
            proxyControlCloudSyncService: cloudSyncService,
            runtimePlatform: .macOS
        )

        await model.loadIfNeeded()

        let ensureCount = await cloudSyncService.readEnsurePushSubscriptionCallCount()
        let commandKinds = await cloudSyncService.readEnqueuedCommandKinds()
        XCTAssertEqual(ensureCount, 0)
        XCTAssertTrue(commandKinds.isEmpty)
        XCTAssertTrue(model.remoteServers.isEmpty)
        XCTAssertTrue(model.remoteStatuses.isEmpty)
        XCTAssertTrue(model.remoteLogs.isEmpty)
    }

    func testApplyRemoteSnapshotPublishesRefreshTimeWhenOnlyMetadataChanges() {
        let model = makeModel()
        let snapshot = makeSnapshot()

        var changeCount = 0
        model.objectWillChange
            .sink { changeCount += 1 }
            .store(in: &cancellables)

        XCTAssertTrue(model.applyRemoteSnapshot(snapshot))
        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertEqual(model.lastRefreshedAt, snapshot.syncedAt / 1_000)

        changeCount = 0
        var metadataOnlyUpdate = snapshot
        metadataOnlyUpdate.syncedAt += 2_000
        metadataOnlyUpdate.sourceDeviceID = "ios-device-2"
        metadataOnlyUpdate.lastHandledCommandID = UUID().uuidString
        metadataOnlyUpdate.lastCommandError = "ignored metadata change"

        XCTAssertFalse(model.applyRemoteSnapshot(metadataOnlyUpdate))
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(model.proxyStatus, snapshot.proxyStatus)
        XCTAssertTrue(model.remoteServers.isEmpty)
        XCTAssertTrue(model.remoteStatuses.isEmpty)
        XCTAssertTrue(model.remoteLogs.isEmpty)
        XCTAssertEqual(model.lastRefreshedAt, metadataOnlyUpdate.syncedAt / 1_000)
    }

    func testProxyPushNotificationIsIgnoredWhenRemoteControlDisabled() async throws {
        let snapshot = makeSnapshot()
        var updatedSnapshot = snapshot
        updatedSnapshot.remoteStatuses["server-1"] = RemoteProxyStatus(
            installed: true,
            serviceInstalled: true,
            running: false,
            enabled: true,
            serviceName: "codexsilo-proxy",
            pid: nil,
            baseURL: "http://1.2.3.4:8787",
            apiKey: "remote-api-key-2",
            lastError: "restarting"
        )

        let cloudSyncService = StubProxyControlCloudSyncService(
            baseSnapshot: snapshot,
            followUpSnapshots: [snapshot, updatedSnapshot]
        )
        let model = makeModel(
            proxyControlCloudSyncService: cloudSyncService,
            runtimePlatform: .macOS
        )

        await model.loadIfNeeded()

        NotificationCenter.default.post(name: .codexsiloProxyControlPushDidArrive, object: nil)
        try? await Task.sleep(for: .milliseconds(250))

        let ensureCount = await cloudSyncService.readEnsurePushSubscriptionCallCount()
        let commandKinds = await cloudSyncService.readEnqueuedCommandKinds()
        XCTAssertEqual(ensureCount, 0)
        XCTAssertTrue(commandKinds.isEmpty)
        XCTAssertTrue(model.remoteStatuses.isEmpty)
    }

    func testLocalStartProxyUsesLocalCommandServiceForImmediateSync() async {
        let snapshot = makeSnapshot()
        let localCommandService = SpyProxyLocalCommandService(snapshot: snapshot)
        let model = makeModel(localProxyCommandService: localCommandService)
        model.preferredPortText = "8787"

        await model.startProxy()

        XCTAssertEqual(model.proxyStatus, snapshot.proxyStatus)
        XCTAssertEqual(localCommandService.commands.map(\.kind), [.startProxy])
        XCTAssertEqual(localCommandService.commands.first?.preferredProxyPort, 8787)
    }

    private func makeModel(
        proxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol? = nil,
        localProxyCommandService: ProxyLocalCommandServiceProtocol? = nil,
        runtimePlatform: RuntimePlatform = .macOS
    ) -> ProxyPageModel {
        let proxyCoordinator = ProxyCoordinator(
            proxyService: StubProxyRuntimeService(),
            cloudflaredService: StubCloudflaredService(),
            remoteService: StubRemoteProxyService()
        )
        let settingsCoordinator = SettingsCoordinator(
            storeRepository: InMemoryAccountsStoreRepository(store: AccountsStore()),
            launchAtStartupService: StubLaunchAtStartupService()
        )

        return ProxyPageModel(
            coordinator: proxyCoordinator,
            settingsCoordinator: settingsCoordinator,
            proxyControlCloudSyncService: proxyControlCloudSyncService,
            localProxyCommandService: localProxyCommandService,
            runtimePlatform: runtimePlatform
        )
    }

    private func makeSnapshot() -> ProxyControlSnapshot {
        let server = RemoteServerConfig(
            id: "server-1",
            label: "Tokyo",
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
        let proxyStatus = ApiProxyStatus(
            running: true,
            port: 8787,
            apiKey: "api-key",
            baseURL: "http://127.0.0.1:8787",
            availableAccounts: 3,
            activeAccountID: "acct-1",
            activeAccountLabel: "Primary",
            lastError: nil
        )
        let cloudflaredStatus = CloudflaredStatus(
            installed: true,
            binaryPath: "/usr/local/bin/cloudflared",
            running: true,
            tunnelMode: .quick,
            publicURL: "https://example.trycloudflare.com",
            customHostname: nil,
            useHTTP2: true,
            lastError: nil
        )
        let remoteStatus = RemoteProxyStatus(
            installed: true,
            serviceInstalled: true,
            running: true,
            enabled: true,
            serviceName: "codexsilo-proxy",
            pid: 42,
            baseURL: "http://1.2.3.4:8787",
            apiKey: "remote-api-key",
            lastError: nil
        )

        return ProxyControlSnapshot(
            syncedAt: 1_763_216_000_000,
            sourceDeviceID: "ios-device-1",
            proxyStatus: proxyStatus,
            preferredProxyPort: 8787,
            autoStartProxy: true,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: .quick,
            cloudflaredNamedInput: NamedCloudflaredTunnelInput(
                apiToken: "",
                accountID: "",
                zoneID: "",
                hostname: ""
            ),
            cloudflaredUseHTTP2: true,
            publicAccessEnabled: true,
            remoteServers: [server],
            remoteStatusesSyncedAt: 1_763_216_000_000,
            remoteStatuses: [server.id: remoteStatus],
            remoteLogs: [server.id: "hello"],
            lastHandledCommandID: nil,
            lastCommandError: nil
        )
    }
}

private actor StubProxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol {
    private let baseSnapshot: ProxyControlSnapshot
    private var followUpSnapshots: [ProxyControlSnapshot]
    private var initialSnapshotPending = true
    private var acknowledgedCommandID: String?
    private(set) var ensurePushSubscriptionCallCount = 0
    private(set) var enqueuedCommandKinds: [ProxyControlCommandKind] = []

    init(
        baseSnapshot: ProxyControlSnapshot,
        followUpSnapshots: [ProxyControlSnapshot] = []
    ) {
        self.baseSnapshot = baseSnapshot
        self.followUpSnapshots = followUpSnapshots
    }

    func pushLocalSnapshot(_ snapshot: ProxyControlSnapshot) async throws {
        _ = snapshot
    }

    func pullRemoteSnapshot() async throws -> ProxyControlSnapshot? {
        if initialSnapshotPending {
            initialSnapshotPending = false
            return baseSnapshot
        }

        if let acknowledgedCommandID {
            var acknowledgedSnapshot = baseSnapshot
            acknowledgedSnapshot.lastHandledCommandID = acknowledgedCommandID
            self.acknowledgedCommandID = nil
            return acknowledgedSnapshot
        }

        if !followUpSnapshots.isEmpty {
            return followUpSnapshots.removeFirst()
        }

        return nil
    }

    func enqueueCommand(_ command: ProxyControlCommand) async throws {
        enqueuedCommandKinds.append(command.kind)
        acknowledgedCommandID = command.id
    }

    func pullPendingCommand() async throws -> ProxyControlCommand? {
        nil
    }

    func ensurePushSubscriptionIfNeeded() async throws {
        ensurePushSubscriptionCallCount += 1
    }

    func readEnsurePushSubscriptionCallCount() -> Int {
        ensurePushSubscriptionCallCount
    }

    func readEnqueuedCommandKinds() -> [ProxyControlCommandKind] {
        enqueuedCommandKinds
    }
}

private final class SpyProxyLocalCommandService: ProxyLocalCommandServiceProtocol, @unchecked Sendable {
    private(set) var commands: [ProxyControlCommand] = []
    private let snapshot: ProxyControlSnapshot

    init(snapshot: ProxyControlSnapshot) {
        self.snapshot = snapshot
    }

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        commands.append(command)
        return snapshot
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
