import Foundation

final class ProxyCoordinator: @unchecked Sendable {
    private let proxyService: ProxyRuntimeService
    private let remoteService: RemoteProxyServiceProtocol

    init(
        proxyService: ProxyRuntimeService,
        remoteService: RemoteProxyServiceProtocol
    ) {
        self.proxyService = proxyService
        self.remoteService = remoteService
    }

    func loadStatus() async -> ApiProxyStatus {
        await proxyService.status()
    }

    func startProxy(preferredPort: Int?) async throws -> ApiProxyStatus {
        try await proxyService.syncAccountsStore()
        return try await proxyService.start(preferredPort: preferredPort)
    }

    func stopProxy() async -> ApiProxyStatus {
        await proxyService.stop()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        try await proxyService.refreshAPIKey()
    }

    func remoteStatus(server: RemoteServerConfig) async -> RemoteProxyStatus {
        await remoteService.status(server: server)
    }

    func remoteStatuses(for servers: [RemoteServerConfig]) async -> [String: RemoteProxyStatus] {
        await withTaskGroup(of: (String, RemoteProxyStatus).self, returning: [String: RemoteProxyStatus].self) { group in
            for server in servers {
                group.addTask { [remoteService] in
                    (server.id, await remoteService.status(server: server))
                }
            }

            var merged: [String: RemoteProxyStatus] = [:]
            for await (serverID, status) in group {
                merged[serverID] = status
            }
            return merged
        }
    }

    func deployRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.deploy(server: server)
    }

    func startRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.start(server: server)
    }

    func stopRemote(server: RemoteServerConfig) async throws -> RemoteProxyStatus {
        try await remoteService.stop(server: server)
    }

    func readRemoteLogs(server: RemoteServerConfig, lines: Int) async throws -> String {
        try await remoteService.readLogs(server: server, lines: lines)
    }
}
