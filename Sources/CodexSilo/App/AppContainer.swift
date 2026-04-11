import Foundation

@MainActor
struct AppContainer {
    let accountsModel: AccountsPageModel
    let proxyModel: ProxyPageModel
    let settingsModel: SettingsPageModel
    let trayModel: TrayMenuModel

    static func liveOrCrash() -> AppContainer {
        do {
            let paths = try FileSystemPaths.live()
            let logger = FileAppLogger(paths: paths)
            logger.info(
                category: .app,
                event: "bootstrap_started",
                message: "Bootstrapping application container."
            )
            let storeRepository = StoreFileRepository(paths: paths, logger: logger)
            let authRepository = AuthFileRepository(paths: paths, logger: logger)
            let localAuthFileMonitor = LocalFileMonitorService(monitoredFilePath: paths.codexAuthPath)
            let localConfigFileMonitor = LocalFileMonitorService(monitoredFilePath: paths.codexConfigPath)
            let initialStore = try storeRepository.loadStore()
            let usageService = DefaultUsageService(configPath: paths.codexConfigPath, logger: logger)
            let workspaceMetadataService = DefaultWorkspaceMetadataService(
                configPath: paths.codexConfigPath,
                logger: logger
            )
            let proxyService = SwiftNativeProxyRuntimeService(
                paths: paths,
                storeRepository: storeRepository,
                authRepository: authRepository,
                logger: logger
            )
            let chatGPTOAuthLoginService = OpenAIChatGPTOAuthLoginService(
                configPath: paths.codexConfigPath,
                logger: logger
            )
            let launchAtStartupService = LaunchAtStartupService(logger: logger)

            let settingsCoordinator = SettingsCoordinator(
                storeRepository: storeRepository,
                authRepository: authRepository,
                launchAtStartupService: launchAtStartupService,
                logger: logger
            )
            let accountsCoordinator = AccountsCoordinator(
                storeRepository: storeRepository,
                authRepository: authRepository,
                usageService: usageService,
                workspaceMetadataService: workspaceMetadataService,
                chatGPTOAuthLoginService: chatGPTOAuthLoginService,
                logger: logger
            )
            let initialAccounts = initialStore.accountSummaries(
                currentAccountKey: authRepository.currentAuthAccountKey(),
                currentVariantKey: authRepository.currentAuthVariantKey()
            )
            let proxyCoordinator = ProxyCoordinator(
                proxyService: proxyService,
                storeRepository: storeRepository,
                logger: logger
            )
            let trayModel = TrayMenuModel(
                accountsCoordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                localAuthFileMonitor: localAuthFileMonitor,
                localConfigFileMonitor: localConfigFileMonitor,
                cloudSyncService: nil,
                currentAccountSelectionSyncService: nil,
                backgroundRefreshPolicy: .forPlatform(PlatformCapabilities.currentPlatform),
                logger: logger,
                initialAccounts: initialAccounts
            )
            let accountsModel = AccountsPageModel(
                coordinator: accountsCoordinator,
                manualRefreshService: trayModel,
                localAccountsMutationSyncService: trayModel,
                currentAccountSelectionSyncService: nil,
                onLocalAccountsChanged: { accounts in
                    trayModel.acceptLocalAccountsSnapshot(accounts)
                },
                logger: logger,
                initialAccounts: initialAccounts,
                initialOverviewCollapsed: initialStore.accountsOverviewCollapsed
            )
            let proxyModel = ProxyPageModel(
                coordinator: proxyCoordinator,
                settingsCoordinator: settingsCoordinator,
                logger: logger
            )
            let settingsModel = SettingsPageModel(
                settingsCoordinator: settingsCoordinator,
                appLogger: logger,
                onSettingsUpdated: { settings in
                    trayModel.applySettings(settings)
                },
                onStoreImported: { importedStore in
                    trayModel.applySettings(importedStore.settings)
                    trayModel.acceptLocalAccountsSnapshot(
                        importedStore.accountSummaries(
                            currentAccountKey: authRepository.currentAuthAccountKey(),
                            currentVariantKey: authRepository.currentAuthVariantKey()
                        )
                    )
                    await accountsModel.load()
                    await proxyModel.load()
                }
            )
            trayModel.applySettings(initialStore.settings)

            Task {
                do {
                    try await settingsCoordinator.syncLaunchAtStartupFromStore()
                } catch {
                    logger.error(
                        category: .app,
                        event: "bootstrap_launch_at_startup_sync_failed",
                        message: "Launch-at-startup sync failed during bootstrap.",
                        metadata: ["error": error.localizedDescription]
                    )
                    // Keep launch non-blocking even if system login item sync fails.
                }
            }

            logger.info(
                category: .app,
                event: "bootstrap_succeeded",
                message: "Application container bootstrapped successfully.",
                metadata: [
                    "accounts": String(initialAccounts.count),
                    "auto_refresh_accounts": initialStore.settings.autoRefreshAccounts ? "true" : "false"
                ]
            )

            return AppContainer(
                accountsModel: accountsModel,
                proxyModel: proxyModel,
                settingsModel: settingsModel,
                trayModel: trayModel
            )
        } catch {
            fatalError("Failed to bootstrap Swift migration app: \(error.localizedDescription)")
        }
    }
}
