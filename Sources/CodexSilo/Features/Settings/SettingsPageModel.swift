import Foundation
import Combine

@MainActor
final class SettingsPageModel: ObservableObject {
    private let settingsCoordinator: SettingsCoordinator
    private let onSettingsUpdated: @MainActor (AppSettings) -> Void
    private let onStoreImported: @MainActor (AccountsStore) async -> Void
    private let noticeScheduler = NoticeAutoDismissScheduler()

    @Published var settings: AppSettings = .defaultValue
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
        onSettingsUpdated: @escaping @MainActor (AppSettings) -> Void = { _ in },
        onStoreImported: @escaping @MainActor (AccountsStore) async -> Void = { _ in }
    ) {
        self.settingsCoordinator = settingsCoordinator
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
            onSettingsUpdated(settings)
            hasLoaded = true
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
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
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func importAccountData(from url: URL, password: String) async -> String? {
        do {
            let importedStore = try await settingsCoordinator.importAccountData(from: url, password: password)
            settings = importedStore.settings
            liveTestLogs = importedStore.proxyLiveTestLogs
            onSettingsUpdated(settings)
            hasLoaded = true
            await onStoreImported(importedStore)
            notice = NoticeMessage(
                style: .success,
                text: L10n.tr("settings.notice.data_imported_format", url.lastPathComponent)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
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
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }
}
