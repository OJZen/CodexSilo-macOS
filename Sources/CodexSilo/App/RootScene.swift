import SwiftUI
import Combine
#if canImport(AppKit)
@preconcurrency import AppKit
#endif

struct RootScene: View {
    @State private var selectedTab: AppTab = .accounts
    @StateObject private var accountsModel: AccountsPageModel
    @StateObject private var proxyModel: ProxyPageModel
    @StateObject private var settingsModel: SettingsPageModel
    @ObservedObject private var trayModel: TrayMenuModel

    init(container: AppContainer, trayModel: TrayMenuModel) {
        _accountsModel = StateObject(wrappedValue: container.accountsModel)
        _proxyModel = StateObject(wrappedValue: container.proxyModel)
        _settingsModel = StateObject(wrappedValue: container.settingsModel)
        self.trayModel = trayModel
    }

    private var runtimeLocale: Locale {
        Locale(identifier: AppLocale.effectiveIdentifier(for: settingsModel.settings.locale))
    }

    private var currentTab: AppTab {
        selectedTab
    }

    private var currentNotice: NoticeMessage? {
        switch currentTab {
        case .accounts:
            return accountsModel.notice
        case .proxy:
            return proxyModel.notice
        case .settings:
            return settingsModel.notice
        }
    }

    var body: some View {
        detailContent
        .environment(\.locale, runtimeLocale)
        .toolbar {
            ToolbarItem(placement: .principal) {
                tabSwitcher
            }
        }
        .onAppear {
            L10n.setLocale(identifier: settingsModel.settings.locale)
        }
        .onChange(of: settingsModel.settings.locale) { _, value in
            L10n.setLocale(identifier: value)
        }
        .onReceive(trayModel.$accounts.removeDuplicates()) { accounts in
            accountsModel.syncFromBackgroundRefresh(accounts)
        }
        .onReceive(trayModel.$isFetchingRemoteUsage.removeDuplicates()) { isRefreshing in
            accountsModel.syncRemoteUsageRefreshActivity(isRefreshing: isRefreshing)
        }
        .task {
            await settingsModel.loadIfNeeded()
            await proxyModel.bootstrapOnAppLaunch(using: settingsModel.settings)
        }
        .animation(.easeInOut(duration: 0.2), value: currentNotice)
        .overlay(alignment: .bottom) {
            NoticeBanner(notice: currentNotice)
                .padding(.horizontal, LayoutRules.pagePadding)
                .padding(.bottom, 18)
                .allowsHitTesting(false)
                .zIndex(10)
        }
        .background {
            WindowSizeEnforcer(
                minWidth: LayoutRules.minimumWindowWidth,
                minHeight: LayoutRules.minimumWindowHeight,
                idealWidth: LayoutRules.defaultWindowWidth,
                idealHeight: LayoutRules.defaultWindowHeight
            )
            .frame(width: 0, height: 0)
            WindowActivationObserver {
                Task { @MainActor in
                    await accountsModel.refreshAccountsOnWindowPresentation()
                }
            }
            .frame(width: 0, height: 0)
        }
        .frame(
            minWidth: LayoutRules.minimumWindowWidth,
            maxWidth: .infinity,
            minHeight: LayoutRules.minimumWindowHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailContent: some View {
        activePage
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabSwitcher: some View {
        Picker("", selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                Text(tab.tabTitle)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .frame(maxWidth: LayoutRules.tabSwitcherMaxWidth)
    }

    @ViewBuilder
    private var activePage: some View {
        switch currentTab {
        case .accounts:
            AccountsPageView(model: accountsModel)
        case .proxy:
            ProxyPageView(model: proxyModel)
        case .settings:
            SettingsPageView(model: settingsModel)
        }
    }
}

private struct WindowSizeEnforcer: NSViewRepresentable {
    let minWidth: CGFloat
    let minHeight: CGFloat
    let idealWidth: CGFloat
    let idealHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(on: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(on: nsView.window)
        }
    }

    private func apply(on window: NSWindow?) {
        guard let window else { return }
        window.contentMinSize = NSSize(width: minWidth, height: minHeight)

        var targetSize = window.contentLayoutRect.size
        let clampedWidth = max(targetSize.width, minWidth)
        let clampedHeight = max(targetSize.height, minHeight)

        guard clampedWidth != targetSize.width || clampedHeight != targetSize.height else { return }
        targetSize.width = clampedWidth > 0 ? clampedWidth : idealWidth
        targetSize.height = clampedHeight > 0 ? clampedHeight : idealHeight
        window.setContentSize(targetSize)
    }
}

private struct WindowActivationObserver: NSViewRepresentable {
    let onWindowDidBecomeKey: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowActivationObserverView(frame: .zero)
        view.onWindowDidBecomeKey = onWindowDidBecomeKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observerView = nsView as? WindowActivationObserverView else { return }
        observerView.onWindowDidBecomeKey = onWindowDidBecomeKey
    }
}

private final class WindowActivationObserverView: NSView {
    var onWindowDidBecomeKey: (@MainActor () -> Void)?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToCurrentWindowIfNeeded()
    }

    private func attachToCurrentWindowIfNeeded() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )
        }

        guard let window else {
            observedWindow = nil
            return
        }
        guard observedWindow !== window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    @objc
    private func handleWindowDidBecomeKey(_ notification: Notification) {
        _ = notification
        Task { @MainActor in
            onWindowDidBecomeKey?()
        }
    }
}

private extension AppTab {
    var iconName: String {
        switch self {
        case .accounts: return "person.2"
        case .proxy: return "network"
        case .settings: return "gearshape"
        }
    }

    var tabTitle: String {
        switch self {
        case .accounts:
            return L10n.tr("tab.accounts")
        case .proxy:
            return L10n.tr("tab.proxy")
        case .settings:
            return L10n.tr("tab.settings")
        }
    }
}
