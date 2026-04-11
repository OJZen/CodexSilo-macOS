import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class SettingsPageModel: ObservableObject {
    private enum LogViewerDefaults {
        static let recentEntriesLimit = 200
    }

    private let settingsCoordinator: SettingsCoordinator
    private let appLogger: AppLogger
    private let onSettingsUpdated: @MainActor (AppSettings) -> Void
    private let onStoreImported: @MainActor (AccountsStore) async -> Void
    private let noticeScheduler = NoticeAutoDismissScheduler()

    @Published var settings: AppSettings = .defaultValue
    @Published var appLogs: [AppLogEntry] = []
    @Published var liveTestLogs: [ProxyLiveTestLogEntry] = []
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }
    @Published var logsBusy = false
    private var hasLoaded = false

    init(
        settingsCoordinator: SettingsCoordinator,
        appLogger: AppLogger = NoopAppLogger.shared,
        onSettingsUpdated: @escaping @MainActor (AppSettings) -> Void = { _ in },
        onStoreImported: @escaping @MainActor (AccountsStore) async -> Void = { _ in }
    ) {
        self.settingsCoordinator = settingsCoordinator
        self.appLogger = appLogger
        self.onSettingsUpdated = onSettingsUpdated
        self.onStoreImported = onStoreImported
    }

    func loadIfNeeded() async {
        if !hasLoaded {
            await load()
        }
    }

    func load() async {
        do {
            settings = try await settingsCoordinator.currentSettings()
            liveTestLogs = try await settingsCoordinator.proxyLiveTestLogs()
            appLogs = try await appLogger.loadEntries(limit: LogViewerDefaults.recentEntriesLimit)
            onSettingsUpdated(settings)
            hasLoaded = true
            appLogger.debug(
                category: .settings,
                event: "page_load_succeeded",
                message: "Settings page loaded.",
                metadata: [
                    "file_logs": String(appLogs.count),
                    "proxy_live_test_logs": String(liveTestLogs.count)
                ]
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            appLogger.error(
                category: .settings,
                event: "page_load_failed",
                message: "Settings page failed to load.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func setLaunchAtStartup(_ value: Bool) {
        Task { await update(AppSettingsPatch(launchAtStartup: value)) }
    }

    func setAutoRefreshAccounts(_ value: Bool) {
        Task { await update(AppSettingsPatch(autoRefreshAccounts: value)) }
    }

    func setAutoSmartSwitch(_ value: Bool) {
        Task { await update(AppSettingsPatch(autoSmartSwitch: value)) }
    }

    func setAutoStartProxy(_ value: Bool) {
        Task { await update(AppSettingsPatch(autoStartApiProxy: value)) }
    }

    func setAllowLanProxyAccess(_ value: Bool) {
        Task {
            await update(
                AppSettingsPatch(allowLanProxyAccess: value),
                successText: L10n.tr("settings.notice.proxy_lan_access_updated")
            )
        }
    }

    func setLocale(_ value: String) {
        Task { await update(AppSettingsPatch(locale: value)) }
    }

    func exportAccountData(to url: URL, password: String) async -> String? {
        do {
            try await settingsCoordinator.exportAccountData(to: url, password: password)
            notice = NoticeMessage(
                style: .success,
                text: L10n.tr("settings.notice.data_exported_format", url.lastPathComponent)
            )
            appLogger.info(
                category: .settings,
                event: "page_export_succeeded",
                message: "Exported account data from settings page.",
                metadata: ["file": url.lastPathComponent]
            )
            return nil
        } catch {
            appLogger.error(
                category: .settings,
                event: "page_export_failed",
                message: "Failed to export account data from settings page.",
                metadata: ["error": error.localizedDescription]
            )
            return error.localizedDescription
        }
    }

    func importAccountData(from url: URL, password: String) async -> String? {
        do {
            let importedStore = try await settingsCoordinator.importAccountData(from: url, password: password)
            settings = importedStore.settings
            liveTestLogs = importedStore.proxyLiveTestLogs
            appLogs = (try? await appLogger.loadEntries(limit: LogViewerDefaults.recentEntriesLimit)) ?? appLogs
            onSettingsUpdated(settings)
            hasLoaded = true
            await onStoreImported(importedStore)
            notice = NoticeMessage(
                style: .success,
                text: L10n.tr("settings.notice.data_imported_format", url.lastPathComponent)
            )
            appLogger.info(
                category: .settings,
                event: "page_import_succeeded",
                message: "Imported account data from settings page.",
                metadata: ["file": url.lastPathComponent]
            )
            return nil
        } catch {
            appLogger.error(
                category: .settings,
                event: "page_import_failed",
                message: "Failed to import account data from settings page.",
                metadata: ["error": error.localizedDescription]
            )
            return error.localizedDescription
        }
    }

    func refreshAppLogs() async {
        logsBusy = true
        defer { logsBusy = false }

        do {
            appLogs = try await appLogger.loadEntries(limit: LogViewerDefaults.recentEntriesLimit)
            appLogger.debug(
                category: .settings,
                event: "refresh_file_logs_succeeded",
                message: "Refreshed file logs in settings page.",
                metadata: ["logs": String(appLogs.count)]
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            appLogger.error(
                category: .settings,
                event: "refresh_file_logs_failed",
                message: "Failed to refresh file logs in settings page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func clearAppLogs() async {
        logsBusy = true
        defer { logsBusy = false }

        do {
            try await appLogger.clearLogs()
            appLogs = []
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            appLogger.error(
                category: .settings,
                event: "clear_file_logs_failed",
                message: "Failed to clear file logs from settings page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func copyAllAppLogs() async {
        do {
            let text = try await appLogger.loadCombinedText(limit: LogViewerDefaults.recentEntriesLimit)
            PlatformClipboard.copy(text)
            appLogger.debug(
                category: .settings,
                event: "copy_all_logs",
                message: "Copied file logs from settings page.",
                metadata: ["characters": String(text.count)]
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            appLogger.error(
                category: .settings,
                event: "copy_all_logs_failed",
                message: "Failed to copy file logs from settings page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func openLogsDirectory() {
        let url = appLogger.logsDirectoryURL()
        #if canImport(AppKit)
        guard NSWorkspace.shared.open(url) else {
            let error = AppError.io(L10n.tr("error.logs.open_folder_failed"))
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            appLogger.error(
                category: .settings,
                event: "open_logs_directory_failed",
                message: "Failed to open logs directory from settings page.",
                metadata: ["path": url.path]
            )
            return
        }
        #endif
        appLogger.info(
            category: .settings,
            event: "open_logs_directory",
            message: "Opened logs directory from settings page.",
            metadata: ["path": url.path]
        )
    }

    func refreshLiveTestLogs() async {
        do {
            liveTestLogs = try await settingsCoordinator.proxyLiveTestLogs()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func clearProxyLiveTestLogs() async {
        logsBusy = true
        defer { logsBusy = false }

        do {
            try await settingsCoordinator.clearProxyLiveTestLogs()
            liveTestLogs = []
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func update(_ patch: AppSettingsPatch, successText: String = L10n.tr("settings.notice.updated")) async {
        do {
            settings = try await settingsCoordinator.updateSettings(patch)
            onSettingsUpdated(settings)
            notice = NoticeMessage(style: .success, text: successText)
            appLogger.info(
                category: .settings,
                event: "update_succeeded",
                message: "Updated settings from settings page."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            appLogger.error(
                category: .settings,
                event: "update_failed",
                message: "Failed to update settings from settings page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }
}
