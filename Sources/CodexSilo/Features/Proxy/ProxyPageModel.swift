import Foundation
import Combine

private struct ProxyPresentationState: Equatable {
    var proxyStatus: ApiProxyStatus
    var preferredPortText: String
    var autoStartProxy: Bool
}

@MainActor
final class ProxyPageModel: ObservableObject {
    private enum Defaults {
        static let preferredPort = 8787
    }

    private let coordinator: ProxyCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform
    private let noticeScheduler = NoticeAutoDismissScheduler()
    private var hasLoaded = false
    private var didRunLaunchBootstrap = false

    @Published var proxyStatus: ApiProxyStatus = .idle
    @Published var lastRefreshedAt: Int64?
    @Published var preferredPortText = String(Defaults.preferredPort)
    @Published var autoStartProxy = false

    @Published var loading = false
    @Published var notice: NoticeMessage? {
        didSet {
            noticeScheduler.schedule(notice) { [weak self] in
                self?.notice = nil
            }
        }
    }

    init(
        coordinator: ProxyCoordinator,
        settingsCoordinator: SettingsCoordinator,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform
    ) {
        self.coordinator = coordinator
        self.settingsCoordinator = settingsCoordinator
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
    }

    func bootstrapOnAppLaunch(using settings: AppSettings) async {
        guard !didRunLaunchBootstrap else { return }
        didRunLaunchBootstrap = true

        autoStartProxy = settings.autoStartApiProxy
        await refreshStatusOnly()

        guard settings.autoStartApiProxy, !proxyStatus.running else { return }

        do {
            let status = try await coordinator.startProxy(preferredPort: nil)
            applyStatus(status)
            lastRefreshedAt = dateProvider.unixSecondsNow()
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func loadIfNeeded() async {
        if !hasLoaded {
            await load()
        } else {
            await refreshForTabEntry()
        }
    }

    func refreshForTabEntry() async {
        await refreshStatusOnly()
    }

    func load() async {
        loading = true
        defer { loading = false }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            autoStartProxy = settings.autoStartApiProxy
            await refreshStatusOnly()
            hasLoaded = true
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshStatus() async {
        loading = true
        defer { loading = false }
        await refreshStatusOnly()
    }

    func startProxy() async {
        loading = true
        defer { loading = false }

        let preferredPort = Int(preferredPortText)

        do {
            let status = try await coordinator.startProxy(preferredPort: preferredPort)
            applyStatus(status, preferredPort: preferredPort)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_proxy_started"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopProxy() async {
        loading = true
        defer { loading = false }

        let status = await coordinator.stopProxy()
        applyStatus(status)
        lastRefreshedAt = dateProvider.unixSecondsNow()
        notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.api_proxy_stopped"))
    }

    func refreshAPIKey() async {
        loading = true
        defer { loading = false }

        do {
            let status = try await coordinator.refreshAPIKey()
            applyStatus(status)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_key_refreshed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func setAutoStartProxy(_ value: Bool) async {
        let previousValue = autoStartProxy
        autoStartProxy = value

        do {
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(autoStartApiProxy: value)
            )
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.auto_start_updated"))
        } catch {
            autoStartProxy = previousValue
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func refreshStatusOnly() async {
        guard runtimePlatform == .macOS else { return }
        let status = await coordinator.loadStatus()
        applyStatus(status)
        lastRefreshedAt = dateProvider.unixSecondsNow()
    }

    private func applyStatus(_ status: ApiProxyStatus, preferredPort: Int? = nil) {
        let nextState = ProxyPresentationState(
            proxyStatus: status,
            preferredPortText: String(preferredPort ?? status.port ?? Defaults.preferredPort),
            autoStartProxy: autoStartProxy
        )
        guard nextState != currentPresentationState else { return }

        setIfChanged(\.proxyStatus, nextState.proxyStatus)
        setIfChanged(\.preferredPortText, nextState.preferredPortText)
        setIfChanged(\.autoStartProxy, nextState.autoStartProxy)
    }

    private var currentPresentationState: ProxyPresentationState {
        ProxyPresentationState(
            proxyStatus: proxyStatus,
            preferredPortText: preferredPortText,
            autoStartProxy: autoStartProxy
        )
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<ProxyPageModel, Value>,
        _ newValue: Value
    ) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }
}
