import Foundation
import Combine

actor ProxyControlBridge: ProxyLocalCommandServiceProtocol {
    private enum Constants {
        static let syncInterval: Duration = .seconds(1)
        static let remoteStatusRefreshIntervalMilliseconds: Int64 = 8_000
    }

    private struct RemoteStatusRefreshSnapshot: Sendable {
        let remoteStatusesSyncedAt: Int64
        let remoteStatuses: [String: RemoteProxyStatus]
    }

    private struct CommandExecutionResult {
        let forceRemoteStatusRefresh: Bool

        static let noRemoteStatusRefresh = CommandExecutionResult(forceRemoteStatusRefresh: false)
        static let forceRemoteStatusRefresh = CommandExecutionResult(forceRemoteStatusRefresh: true)
    }

    private let proxyCoordinator: ProxyCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let cloudSyncService: ProxyControlCloudSyncServiceProtocol?
    private let dateProvider: DateProviding
    private let runtimePlatform: RuntimePlatform
    private let sourceDeviceID: String

    private var loopTask: Task<Void, Never>?
    private var remoteStatusRefreshTask: Task<Void, Never>?
    private var hasPendingForcedRemoteStatusRefresh = false
    private var lastHandledCommandID: String?
    private var lastCommandError: String?
    private var remoteLogs: [String: String] = [:]
    private var cachedRemoteStatuses: [String: RemoteProxyStatus] = [:]
    private var lastRemoteStatusRefreshAt: Int64?
    private var pushCancellable: AnyCancellable?

    init(
        proxyCoordinator: ProxyCoordinator,
        settingsCoordinator: SettingsCoordinator,
        cloudSyncService: ProxyControlCloudSyncServiceProtocol?,
        dateProvider: DateProviding = SystemDateProvider(),
        runtimePlatform: RuntimePlatform = PlatformCapabilities.currentPlatform,
        sourceDeviceID: String = "macos-proxy-bridge"
    ) {
        self.proxyCoordinator = proxyCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.cloudSyncService = cloudSyncService
        self.dateProvider = dateProvider
        self.runtimePlatform = runtimePlatform
        self.sourceDeviceID = sourceDeviceID
    }

    func start() {
        guard runtimePlatform == .macOS else { return }
        guard loopTask == nil else { return }
        configurePushHandlingIfNeeded()
        Task {
            do {
                try await cloudSyncService?.ensurePushSubscriptionIfNeeded()
                await seedStateFromLatestSnapshotIfAvailable()
                scheduleRemoteStatusRefreshIfNeeded(force: cachedRemoteStatuses.isEmpty)
            } catch {
                #if DEBUG
                // print("CloudKit proxy push subscription skipped:", error.localizedDescription)
                #endif
            }
        }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        remoteStatusRefreshTask?.cancel()
        remoteStatusRefreshTask = nil
        pushCancellable = nil
    }

    func performLocalCommand(_ command: ProxyControlCommand) async throws -> ProxyControlSnapshot {
        guard runtimePlatform == .macOS else {
            throw AppError.invalidData("Local proxy commands are only available on macOS.")
        }

        let executionResult = try await execute(command)
        lastCommandError = nil

        let snapshot = try await buildSnapshot(forceRemoteStatusRefresh: executionResult.forceRemoteStatusRefresh)
        try await cloudSyncService?.pushLocalSnapshot(snapshot)
        return snapshot
    }

    func handlePushNotification() async {
        guard runtimePlatform == .macOS else { return }
        do {
            let didHandleCommand = try await processPendingCommandIfNeeded()
            if !didHandleCommand {
                try await publishSnapshot()
            }
        } catch {
            #if DEBUG
            // print("Proxy control push handling skipped:", error.localizedDescription)
            #endif
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                scheduleRemoteStatusRefreshIfNeeded(force: false)
                let didHandleCommand = try await processPendingCommandIfNeeded()
                if !didHandleCommand {
                    try await publishSnapshot()
                }
            } catch {
                #if DEBUG
                // print("Proxy control bridge skipped:", error.localizedDescription)
                #endif
            }

            try? await Task.sleep(for: Constants.syncInterval)
        }
    }

    private func configurePushHandlingIfNeeded() {
        guard pushCancellable == nil else { return }

        pushCancellable = NotificationCenter.default
            .publisher(for: .codexsiloProxyControlPushDidArrive)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.handlePushNotification()
                }
            }
    }

    private func publishSnapshot() async throws {
        try await publishSnapshot(forceRemoteStatusRefresh: false)
    }

    private func publishSnapshot(forceRemoteStatusRefresh: Bool) async throws {
        guard let cloudSyncService else { return }
        let snapshot = try await buildSnapshot(forceRemoteStatusRefresh: forceRemoteStatusRefresh)
        try await cloudSyncService.pushLocalSnapshot(snapshot)
    }

    @discardableResult
    private func processPendingCommandIfNeeded() async throws -> Bool {
        guard let cloudSyncService else { return false }
        guard let command = try await cloudSyncService.pullPendingCommand() else { return false }
        guard command.id != lastHandledCommandID else { return false }

        var executionResult = CommandExecutionResult.noRemoteStatusRefresh

        do {
            executionResult = try await execute(command)
            lastHandledCommandID = command.id
            lastCommandError = nil
        } catch {
            lastHandledCommandID = command.id
            lastCommandError = error.localizedDescription
        }

        try await publishSnapshot(forceRemoteStatusRefresh: executionResult.forceRemoteStatusRefresh)
        return true
    }

    private func buildSnapshot(forceRemoteStatusRefresh: Bool) async throws -> ProxyControlSnapshot {
        let settings = try await settingsCoordinator.currentSettings()
        let remoteStatuses = resolveRemoteStatuses(for: settings.remoteServers)
        if forceRemoteStatusRefresh {
            scheduleRemoteStatusRefreshIfNeeded(force: true)
        }
        let pair = await proxyCoordinator.loadStatus()
        let proxyStatus = pair.0
        let cloudflaredStatus = pair.1

        return ProxyControlSnapshot(
            syncedAt: dateProvider.unixMillisecondsNow(),
            sourceDeviceID: sourceDeviceID,
            proxyStatus: proxyStatus,
            preferredProxyPort: proxyStatus.port ?? RemoteServerConfiguration.defaultProxyPort,
            autoStartProxy: settings.autoStartApiProxy,
            cloudflaredStatus: cloudflaredStatus,
            cloudflaredTunnelMode: cloudflaredStatus.tunnelMode ?? .quick,
            cloudflaredNamedInput: NamedCloudflaredTunnelInput(
                apiToken: "",
                accountID: "",
                zoneID: "",
                hostname: cloudflaredStatus.customHostname ?? ""
            ),
            cloudflaredUseHTTP2: cloudflaredStatus.useHTTP2,
            publicAccessEnabled: cloudflaredStatus.running,
            remoteServers: settings.remoteServers,
            remoteStatusesSyncedAt: lastRemoteStatusRefreshAt,
            remoteStatuses: remoteStatuses,
            remoteLogs: remoteLogs,
            lastHandledCommandID: lastHandledCommandID,
            lastCommandError: lastCommandError
        )
    }

    private func resolveRemoteStatuses(
        for remoteServers: [RemoteServerConfig]
    ) -> [String: RemoteProxyStatus] {
        let serverIDs = Set(remoteServers.map(\.id))
        cachedRemoteStatuses = cachedRemoteStatuses.filter { serverIDs.contains($0.key) }
        return cachedRemoteStatuses
    }

    private func seedStateFromLatestSnapshotIfAvailable() async {
        guard let cloudSyncService else { return }
        do {
            guard let snapshot = try await cloudSyncService.pullRemoteSnapshot() else { return }
            cachedRemoteStatuses = snapshot.remoteStatuses
            remoteLogs = snapshot.remoteLogs
            lastHandledCommandID = snapshot.lastHandledCommandID
            lastCommandError = snapshot.lastCommandError
            lastRemoteStatusRefreshAt = snapshot.remoteStatusesSyncedAt
        } catch {
            #if DEBUG
            // print("Proxy control snapshot seed skipped:", error.localizedDescription)
            #endif
        }
    }

    private func scheduleRemoteStatusRefreshIfNeeded(force: Bool) {
        guard runtimePlatform == .macOS else { return }
        guard remoteStatusRefreshTask == nil else {
            if force {
                hasPendingForcedRemoteStatusRefresh = true
            }
            return
        }
        if !force, !isRemoteStatusRefreshDue() {
            return
        }

        remoteStatusRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRemoteStatusesInBackground()
        }
    }

    private func isRemoteStatusRefreshDue() -> Bool {
        guard let lastRemoteStatusRefreshAt else { return true }
        return dateProvider.unixMillisecondsNow() - lastRemoteStatusRefreshAt >= Constants.remoteStatusRefreshIntervalMilliseconds
    }

    private func refreshRemoteStatusesInBackground() async {
        defer {
            remoteStatusRefreshTask = nil
            if hasPendingForcedRemoteStatusRefresh {
                hasPendingForcedRemoteStatusRefresh = false
                scheduleRemoteStatusRefreshIfNeeded(force: true)
            }
        }

        do {
            let settings = try await settingsCoordinator.currentSettings()
            let previousStatuses = resolveRemoteStatuses(for: settings.remoteServers)
            let refreshSnapshot = await refreshRemoteStatuses(
                for: settings.remoteServers,
                startingWith: previousStatuses
            )
            cachedRemoteStatuses = refreshSnapshot.remoteStatuses
            lastRemoteStatusRefreshAt = refreshSnapshot.remoteStatusesSyncedAt
            guard refreshSnapshot.remoteStatuses != previousStatuses else { return }
            try await publishSnapshot()
        } catch {
            #if DEBUG
            // print("Proxy control remote status refresh skipped:", error.localizedDescription)
            #endif
        }
    }

    private func refreshRemoteStatuses(
        for remoteServers: [RemoteServerConfig],
        startingWith cachedStatuses: [String: RemoteProxyStatus]
    ) async -> RemoteStatusRefreshSnapshot {
        guard !remoteServers.isEmpty else {
            return RemoteStatusRefreshSnapshot(
                remoteStatusesSyncedAt: dateProvider.unixMillisecondsNow(),
                remoteStatuses: cachedStatuses
            )
        }

        let refreshedStatuses = await proxyCoordinator.remoteStatuses(for: remoteServers)
        var mergedStatuses = cachedStatuses
        for server in remoteServers {
            if let status = refreshedStatuses[server.id] {
                mergedStatuses[server.id] = status
            }
        }

        return RemoteStatusRefreshSnapshot(
            remoteStatusesSyncedAt: dateProvider.unixMillisecondsNow(),
            remoteStatuses: mergedStatuses
        )
    }

    private func execute(_ command: ProxyControlCommand) async throws -> CommandExecutionResult {
        switch command.kind {
        case .refreshStatus:
            scheduleRemoteStatusRefreshIfNeeded(force: true)
            return .noRemoteStatusRefresh
        case .startProxy:
            _ = try await proxyCoordinator.startProxy(preferredPort: command.preferredProxyPort)
            return .noRemoteStatusRefresh
        case .stopProxy:
            _ = await proxyCoordinator.stopProxy()
            return .noRemoteStatusRefresh
        case .refreshAPIKey:
            _ = try await proxyCoordinator.refreshAPIKey()
            return .noRemoteStatusRefresh
        case .setAutoStartProxy:
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(autoStartApiProxy: command.autoStartProxy ?? false)
            )
            return .noRemoteStatusRefresh
        case .installCloudflared:
            _ = try await proxyCoordinator.installCloudflared()
            return .noRemoteStatusRefresh
        case .startCloudflared:
            guard let input = command.cloudflaredInput else {
                throw AppError.invalidData("Missing cloudflared input.")
            }
            _ = try await proxyCoordinator.startCloudflared(input: input)
            return .noRemoteStatusRefresh
        case .stopCloudflared:
            _ = await proxyCoordinator.stopCloudflared()
            return .noRemoteStatusRefresh
        case .refreshCloudflared:
            _ = await proxyCoordinator.refreshCloudflared()
            return .noRemoteStatusRefresh
        case .addRemoteServer:
            let draft = command.remoteServer ?? RemoteServerConfiguration.makeDraft()
            let settings = try await settingsCoordinator.currentSettings()
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(
                    remoteServers: settings.remoteServers + [RemoteServerConfiguration.normalize(draft)]
                )
            )
            scheduleRemoteStatusRefreshIfNeeded(force: true)
            return .noRemoteStatusRefresh
        case .saveRemoteServer:
            guard let remoteServer = command.remoteServer else {
                throw AppError.invalidData("Missing remote server payload.")
            }
            let settings = try await settingsCoordinator.currentSettings()
            let merged = RemoteServerConfiguration.upsert(remoteServer, into: settings.remoteServers)
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(remoteServers: merged)
            )
            scheduleRemoteStatusRefreshIfNeeded(force: true)
            return .noRemoteStatusRefresh
        case .removeRemoteServer:
            guard let id = command.remoteServerID else {
                throw AppError.invalidData("Missing remote server id.")
            }
            let settings = try await settingsCoordinator.currentSettings()
            let merged = settings.remoteServers.filter { $0.id != id }
            _ = try await settingsCoordinator.updateSettings(
                AppSettingsPatch(remoteServers: merged)
            )
            remoteLogs.removeValue(forKey: id)
            cachedRemoteStatuses.removeValue(forKey: id)
            return .noRemoteStatusRefresh
        case .refreshRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = await proxyCoordinator.remoteStatus(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .deployRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.deployRemote(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .startRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.startRemote(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .stopRemote:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            cachedRemoteStatuses[server.id] = try await proxyCoordinator.stopRemote(server: server)
            lastRemoteStatusRefreshAt = dateProvider.unixMillisecondsNow()
            return .noRemoteStatusRefresh
        case .readRemoteLogs:
            guard let server = try await serverForCommand(command) else { return .noRemoteStatusRefresh }
            let logs = try await proxyCoordinator.readRemoteLogs(
                server: server,
                lines: command.logLines ?? 120
            )
            remoteLogs[server.id] = logs
            return .noRemoteStatusRefresh
        }
    }

    private func serverForCommand(_ command: ProxyControlCommand) async throws -> RemoteServerConfig? {
        guard let id = command.remoteServerID else {
            throw AppError.invalidData("Missing remote server id.")
        }
        let settings = try await settingsCoordinator.currentSettings()
        return settings.remoteServers.first(where: { $0.id == id })
    }
}
