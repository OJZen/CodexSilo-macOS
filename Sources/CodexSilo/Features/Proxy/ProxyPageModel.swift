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
        static let liveTestErrorNoticeDelay = Duration.seconds(12)
        static let autoRefreshInterval = Duration.seconds(1)
    }

    private let coordinator: ProxyCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform
    private let autoRefreshInterval: Duration
    private let logger: AppLogger
    private let noticeScheduler = NoticeAutoDismissScheduler()
    private var hasLoaded = false
    private var didRunLaunchBootstrap = false
    private var isPageVisible = false
    private var autoRefreshTask: Task<Void, Never>?

    @Published var proxyStatus: ApiProxyStatus = .idle
    @Published var liveTestLogs: [ProxyLiveTestLogEntry] = []
    @Published var lastRefreshedAt: Int64?
    @Published var preferredPortText = String(Defaults.preferredPort)
    @Published var autoStartProxy = false

    @Published var loading = false
    @Published var testingLiveRequest = false
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
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform,
        autoRefreshInterval: Duration = Defaults.autoRefreshInterval,
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.coordinator = coordinator
        self.settingsCoordinator = settingsCoordinator
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
        self.autoRefreshInterval = autoRefreshInterval
        self.logger = logger
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    func bootstrapOnAppLaunch(using settings: AppSettings) async {
        guard !didRunLaunchBootstrap else { return }
        didRunLaunchBootstrap = true
        logger.debug(
            category: .proxy,
            event: "bootstrap_started",
            message: "Running proxy bootstrap on app launch.",
            metadata: ["auto_start": settings.autoStartApiProxy ? "true" : "false"]
        )

        autoStartProxy = settings.autoStartApiProxy
        await refreshStatusOnly()

        guard settings.autoStartApiProxy, !proxyStatus.running else { return }

        do {
            let status = try await coordinator.startProxy(preferredPort: nil)
            applyStatus(status)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            logger.info(
                category: .proxy,
                event: "bootstrap_auto_start_succeeded",
                message: "Auto-started proxy during app bootstrap."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "bootstrap_auto_start_failed",
                message: "Failed to auto-start proxy during app bootstrap.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func loadIfNeeded() async {
        isPageVisible = true
        if !hasLoaded {
            await load()
        } else {
            await refreshForTabEntry()
        }
    }

    func refreshForTabEntry() async {
        isPageVisible = true
        await refreshStatusOnly()
    }

    func handlePageDisappear() {
        isPageVisible = false
        stopAutoRefreshLoop()
    }

    func load() async {
        loading = true
        defer { loading = false }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            autoStartProxy = settings.autoStartApiProxy
            liveTestLogs = try coordinator.loadLiveTestLogs()
            await refreshStatusOnly()
            hasLoaded = true
            logger.debug(
                category: .proxy,
                event: "page_load_succeeded",
                message: "Proxy page loaded."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "page_load_failed",
                message: "Proxy page failed to load.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func refreshStatus() async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }
        await refreshStatusOnly()
    }

    func startProxy() async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }

        let preferredPort = Int(preferredPortText)

        do {
            let status = try await coordinator.startProxy(preferredPort: preferredPort)
            applyStatus(status, preferredPort: preferredPort)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_proxy_started"))
            logger.info(
                category: .proxy,
                event: "page_start_proxy_succeeded",
                message: "Started proxy from proxy page."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "page_start_proxy_failed",
                message: "Failed to start proxy from proxy page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func stopProxy() async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }

        let status = await coordinator.stopProxy()
        applyStatus(status)
        lastRefreshedAt = dateProvider.unixSecondsNow()
        notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.api_proxy_stopped"))
        logger.info(
            category: .proxy,
            event: "page_stop_proxy_succeeded",
            message: "Stopped proxy from proxy page."
        )
    }

    func refreshAPIKey() async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }

        do {
            let status = try await coordinator.refreshAPIKey()
            applyStatus(status)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_key_refreshed"))
            logger.info(
                category: .proxy,
                event: "page_refresh_api_key_succeeded",
                message: "Refreshed proxy API key from proxy page."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "page_refresh_api_key_failed",
                message: "Failed to refresh proxy API key from proxy page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func resetMetrics() async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }

        do {
            let status = try await coordinator.resetMetrics()
            applyStatus(status)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.metrics_reset"))
            logger.info(
                category: .proxy,
                event: "page_reset_metrics_succeeded",
                message: "Reset proxy metrics from proxy page."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "page_reset_metrics_failed",
                message: "Failed to reset proxy metrics from proxy page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func testLiveRequest() async {
        guard !testingLiveRequest else { return }
        testingLiveRequest = true
        defer { testingLiveRequest = false }

        do {
            let result = try await coordinator.testLiveRequest(using: proxyStatus)
            liveTestLogs = (try? coordinator.loadLiveTestLogs()) ?? liveTestLogs
            await refreshStatusOnly()
            notice = NoticeMessage(
                style: .success,
                text: L10n.tr("proxy.notice.test_request_succeeded_format", result.model, result.outputPreview)
            )
            logger.info(
                category: .proxy,
                event: "page_live_test_succeeded",
                message: "Proxy live test succeeded from proxy page.",
                metadata: ["model": result.model]
            )
        } catch {
            liveTestLogs = (try? coordinator.loadLiveTestLogs()) ?? liveTestLogs
            await refreshStatusOnly()
            notice = NoticeMessage(
                style: .error,
                text: error.localizedDescription,
                autoDismissDelayOverride: Defaults.liveTestErrorNoticeDelay
            )
            logger.error(
                category: .proxy,
                event: "page_live_test_failed",
                message: "Proxy live test failed from proxy page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func clearLiveTestLogs() async {
        guard !testingLiveRequest else { return }
        do {
            try coordinator.clearLiveTestLogs()
            liveTestLogs = []
            logger.info(
                category: .proxy,
                event: "page_clear_live_test_logs_succeeded",
                message: "Cleared proxy live test logs from proxy page."
            )
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "page_clear_live_test_logs_failed",
                message: "Failed to clear proxy live test logs from proxy page.",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func setAutoStartProxy(_ value: Bool) async {
        guard !testingLiveRequest else { return }
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

    var controlsBusy: Bool {
        loading || testingLiveRequest
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
        reconcileAutoRefreshLoop()
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

    private func reconcileAutoRefreshLoop() {
        guard isPageVisible, runtimePlatform == .macOS, proxyStatus.running else {
            stopAutoRefreshLoop()
            return
        }

        guard autoRefreshTask == nil else { return }

        autoRefreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: autoRefreshInterval)
                guard !Task.isCancelled else { return }
                await self.performAutoRefreshTick()
            }
        }
    }

    private func stopAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func performAutoRefreshTick() async {
        guard isPageVisible, runtimePlatform == .macOS, proxyStatus.running else {
            stopAutoRefreshLoop()
            return
        }

        guard !loading, !testingLiveRequest else { return }

        let status = await coordinator.loadStatus()
        applyStatus(status)
        lastRefreshedAt = dateProvider.unixSecondsNow()
    }
}
