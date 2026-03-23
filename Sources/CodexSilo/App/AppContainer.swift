import Foundation

@MainActor
struct AppContainer {
    let accountsModel: AccountsPageModel
    let proxyModel: ProxyPageModel
    let settingsModel: SettingsPageModel
    let trayModel: TrayMenuModel
    let proxyControlBridge: ProxyControlBridge

    static func liveOrCrash() -> AppContainer {
        do {
            let paths = try FileSystemPaths.live()
            let storeRepository = StoreFileRepository(paths: paths)
            let authRepository = AuthFileRepository(paths: paths)
            let initialStore = try storeRepository.loadStore()
            let usageService = DefaultUsageService(configPath: paths.codexConfigPath)
            let workspaceMetadataService = DefaultWorkspaceMetadataService(configPath: paths.codexConfigPath)
            let proxyService = SwiftNativeProxyRuntimeService(
                paths: paths,
                storeRepository: storeRepository,
                authRepository: authRepository
            )
            let remoteService = RemoteProxyService(
                repoRoot: RepositoryLocator.findRepoRoot(startingAt: URL(fileURLWithPath: #filePath)),
                sourceAccountStorePath: paths.accountStorePath,
                sourceAuthPath: paths.codexAuthPath
            )
            let chatGPTOAuthLoginService = OpenAIChatGPTOAuthLoginService(configPath: paths.codexConfigPath)
            let codexCLIService = CodexCLIService()
            let launchAtStartupService = LaunchAtStartupService()

            let settingsCoordinator = SettingsCoordinator(
                storeRepository: storeRepository,
                launchAtStartupService: launchAtStartupService
            )
            let accountsCoordinator = AccountsCoordinator(
                storeRepository: storeRepository,
                authRepository: authRepository,
                usageService: usageService,
                workspaceMetadataService: workspaceMetadataService,
                chatGPTOAuthLoginService: chatGPTOAuthLoginService,
                codexCLIService: codexCLIService
            )
            let initialAccounts = initialStore.accountSummaries(
                currentAccountKey: authRepository.currentAuthAccountKey(),
                currentVariantKey: authRepository.currentAuthVariantKey()
            )
            let proxyCoordinator = ProxyCoordinator(
                proxyService: proxyService,
                remoteService: remoteService
            )
            let proxyControlBridge = ProxyControlBridge(
                proxyCoordinator: proxyCoordinator,
                settingsCoordinator: settingsCoordinator,
                cloudSyncService: nil
            )
            let trayModel = TrayMenuModel(
                accountsCoordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                cloudSyncService: nil,
                currentAccountSelectionSyncService: nil,
                backgroundRefreshPolicy: .forPlatform(PlatformCapabilities.currentPlatform),
                initialAccounts: initialAccounts
            )
            let settingsModel = SettingsPageModel(
                settingsCoordinator: settingsCoordinator,
                onSettingsUpdated: { settings in
                    trayModel.applySettings(settings)
                }
            )
            trayModel.applySettings(initialStore.settings)

            Task {
                do {
                    try await settingsCoordinator.syncLaunchAtStartupFromStore()
                } catch {
                    // Keep launch non-blocking even if system login item sync fails.
                }
            }

            return AppContainer(
                accountsModel: AccountsPageModel(
                    coordinator: accountsCoordinator,
                    manualRefreshService: trayModel,
                    localAccountsMutationSyncService: trayModel,
                    currentAccountSelectionSyncService: nil,
                    onLocalAccountsChanged: { accounts in
                        trayModel.acceptLocalAccountsSnapshot(accounts)
                    },
                    initialAccounts: initialAccounts,
                    initialOverviewCollapsed: initialStore.accountsOverviewCollapsed
                ),
                proxyModel: ProxyPageModel(
                    coordinator: proxyCoordinator,
                    settingsCoordinator: settingsCoordinator,
                    proxyControlCloudSyncService: nil,
                    localProxyCommandService: proxyControlBridge
                ),
                settingsModel: settingsModel,
                trayModel: trayModel,
                proxyControlBridge: proxyControlBridge
            )
        } catch {
            fatalError("Failed to bootstrap Swift migration app: \(error.localizedDescription)")
        }
    }
}
