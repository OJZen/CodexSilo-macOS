import Foundation
#if os(macOS)
import ServiceManagement
#endif

final class LaunchAtStartupService: LaunchAtStartupServiceProtocol, @unchecked Sendable {
    private let logger: AppLogger

    init(logger: AppLogger = NoopAppLogger.shared) {
        self.logger = logger
    }

    func setEnabled(_ enabled: Bool) throws {
        #if os(macOS)
        logger.info(
            category: .settings,
            event: "launch_at_startup_set",
            message: "Updating launch at startup setting.",
            metadata: ["enabled": enabled ? "true" : "false"]
        )
        if enabled {
            try registerMainAppIfNeeded()
        } else {
            try unregisterMainAppIfNeeded()
        }
        #else
        _ = enabled
        #endif
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        #if os(macOS)
        let currentlyEnabled = isEnabledBySystemStatus()
        guard currentlyEnabled != enabled else { return }
        logger.debug(
            category: .settings,
            event: "launch_at_startup_sync",
            message: "Synchronizing launch at startup with stored setting.",
            metadata: [
                "current": currentlyEnabled ? "true" : "false",
                "target": enabled ? "true" : "false"
            ]
        )
        try setEnabled(enabled)
        #else
        _ = enabled
        #endif
    }

    #if os(macOS)
    private func isEnabledBySystemStatus() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notFound, .notRegistered:
            return false
        @unknown default:
            return false
        }
    }

    private func registerMainAppIfNeeded() throws {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            logger.info(
                category: .settings,
                event: "launch_at_startup_enabled",
                message: "Launch at startup enabled."
            )
        } catch {
            logger.error(
                category: .settings,
                event: "launch_at_startup_enable_failed",
                message: "Failed to enable launch at startup.",
                metadata: ["error": error.localizedDescription]
            )
            throw AppError.io(L10n.tr("error.startup.enable_failed_format", error.localizedDescription))
        }
    }

    private func unregisterMainAppIfNeeded() throws {
        guard SMAppService.mainApp.status != .notRegistered else { return }
        do {
            try SMAppService.mainApp.unregister()
            logger.info(
                category: .settings,
                event: "launch_at_startup_disabled",
                message: "Launch at startup disabled."
            )
        } catch {
            logger.error(
                category: .settings,
                event: "launch_at_startup_disable_failed",
                message: "Failed to disable launch at startup.",
                metadata: ["error": error.localizedDescription]
            )
            throw AppError.io(L10n.tr("error.startup.disable_failed_format", error.localizedDescription))
        }
    }
    #endif
}
