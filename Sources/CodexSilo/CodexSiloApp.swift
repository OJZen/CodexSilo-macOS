import SwiftUI
import CloudKit
#if canImport(AppKit)
import AppKit
#endif

@main
struct CodexSiloApp: App {
    private enum SceneID {
        static let mainWindow = "codexsilo.main-window"
    }

    private let container: AppContainer
    private let mainWindowController: MainWindowController
    @StateObject private var trayModel: TrayMenuModel
    @NSApplicationDelegateAdaptor(CodexSiloAppDelegate.self) private var appDelegate

    init() {
        let container = AppContainer.liveOrCrash()
        let mainWindowController = MainWindowController(
            contentView: RootScene(container: container, trayModel: container.trayModel),
            onWindowDidBecomeKey: { [accountsModel = container.accountsModel] in
                await accountsModel.refreshAccountsOnWindowPresentation()
            }
        )
        self.container = container
        _trayModel = StateObject(wrappedValue: container.trayModel)
        self.mainWindowController = mainWindowController
        Task { @MainActor in
            mainWindowController.showWindow()
            container.trayModel.startBackgroundRefresh()
            await container.proxyControlBridge.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Button("打开主页面") {
                mainWindowController.showWindow()
            }

            Divider()

            Button("退出", role: .destructive) {
                NSApp.terminate(nil)
            }
        } label: {
            menuBarIcon
        }
    }

    private var menuBarIcon: Image {
        if let icon = makeMenuBarSymbolImage() {
            return Image(nsImage: icon)
        }
        return Image(systemName: "figure.pool.swim")
    }

    private func makeMenuBarSymbolImage() -> NSImage? {
        guard let base = NSImage(systemSymbolName: "figure.pool.swim", accessibilityDescription: "CodexSilo") else {
            return nil
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .black, scale: .large)
        let configured = base.withSymbolConfiguration(symbolConfig) ?? base

        let canvasSize = NSSize(width: 18, height: 18)
        let symbolSize = configured.size
        guard symbolSize.width > 0, symbolSize.height > 0 else {
            configured.isTemplate = true
            return configured
        }

        // Keep aspect ratio while slightly enlarging to improve optical size.
        let fitScale = min(canvasSize.width / symbolSize.width, canvasSize.height / symbolSize.height) * 1.08
        let drawSize = NSSize(width: symbolSize.width * fitScale, height: symbolSize.height * fitScale)
        let drawRect = NSRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        configured.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }
}

@MainActor
private final class CodexSiloAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.registerForRemoteNotifications()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return false
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        _ = application
        _ = deviceToken
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        _ = application
        handleRemoteNotification(userInfo)
    }
}

@MainActor
private final class MainWindowController: NSObject, NSWindowDelegate {
    private let contentView: RootScene
    private let onWindowDidBecomeKey: @MainActor () async -> Void
    private var window: NSWindow?

    init(
        contentView: RootScene,
        onWindowDidBecomeKey: @escaping @MainActor () async -> Void = {}
    ) {
        self.contentView = contentView
        self.onWindowDidBecomeKey = onWindowDidBecomeKey
    }

    func showWindow() {
        let window = makeWindowIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        _ = notification
        Task { @MainActor [onWindowDidBecomeKey] in
            await onWindowDidBecomeKey()
        }
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: LayoutRules.defaultWindowWidth,
                height: LayoutRules.defaultWindowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = "CodexSilo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("codexsilo.main-window")
        window.center()
        window.contentMinSize = NSSize(
            width: LayoutRules.minimumWindowWidth,
            height: LayoutRules.minimumWindowHeight
        )
        window.contentViewController = hostingController
        self.window = window
        return window
    }
}

@discardableResult
private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    let payload = userInfo.reduce(into: [String: Any]()) { partialResult, entry in
        if let key = entry.key as? String {
            partialResult[key] = entry.value
        }
    }

    guard let notification = CKNotification(fromRemoteNotificationDictionary: payload) else {
        return false
    }

    if notification.subscriptionID == CloudKitCurrentAccountSelectionSyncService.pushSubscriptionID {
        NotificationCenter.default.post(name: .codexsiloCurrentAccountSelectionPushDidArrive, object: nil)
        return true
    }

    if notification.subscriptionID == CloudKitAccountsSyncService.pushSubscriptionID {
        NotificationCenter.default.post(name: .codexsiloAccountsSnapshotPushDidArrive, object: nil)
        return true
    }

    if notification.subscriptionID == CloudKitProxyControlSyncService.pushSubscriptionID {
        NotificationCenter.default.post(name: .codexsiloProxyControlPushDidArrive, object: nil)
        return true
    }

    return false
}
