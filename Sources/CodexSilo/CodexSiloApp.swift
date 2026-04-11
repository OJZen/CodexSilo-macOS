import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

private enum CodexSiloSceneID {
    static let mainWindow = "codexsilo.main-window"
}

@main
struct CodexSiloApp: App {
    private let container: AppContainer
    private let mainWindowController: MainWindowController
    @StateObject private var trayModel: TrayMenuModel
    @NSApplicationDelegateAdaptor(CodexSiloAppDelegate.self) private var appDelegate

    init() {
        let container = AppContainer.liveOrCrash()
        let mainWindowController = MainWindowController(
            contentView: RootScene(container: container, trayModel: container.trayModel)
        )
        self.container = container
        self.mainWindowController = mainWindowController
        _trayModel = StateObject(wrappedValue: container.trayModel)
        CodexSiloAppDelegate.showMainWindow = { [mainWindowController] in
            mainWindowController.showWindow()
        }
        Task { @MainActor in
            container.trayModel.startBackgroundRefresh()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            TrayMenuContentView(
                trayModel: trayModel,
                onOpenMainWindow: {
                    mainWindowController.showWindow()
                }
            )
            .id(trayMenuContentIdentity)
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: Image {
        if let icon = makeMenuBarTemplateImage() {
            return Image(nsImage: icon)
        }
        return Image(systemName: "curlybraces")
    }

    private var trayMenuContentIdentity: String {
        trayModel.accounts.map { account in
            let fiveHour = Int((account.usage?.fiveHour?.usedPercent ?? -1).rounded())
            let oneWeek = Int((account.usage?.oneWeek?.usedPercent ?? -1).rounded())
            return "\(account.id)|\(account.isCurrent)|\(account.updatedAt)|\(fiveHour)|\(oneWeek)"
        }
        .joined(separator: ";")
    }

    private func makeMenuBarTemplateImage() -> NSImage? {
        guard
            let resourceURL = Bundle.main.url(forResource: "icon", withExtension: "svg"),
            let base = NSImage(contentsOf: resourceURL)
        else {
            return nil
        }

        let canvasSize = NSSize(width: 18, height: 18)
        let baseSize = base.size
        guard baseSize.width > 0, baseSize.height > 0 else {
            base.isTemplate = true
            return base
        }

        // Preserve the SVG proportions while keeping a little breathing room in the menu bar.
        let fitScale = min(canvasSize.width / baseSize.width, canvasSize.height / baseSize.height) * 0.9
        let drawSize = NSSize(width: baseSize.width * fitScale, height: baseSize.height * fitScale)
        let drawRect = NSRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        base.draw(
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

private struct TrayMenuContentView: View {
    @ObservedObject var trayModel: TrayMenuModel
    let onOpenMainWindow: () -> Void

    private var displayedAccounts: [AccountSummary] {
        let current = trayModel.accounts.filter(\.isCurrent)
        let others = trayModel.accounts.filter { !$0.isCurrent }
        return current + others
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            trayActionButton(title: "显示主页面", systemImage: "macwindow") {
                onOpenMainWindow()
            }

            Divider()

            if trayModel.accounts.isEmpty {
                Text(L10n.tr("tray.no_accounts"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(displayedAccounts) { account in
                        TrayMenuAccountButton(
                            account: account,
                            onSwitch: {
                                Task {
                                    await trayModel.switchAccount(id: account.id)
                                }
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            trayActionButton(
                title: L10n.tr("common.quit"),
                systemImage: "power",
                role: .destructive,
                action: { NSApp.terminate(nil) }
            )
        }
        .padding(10)
        .frame(width: 312)
        .onAppear {
            Task {
                await trayModel.handleTrayMenuPresentation()
            }
        }
    }

    private func trayActionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(role == .destructive ? Color.red.opacity(0.08) : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct TrayMenuAccountButton: View {
    let account: AccountSummary
    let onSwitch: () -> Void

    var body: some View {
        Button {
            guard !account.isCurrent else { return }
            onSwitch()
        } label: {
            content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(account.isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(account.isCurrent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.14), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if account.isCurrent {
            currentAccountContent
        } else {
            compactAccountContent
        }
    }

    private var currentAccountContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(account.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("✅")
                    .font(.system(size: 12))
            }

            if let email = trimmedEmail {
                Text(email)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 5) {
                usageProgressRow(
                    title: L10n.tr("accounts.window.five_hour"),
                    remainingText: remainingText(for: account.usage?.fiveHour),
                    progress: remainingFraction(for: account.usage?.fiveHour)
                )
                usageProgressRow(
                    title: L10n.tr("accounts.window.one_week"),
                    remainingText: remainingText(for: account.usage?.oneWeek),
                    progress: remainingFraction(for: account.usage?.oneWeek)
                )
            }
            .padding(.top, 1)
        }
    }

    private var compactAccountContent: some View {
        HStack(spacing: 8) {
            Text(account.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            usageBadge(
                title: L10n.tr("accounts.window.five_hour"),
                value: remainingText(for: account.usage?.fiveHour),
                progress: remainingFraction(for: account.usage?.fiveHour)
            )

            usageBadge(
                title: L10n.tr("accounts.window.one_week"),
                value: remainingText(for: account.usage?.oneWeek),
                progress: remainingFraction(for: account.usage?.oneWeek)
            )
        }
    }

    private var trimmedEmail: String? {
        guard let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return nil
        }
        return email
    }

    private func usageBadge(title: String, value: String, progress: Double?) -> some View {
        let color = statusColor(for: progress)

        return HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(progress == nil ? 0.08 : 0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(progress == nil ? 0.12 : 0.22), lineWidth: 1)
        )
    }

    private func usageProgressRow(
        title: String,
        remainingText: String,
        progress: Double?
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            ProgressView(value: progress ?? 0)
                .progressViewStyle(.linear)
                .tint(statusColor(for: progress))
                .scaleEffect(x: 1, y: 0.7, anchor: .center)

            Text(remainingText)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func remainingText(for window: UsageWindow?) -> String {
        guard let remaining = remainingPercent(for: window) else { return "--" }
        return "\(Int(remaining.rounded()))%"
    }

    private func remainingPercent(for window: UsageWindow?) -> Double? {
        guard let window else { return nil }
        return max(0, 100 - window.usedPercent)
    }

    private func remainingFraction(for window: UsageWindow?) -> Double? {
        guard let remaining = remainingPercent(for: window) else { return nil }
        return remaining / 100
    }

    private func statusColor(for progress: Double?) -> Color {
        guard let progress else { return .secondary }
        switch progress {
        case ..<0.2:
            return .red
        case ..<0.5:
            return .orange
        default:
            return .green
        }
    }
}

@MainActor
private final class CodexSiloAppDelegate: NSObject, NSApplicationDelegate {
    static var showMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApplication.shared.setActivationPolicy(.regular)
        Self.showMainWindow?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        _ = sender
        if !flag {
            Self.showMainWindow?()
        }
        return true
    }
}

@MainActor
private final class MainWindowController: NSObject {
    private let contentView: RootScene
    private var window: NSWindow?

    init(contentView: RootScene) {
        self.contentView = contentView
    }

    func showWindow() {
        let window = makeWindowIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        window.isReleasedWhenClosed = false
        window.title = "CodexSilo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setFrameAutosaveName(CodexSiloSceneID.mainWindow)
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
