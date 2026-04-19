import Foundation
import Combine

private struct ProxyPresentationState: Equatable {
    var proxyStatus: ApiProxyStatus
    var preferredPortText: String
    var proxyAccountSelection: ProxyAccountSelectionSnapshot
}

@MainActor
final class ProxyPageModel: ObservableObject {
    private enum Defaults {
        static let preferredPort = 8787
        static let liveTestErrorNoticeDelay = Duration.seconds(12)
        static let autoRefreshInterval = Duration.seconds(1)
        static let followCurrentSelectionID = "__proxy.follow_current__"
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
    @Published var proxyAccountOptions: [ProxyAccountOption] = []
    @Published var selectedProxyAccountRoutingMode: ProxyAccountRoutingMode?
    @Published var selectedProxyAccountOptionID: String?
    @Published var currentProxyAccountOptionID: String?

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
            _ = try await settingsCoordinator.currentSettings()
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

    func setProxyAccountSelection(choiceID: String) async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }

        do {
            let selectionSnapshot = try await coordinator.updateProxyAccountSelection(
                mode: choiceID == Defaults.followCurrentSelectionID ? nil : .fixedAccount,
                optionID: choiceID == Defaults.followCurrentSelectionID ? nil : choiceID
            )
            let status = await coordinator.loadStatus()
            applyStatus(status, selectionSnapshot: selectionSnapshot)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.selected_account_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func setAutoSwitchProxyAccounts(_ value: Bool) async {
        guard !testingLiveRequest else { return }
        loading = true
        defer { loading = false }

        do {
            let selectionSnapshot = try await coordinator.updateProxyAccountSelection(
                mode: value ? .autoUniform : nil,
                optionID: nil
            )
            let status = await coordinator.loadStatus()
            applyStatus(status, selectionSnapshot: selectionSnapshot)
            lastRefreshedAt = dateProvider.unixSecondsNow()
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.selected_account_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func refreshStatusOnly() async {
        guard runtimePlatform == .macOS else { return }
        let status = await coordinator.loadStatus()
        applyStatus(status, selectionSnapshot: refreshSelectionSnapshot())
        lastRefreshedAt = dateProvider.unixSecondsNow()
    }

    var controlsBusy: Bool {
        loading || testingLiveRequest
    }

    var selectedProxyAccountPickerID: String {
        selectedProxyAccountOptionID ?? Defaults.followCurrentSelectionID
    }

    var followCurrentSelectionID: String {
        Defaults.followCurrentSelectionID
    }

    var followCurrentProxyAccountTitle: String {
        if let currentOption = proxyAccountOptions.first(where: { $0.id == currentProxyAccountOptionID }) {
            return L10n.tr("proxy.selection.follow_current_format", currentOption.label)
        }
        return L10n.tr("proxy.selection.follow_current")
    }

    var autoSwitchPickerTitle: String {
        if let activeOption = activeProxyAccountOption {
            return activeOption.label
        }
        if let activeAccountLabel = proxyStatus.activeAccountLabel, !activeAccountLabel.isEmpty {
            return activeAccountLabel
        }
        return L10n.tr("proxy.selection.auto_switch_waiting")
    }

    var selectedProxyAccountHeadline: String {
        if selectedProxyAccountRoutingMode == .autoUniform {
            return L10n.tr("proxy.selection.auto_switch")
        }
        if let selectedOption = proxyAccountOptions.first(where: { $0.id == selectedProxyAccountOptionID }) {
            return selectedOption.label
        }
        return followCurrentProxyAccountTitle
    }

    var selectedProxyAccountDetailText: String {
        if selectedProxyAccountRoutingMode == .autoUniform {
            if let activeAccountLabel = proxyStatus.activeAccountLabel,
               !activeAccountLabel.isEmpty {
                return L10n.tr(
                    "proxy.info.selected_account_auto_uniform_last_hit_format",
                    String(proxyAccountOptions.count),
                    activeAccountLabel
                )
            }
            return L10n.tr(
                "proxy.info.selected_account_auto_uniform_format",
                String(proxyAccountOptions.count)
            )
        }
        if let selectedOption = proxyAccountOptions.first(where: { $0.id == selectedProxyAccountOptionID }) {
            return selectedOption.detail ?? selectedOption.accountID
        }
        if let currentOption = proxyAccountOptions.first(where: { $0.id == currentProxyAccountOptionID }) {
            return currentOption.detail ?? currentOption.accountID
        }
        return L10n.tr("proxy.info.selected_account_hint")
    }

    var followsCurrentProxyAccount: Bool {
        selectedProxyAccountRoutingMode == nil
    }

    var usesAutoUniformProxyAccountRouting: Bool {
        selectedProxyAccountRoutingMode == .autoUniform
    }

    private var activeProxyAccountOption: ProxyAccountOption? {
        guard let activeAccountID = proxyStatus.activeAccountID else {
            return nil
        }
        return proxyAccountOptions.first(where: { $0.accountID == activeAccountID })
    }

    private func applyStatus(
        _ status: ApiProxyStatus,
        preferredPort: Int? = nil,
        selectionSnapshot: ProxyAccountSelectionSnapshot? = nil
    ) {
        let resolvedSelectionSnapshot = selectionSnapshot ?? currentProxyAccountSelectionSnapshot
        let nextState = ProxyPresentationState(
            proxyStatus: status,
            preferredPortText: String(preferredPort ?? status.port ?? Defaults.preferredPort),
            proxyAccountSelection: resolvedSelectionSnapshot
        )
        guard nextState != currentPresentationState else { return }

        setIfChanged(\.proxyStatus, nextState.proxyStatus)
        setIfChanged(\.preferredPortText, nextState.preferredPortText)
        setIfChanged(\.proxyAccountOptions, nextState.proxyAccountSelection.options)
        setIfChanged(\.selectedProxyAccountRoutingMode, nextState.proxyAccountSelection.mode)
        setIfChanged(\.selectedProxyAccountOptionID, nextState.proxyAccountSelection.selectedOptionID)
        setIfChanged(\.currentProxyAccountOptionID, nextState.proxyAccountSelection.currentOptionID)
        reconcileAutoRefreshLoop()
    }

    private var currentPresentationState: ProxyPresentationState {
        ProxyPresentationState(
            proxyStatus: proxyStatus,
            preferredPortText: preferredPortText,
            proxyAccountSelection: currentProxyAccountSelectionSnapshot
        )
    }

    private var currentProxyAccountSelectionSnapshot: ProxyAccountSelectionSnapshot {
        ProxyAccountSelectionSnapshot(
            options: proxyAccountOptions,
            mode: selectedProxyAccountRoutingMode,
            selectedOptionID: selectedProxyAccountOptionID,
            currentOptionID: currentProxyAccountOptionID
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
        applyStatus(status, selectionSnapshot: refreshSelectionSnapshot())
        lastRefreshedAt = dateProvider.unixSecondsNow()
    }

    private func refreshSelectionSnapshot() -> ProxyAccountSelectionSnapshot {
        (try? coordinator.loadProxyAccountSelectionSnapshot()) ?? currentProxyAccountSelectionSnapshot
    }
}
