import Foundation

actor UpdateCoordinator {
    private let service: UpdateCheckingService

    init(service: UpdateCheckingService) {
        self.service = service
    }

    func check(currentVersion: String) async throws -> PendingUpdateInfo? {
        try await service.checkForUpdates(currentVersion: currentVersion)
    }
}
