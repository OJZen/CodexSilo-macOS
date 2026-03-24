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
            let chatGPTOAuthLoginService = OpenAIChatGPTOAuthLoginService(configPath: paths.codexConfigPath)
            let launchAtStartupService = LaunchAtStartupService()

            let settingsCoordinator = SettingsCoordinator(
                storeRepository: storeRepository,
                authRepository: authRepository,
                launchAtStartupService: launchAtStartupService
            )
            let accountsCoordinator = AccountsCoordinator(
                storeRepository: storeRepository,
                authRepository: authRepository,
                usageService: usageService,
                workspaceMetadataService: workspaceMetadataService,
                chatGPTOAuthLoginService: chatGPTOAuthLoginService,
            )
            let initialAccounts = initialStore.accountSummaries(
                currentAccountKey: authRepository.currentAuthAccountKey(),
                currentVariantKey: authRepository.currentAuthVariantKey()
            )
            let proxyCoordinator = ProxyCoordinator(proxyService: proxyService)
            let trayModel = TrayMenuModel(
                accountsCoordinator: accountsCoordinator,
                settingsCoordinator: settingsCoordinator,
                cloudSyncService: nil,
                currentAccountSelectionSyncService: nil,
                backgroundRefreshPolicy: .forPlatform(PlatformCapabilities.currentPlatform),
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
                initialAccounts: initialAccounts,
                initialOverviewCollapsed: initialStore.accountsOverviewCollapsed
            )
            let proxyModel = ProxyPageModel(
                coordinator: proxyCoordinator,
                settingsCoordinator: settingsCoordinator
            )
            let settingsModel = SettingsPageModel(
                settingsCoordinator: settingsCoordinator,
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
                    // Keep launch non-blocking even if system login item sync fails.
                }
            }

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
