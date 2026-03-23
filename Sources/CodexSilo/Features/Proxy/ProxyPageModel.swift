import Foundation
import Combine

enum RemoteServerAction: Equatable {
    case save
    case remove
    case refresh
    case deploy
    case start
    case stop
    case logs
}

private struct RemoteSnapshotPresentationState: Equatable {
    var proxyStatus: ApiProxyStatus
    var preferredPortText: String
    var autoStartProxy: Bool
    var remoteServers: [RemoteServerConfig]
    var remoteStatuses: [String: RemoteProxyStatus]
    var remoteLogs: [String: String]

    init(
        proxyStatus: ApiProxyStatus,
        preferredPortText: String,
        autoStartProxy: Bool,
        remoteServers: [RemoteServerConfig],
        remoteStatuses: [String: RemoteProxyStatus],
        remoteLogs: [String: String]
    ) {
        self.proxyStatus = proxyStatus
        self.preferredPortText = preferredPortText
        self.autoStartProxy = autoStartProxy
        self.remoteServers = remoteServers
        self.remoteStatuses = remoteStatuses
        self.remoteLogs = remoteLogs
    }

    init(snapshot: ProxyControlSnapshot, includeRemoteServers: Bool) {
        proxyStatus = snapshot.proxyStatus
        preferredPortText = String(
            snapshot.preferredProxyPort
                ?? snapshot.proxyStatus.port
                ?? RemoteServerConfiguration.defaultProxyPort
        )
        autoStartProxy = snapshot.autoStartProxy
        remoteServers = includeRemoteServers ? snapshot.remoteServers : []
        remoteStatuses = includeRemoteServers ? snapshot.remoteStatuses : [:]
        remoteLogs = includeRemoteServers ? snapshot.remoteLogs : [:]
    }
}

@MainActor
final class ProxyPageModel: ObservableObject {
    private enum RemoteControlPolling {
        static let snapshotSyncInterval: Duration = .seconds(1)
        static let snapshotFreshnessWindowMilliseconds: Int64 = 5_000
        static let remoteStatusesFreshnessWindowMilliseconds: Int64 = 12_000
        static let commandAckPollLimit = 24
        static let commandAckPollInterval: Duration = .milliseconds(250)
        static let logAckPollLimit = 36
        static let logAckPollInterval: Duration = .milliseconds(250)
    }

    private let coordinator: ProxyCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let proxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol?
    private let localProxyCommandService: ProxyLocalCommandServiceProtocol?
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform
    private let noticeScheduler = NoticeAutoDismissScheduler()
    private var hasLoaded = false
    private var didRunLaunchBootstrap = false
    private var remoteSnapshotTask: Task<Void, Never>?
    private var lastRemoteCommandID: String?
    private var lastAppliedRemoteSnapshotSyncedAt: Int64?
    private var lastAppliedRemoteStatusesSyncedAt: Int64?
    private var proxyPushCancellable: AnyCancellable?

    @Published var proxyStatus: ApiProxyStatus = .idle
    @Published var remoteServers: [RemoteServerConfig] = []
    @Published var remoteStatuses: [String: RemoteProxyStatus] = [:]
    @Published var remoteLogs: [String: String] = [:]
    @Published var remoteActions: [String: RemoteServerAction] = [:]
    @Published var lastRefreshedAt: Int64?

    @Published var preferredPortText = String(RemoteServerConfiguration.defaultProxyPort)
    @Published var autoStartProxy = false
    @Published var showsRemoteControlCallout = true

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
        proxyControlCloudSyncService: ProxyControlCloudSyncServiceProtocol? = nil,
        localProxyCommandService: ProxyLocalCommandServiceProtocol? = nil,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform
    ) {
        self.coordinator = coordinator
        self.settingsCoordinator = settingsCoordinator
        self.proxyControlCloudSyncService = proxyControlCloudSyncService
        self.localProxyCommandService = localProxyCommandService
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
    }

    deinit {
        remoteSnapshotTask?.cancel()
    }

    var canManageRemoteServers: Bool {
        false
    }

    var usesRemoteMacControl: Bool {
        false
    }

    func dismissRemoteControlCallout() {
        showsRemoteControlCallout = false
    }

    func bootstrapOnAppLaunch(using settings: AppSettings) async {
        guard !didRunLaunchBootstrap else { return }
        didRunLaunchBootstrap = true

        autoStartProxy = settings.autoStartApiProxy
        if usesRemoteMacControl {
            configureProxyPushHandlingIfNeeded()
            await ensureProxyPushSubscriptionIfNeeded()
            await refreshRemoteSnapshot(showErrors: false)
            if shouldRequestRemoteSnapshotRefresh() {
                await requestRemoteSnapshotRefresh(showErrors: false)
            }
            startRemoteSnapshotSyncIfNeeded()
            return
        }

        stopRemoteSnapshotSync()
        await refreshStatusOnly()

        guard settings.autoStartApiProxy, !proxyStatus.running else { return }

        do {
            proxyStatus = try await coordinator.startProxy(preferredPort: nil)
            await refreshStatusOnly()
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
        if usesRemoteMacControl {
            await refreshRemoteSnapshot(showErrors: false)
            if shouldRequestRemoteSnapshotRefresh() {
                await requestRemoteSnapshotRefresh(showErrors: false)
            }
            return
        }

        await refreshStatusOnly()
    }

    func load() async {
        loading = true
        defer { loading = false }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            remoteServers = []
            remoteStatuses = [:]
            remoteLogs = [:]
            autoStartProxy = settings.autoStartApiProxy
            if usesRemoteMacControl {
                configureProxyPushHandlingIfNeeded()
                await ensureProxyPushSubscriptionIfNeeded()
                await refreshRemoteSnapshot(showErrors: true)
                if shouldRequestRemoteSnapshotRefresh() {
                    await requestRemoteSnapshotRefresh(showErrors: false)
                }
                startRemoteSnapshotSyncIfNeeded()
            } else {
                stopRemoteSnapshotSync()
                await refreshStatusOnly()
            }
            hasLoaded = true
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshStatus() async {
        if usesRemoteMacControl {
            await requestRemoteSnapshotRefresh(showErrors: true, showLoading: true)
            return
        }
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await performLocalCommand(kind: .refreshStatus)
            applyRemoteSnapshot(snapshot)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func startProxy() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .startProxy,
                preferredProxyPort: Int(preferredPortText),
                successNotice: L10n.tr("proxy.notice.api_proxy_started")
            )
            return
        }
        loading = true
        defer { loading = false }

        let preferredPort = Int(preferredPortText)

        do {
            let snapshot = try await performLocalCommand(
                kind: .startProxy,
                preferredProxyPort: preferredPort
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_proxy_started"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopProxy() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .stopProxy,
                successNotice: L10n.tr("proxy.notice.api_proxy_stopped")
            )
            return
        }
        loading = true
        defer { loading = false }

        do {
            let snapshot = try await performLocalCommand(kind: .stopProxy)
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.api_proxy_stopped"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshAPIKey() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .refreshAPIKey,
                successNotice: L10n.tr("proxy.notice.api_key_refreshed")
            )
            return
        }
        loading = true
        defer { loading = false }

        do {
            let snapshot = try await performLocalCommand(kind: .refreshAPIKey)
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.api_key_refreshed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func setAutoStartProxy(_ value: Bool) async {
        if usesRemoteMacControl {
            autoStartProxy = value
            await performRemoteCommand(
                kind: .setAutoStartProxy,
                autoStartProxy: value,
                successNotice: L10n.tr("proxy.notice.auto_start_updated")
            )
            return
        }
        do {
            let snapshot = try await performLocalCommand(
                kind: .setAutoStartProxy,
                autoStartProxy: value
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.auto_start_updated"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func addRemoteServer() async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .addRemoteServer,
                remoteServer: RemoteServerConfiguration.makeDraft(),
                successNotice: L10n.tr("settings.notice.remote_servers_saved")
            )
            return
        }
        do {
            let snapshot = try await performLocalCommand(
                kind: .addRemoteServer,
                remoteServer: RemoteServerConfiguration.makeDraft()
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.notice.remote_servers_saved"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func saveRemoteServer(_ server: RemoteServerConfig) async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .saveRemoteServer,
                remoteServer: RemoteServerConfiguration.normalize(server),
                successNotice: L10n.tr("settings.notice.remote_servers_saved")
            )
            return
        }
        remoteActions[server.id] = .save
        defer { remoteActions.removeValue(forKey: server.id) }
        do {
            let snapshot = try await performLocalCommand(
                kind: .saveRemoteServer,
                remoteServer: RemoteServerConfiguration.normalize(server)
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("settings.notice.remote_servers_saved"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func removeRemoteServer(id: String) async {
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .removeRemoteServer,
                remoteServerID: id,
                successNotice: L10n.tr("proxy.notice.remote_server_removed")
            )
            return
        }
        remoteActions[id] = .remove
        defer { remoteActions.removeValue(forKey: id) }
        do {
            let snapshot = try await performLocalCommand(
                kind: .removeRemoteServer,
                remoteServerID: id
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_server_removed"))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func refreshAllRemoteStatuses() async {
        guard canManageRemoteServers else {
            remoteStatuses = [:]
            return
        }
        if usesRemoteMacControl {
            await refreshRemoteSnapshot(showErrors: false)
            return
        }
        remoteStatuses = await coordinator.remoteStatuses(for: remoteServers)
    }

    func refreshRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(kind: .refreshRemote, remoteServerID: server.id)
            return
        }
        remoteActions[server.id] = .refresh
        defer { remoteActions.removeValue(forKey: server.id) }
        do {
            let snapshot = try await performLocalCommand(
                kind: .refreshRemote,
                remoteServerID: server.id
            )
            applyRemoteSnapshot(snapshot)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func deployRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .deployRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_deploy_done_format", server.label),
                pendingNotice: L10n.tr("proxy.notice.remote_deploying_format", server.label)
            )
            return
        }
        remoteActions[server.id] = .deploy
        defer { remoteActions.removeValue(forKey: server.id) }
        notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_deploying_format", server.label))

        do {
            let snapshot = try await performLocalCommand(
                kind: .deployRemote,
                remoteServerID: server.id
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_deploy_done_format", server.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func startRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .startRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_started_format", server.label)
            )
            return
        }
        remoteActions[server.id] = .start
        defer { remoteActions.removeValue(forKey: server.id) }

        do {
            let snapshot = try await performLocalCommand(
                kind: .startRemote,
                remoteServerID: server.id
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .success, text: L10n.tr("proxy.notice.remote_started_format", server.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func stopRemote(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            await performRemoteCommand(
                kind: .stopRemote,
                remoteServerID: server.id,
                successNotice: L10n.tr("proxy.notice.remote_stopped_format", server.label)
            )
            return
        }
        remoteActions[server.id] = .stop
        defer { remoteActions.removeValue(forKey: server.id) }

        do {
            let snapshot = try await performLocalCommand(
                kind: .stopRemote,
                remoteServerID: server.id
            )
            applyRemoteSnapshot(snapshot)
            notice = NoticeMessage(style: .info, text: L10n.tr("proxy.notice.remote_stopped_format", server.label))
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    func readRemoteLogs(server: RemoteServerConfig) async {
        guard canManageRemoteServers else { return }
        if usesRemoteMacControl {
            remoteActions[server.id] = .logs
            defer { remoteActions.removeValue(forKey: server.id) }

            await performRemoteLogCommand(
                serverID: server.id,
                logLines: 120
            )
            return
        }
        remoteActions[server.id] = .logs
        defer { remoteActions.removeValue(forKey: server.id) }

        do {
            let snapshot = try await performLocalCommand(
                kind: .readRemoteLogs,
                remoteServerID: server.id,
                logLines: 120
            )
            applyRemoteSnapshot(snapshot)
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func refreshStatusOnly() async {
        proxyStatus = await coordinator.loadStatus()
        lastRefreshedAt = dateProvider.unixSecondsNow()
    }

    private func startRemoteSnapshotSyncIfNeeded() {
        guard usesRemoteMacControl else { return }
        guard remoteSnapshotTask == nil else { return }

        remoteSnapshotTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: RemoteControlPolling.snapshotSyncInterval)
                await self.refreshRemoteSnapshot(showErrors: false)
            }
        }
    }

    private func stopRemoteSnapshotSync() {
        remoteSnapshotTask?.cancel()
        remoteSnapshotTask = nil
    }

    private func configureProxyPushHandlingIfNeeded() {
        guard proxyPushCancellable == nil else { return }

        proxyPushCancellable = NotificationCenter.default
            .publisher(for: .codexsiloProxyControlPushDidArrive)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshRemoteSnapshotAfterPush()
                }
            }
    }

    private func ensureProxyPushSubscriptionIfNeeded() async {
        guard let proxyControlCloudSyncService else { return }
        do {
            try await proxyControlCloudSyncService.ensurePushSubscriptionIfNeeded()
        } catch {
            #if DEBUG
            // print("Proxy push subscription skipped:", error.localizedDescription)
            #endif
        }
    }

    @discardableResult
    private func refreshRemoteSnapshot(showErrors: Bool) async -> Bool {
        guard let proxyControlCloudSyncService else { return false }

        do {
            if let snapshot = try await proxyControlCloudSyncService.pullRemoteSnapshot() {
                return applyRemoteSnapshot(snapshot)
            }
        } catch {
            if showErrors {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }

        return false
    }

    private func refreshRemoteSnapshotAfterPush() async {
        let policy = CloudPushPullRetryPolicy.nearRealtime

        for attempt in 0..<policy.maxAttempts {
            let didPullSnapshot = await refreshRemoteSnapshot(showErrors: false)
            if didPullSnapshot {
                return
            }

            guard attempt + 1 < policy.maxAttempts else {
                return
            }
            try? await Task.sleep(for: policy.retryInterval)
        }
    }

    @discardableResult
    func applyRemoteSnapshot(_ snapshot: ProxyControlSnapshot) -> Bool {
        lastAppliedRemoteSnapshotSyncedAt = snapshot.syncedAt
        lastAppliedRemoteStatusesSyncedAt = snapshot.remoteStatusesSyncedAt
        setIfChanged(\.lastRefreshedAt, max(snapshot.syncedAt, snapshot.remoteStatusesSyncedAt ?? 0) / 1_000)
        let nextState = RemoteSnapshotPresentationState(
            snapshot: snapshot,
            includeRemoteServers: canManageRemoteServers
        )
        guard nextState != currentRemoteSnapshotPresentationState else {
            return false
        }

        setIfChanged(\.proxyStatus, nextState.proxyStatus)
        setIfChanged(\.preferredPortText, nextState.preferredPortText)
        setIfChanged(\.autoStartProxy, nextState.autoStartProxy)
        setIfChanged(\.remoteServers, nextState.remoteServers)
        setIfChanged(\.remoteStatuses, nextState.remoteStatuses)
        setIfChanged(\.remoteLogs, nextState.remoteLogs)
        return true
    }

    private var currentRemoteSnapshotPresentationState: RemoteSnapshotPresentationState {
        RemoteSnapshotPresentationState(
            proxyStatus: proxyStatus,
            preferredPortText: preferredPortText,
            autoStartProxy: autoStartProxy,
            remoteServers: remoteServers,
            remoteStatuses: remoteStatuses,
            remoteLogs: remoteLogs
        )
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<ProxyPageModel, Value>,
        _ newValue: Value
    ) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    private func shouldRequestRemoteSnapshotRefresh() -> Bool {
        guard let lastAppliedRemoteSnapshotSyncedAt else {
            return true
        }

        let now = dateProvider.unixMillisecondsNow()
        if now - lastAppliedRemoteSnapshotSyncedAt >= RemoteControlPolling.snapshotFreshnessWindowMilliseconds {
            return true
        }

        guard !remoteServers.isEmpty else {
            return false
        }

        guard let lastAppliedRemoteStatusesSyncedAt else {
            return true
        }
        return now - lastAppliedRemoteStatusesSyncedAt >= RemoteControlPolling.remoteStatusesFreshnessWindowMilliseconds
    }

    private func requestRemoteSnapshotRefresh(
        showErrors: Bool,
        showLoading: Bool = false
    ) async {
        guard let proxyControlCloudSyncService else { return }

        if showLoading {
            loading = true
        }
        defer {
            if showLoading {
                loading = false
            }
        }

        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: .refreshStatus
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(command.id) {
                applyRemoteSnapshot(acknowledgedSnapshot)
            } else {
                await refreshRemoteSnapshot(showErrors: false)
            }
        } catch {
            if showErrors {
                notice = NoticeMessage(style: .error, text: error.localizedDescription)
            }
        }
    }

    private func performRemoteCommand(
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        logLines: Int? = nil,
        successNotice: String? = nil,
        pendingNotice: String? = nil
    ) async {
        guard let proxyControlCloudSyncService else { return }

        loading = true
        defer { loading = false }

        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            logLines: logLines
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let pendingNotice {
                notice = NoticeMessage(style: .info, text: pendingNotice)
            }

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(command.id) {
                applyRemoteSnapshot(acknowledgedSnapshot)
                if let error = acknowledgedSnapshot.lastCommandError,
                   acknowledgedSnapshot.lastHandledCommandID == command.id,
                   !error.isEmpty {
                    notice = NoticeMessage(style: .error, text: error)
                } else if let successNotice {
                    notice = NoticeMessage(style: .success, text: successNotice)
                }
            } else if let successNotice {
                notice = NoticeMessage(style: .info, text: successNotice)
            }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func performRemoteLogCommand(serverID: String, logLines: Int) async {
        guard let proxyControlCloudSyncService else { return }

        let previousLogs = remoteLogs[serverID]
        let command = makeProxyControlCommand(
            sourceDeviceID: "ios-proxy-control",
            kind: .readRemoteLogs,
            remoteServerID: serverID,
            logLines: logLines
        )

        do {
            try await proxyControlCloudSyncService.enqueueCommand(command)
            lastRemoteCommandID = command.id

            if let acknowledgedSnapshot = try await waitForRemoteCommandAck(
                command.id,
                pollLimit: RemoteControlPolling.logAckPollLimit,
                pollInterval: RemoteControlPolling.logAckPollInterval,
                acceptance: { snapshot in
                    if snapshot.lastHandledCommandID == command.id {
                        return true
                    }
                    return snapshot.remoteLogs[serverID] != previousLogs && snapshot.remoteLogs[serverID] != nil
                }
            ) {
                applyRemoteSnapshot(acknowledgedSnapshot)
                if let error = acknowledgedSnapshot.lastCommandError,
                   acknowledgedSnapshot.lastHandledCommandID == command.id,
                   !error.isEmpty {
                    notice = NoticeMessage(style: .error, text: error)
                }
            } else {
                await refreshRemoteSnapshot(showErrors: false)
                if remoteLogs[serverID] == previousLogs {
                    notice = NoticeMessage(style: .error, text: L10n.tr("error.remote.logs_unavailable"))
                }
            }
        } catch {
            notice = NoticeMessage(style: .error, text: error.localizedDescription)
        }
    }

    private func waitForRemoteCommandAck(
        _ commandID: String,
        pollLimit: Int = RemoteControlPolling.commandAckPollLimit,
        pollInterval: Duration = RemoteControlPolling.commandAckPollInterval,
        acceptance: ((ProxyControlSnapshot) -> Bool)? = nil
    ) async throws -> ProxyControlSnapshot? {
        guard let proxyControlCloudSyncService else { return nil }

        for _ in 0..<pollLimit {
            if let snapshot = try await proxyControlCloudSyncService.pullRemoteSnapshot() {
                let isAccepted = acceptance?(snapshot) ?? (snapshot.lastHandledCommandID == commandID)
                if isAccepted {
                    return snapshot
                }
                applyRemoteSnapshot(snapshot)
            }
            try? await Task.sleep(for: pollInterval)
        }

        return nil
    }

    private func performLocalCommand(
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        logLines: Int? = nil
    ) async throws -> ProxyControlSnapshot {
        guard let localProxyCommandService else {
            throw AppError.invalidData("Local proxy command service is unavailable.")
        }

        let command = makeProxyControlCommand(
            sourceDeviceID: "macos-proxy-control",
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            logLines: logLines
        )
        return try await localProxyCommandService.performLocalCommand(command)
    }

    private func makeProxyControlCommand(
        sourceDeviceID: String,
        kind: ProxyControlCommandKind,
        preferredProxyPort: Int? = nil,
        autoStartProxy: Bool? = nil,
        remoteServer: RemoteServerConfig? = nil,
        remoteServerID: String? = nil,
        logLines: Int? = nil
    ) -> ProxyControlCommand {
        ProxyControlCommand(
            id: UUID().uuidString,
            createdAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: sourceDeviceID,
            kind: kind,
            preferredProxyPort: preferredProxyPort,
            autoStartProxy: autoStartProxy,
            remoteServer: remoteServer,
            remoteServerID: remoteServerID,
            logLines: logLines
        )
    }
}
