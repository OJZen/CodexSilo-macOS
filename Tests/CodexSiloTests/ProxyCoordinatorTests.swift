import XCTest
@testable import CodexSilo

final class ProxyCoordinatorTests: XCTestCase {
    func testRemoteStatusesRunsLookupsConcurrently() async {
        let tracker = RemoteStatusConcurrencyTracker()
        let remoteService = TrackingRemoteProxyService(tracker: tracker)
        let coordinator = ProxyCoordinator(
            proxyService: ProxyCoordinatorStubProxyRuntimeService(),
            remoteService: remoteService
        )

        let servers = [
            makeRemoteServer(id: "server-1"),
            makeRemoteServer(id: "server-2"),
            makeRemoteServer(id: "server-3")
        ]

        let statuses = await coordinator.remoteStatuses(for: servers)
        let maxActiveCount = await tracker.readMaxActiveCount()

        XCTAssertEqual(statuses.count, servers.count)
        XCTAssertGreaterThanOrEqual(maxActiveCount, 2)
    }

    private func makeRemoteServer(id: String) -> RemoteServerConfig {
        RemoteServerConfig(
            id: id,
            label: id,
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

private actor RemoteStatusConcurrencyTracker {
    private var activeCount = 0
    private var maxActiveCount = 0

    func begin() {
        activeCount += 1
        maxActiveCount = max(maxActiveCount, activeCount)
    }

    func end() {
        activeCount = max(0, activeCount - 1)
    }

    func readMaxActiveCount() -> Int {
        maxActiveCount
    }
}

private final class TrackingRemoteProxyService: RemoteProxyServiceProtocol, @unchecked Sendable {
    private let tracker: RemoteStatusConcurrencyTracker

    init(tracker: RemoteStatusConcurrencyTracker) {
        self.tracker = tracker
    }

    func status(server: RemoteServerConfig) async -> RemoteProxyStatus {
        await tracker.begin()
        try? await Task.sleep(for: .milliseconds(60))
        await tracker.end()
        return RemoteProxyStatus(
            installed: true,
            serviceInstalled: true,
            running: true,
            enabled: true,
            serviceName: "codex-tools-proxyd.service",
            pid: 42,
            baseURL: "http://\(server.host):\(server.listenPort)/v1",
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

private struct ProxyCoordinatorStubProxyRuntimeService: ProxyRuntimeService {
    func status() async -> ApiProxyStatus { .idle }
    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        _ = preferredPort
        return .idle
    }
    func stop() async -> ApiProxyStatus { .idle }
    func refreshAPIKey() async throws -> ApiProxyStatus { .idle }
    func syncAccountsStore() async throws {}
}
