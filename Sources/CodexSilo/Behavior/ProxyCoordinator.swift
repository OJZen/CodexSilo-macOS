import Foundation

final class ProxyCoordinator: @unchecked Sendable {
    private let proxyService: ProxyRuntimeService

    init(proxyService: ProxyRuntimeService) {
        self.proxyService = proxyService
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
}
