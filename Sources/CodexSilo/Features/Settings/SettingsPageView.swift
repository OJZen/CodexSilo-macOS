import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsPageView: View {
    @ObservedObject var model: SettingsPageModel
    @State private var transferDialogMode: SettingsTransferDialogMode?
    @State private var isShowingQuitConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
            pageHeader
                .padding(.horizontal, LayoutRules.pagePadding)

            Form {
                generalSection
                languageSection
                switchBehaviorSection
                dataTransferSection
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)
        }
        .padding(.top, LayoutRules.pageTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await model.loadIfNeeded()
        }
        .sheet(item: $transferDialogMode) { mode in
            SettingsDataTransferDialog(mode: mode, model: model)
                .frame(
                    minWidth: 640,
                    minHeight: mode == .exportArchive ? 460 : 420
                )
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: LayoutRules.listRowSpacing) {
            Text(L10n.tr("tab.settings"))
                .font(.largeTitle.weight(.semibold))

            Spacer(minLength: 0)

            Button(role: .destructive) {
                isShowingQuitConfirmation = true
            } label: {
                Label("common.quit", systemImage: "power")
                    .lineLimit(1)
            }
            .codexsiloActionButtonStyle(tint: .red)
        }
        .alert(
            L10n.tr("settings.quit_confirmation_title"),
            isPresented: $isShowingQuitConfirmation
        ) {
            Button(L10n.tr("common.close"), role: .cancel) {}
            Button(L10n.tr("common.quit"), role: .destructive) {
                quitApp()
            }
        } message: {
            Text(L10n.tr("settings.quit_confirmation_message"))
        }
    }

    private var generalSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.launchAtStartup },
                set: { model.setLaunchAtStartup($0) }
            )) {
                Label("settings.launch_at_startup", systemImage: "power.circle")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { model.settings.launchCodexAfterSwitch },
                set: { model.setLaunchAfterSwitch($0) }
            )) {
                Label("settings.launch_codex_after_switch", systemImage: "terminal")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { model.settings.autoRefreshAccounts },
                set: { model.setAutoRefreshAccounts($0) }
            )) {
                Label("settings.auto_refresh_accounts", systemImage: "arrow.clockwise")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { model.settings.autoStartApiProxy },
                set: { model.setAutoStartProxy($0) }
            )) {
                Label("settings.auto_start_api_proxy", systemImage: "network")
            }
            .toggleStyle(.switch)
        } header: {
            Label(L10n.tr("settings.section.general"), systemImage: "slider.horizontal.3")
        }
    }

    private var switchBehaviorSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.autoSmartSwitch },
                set: { model.setAutoSmartSwitch($0) }
            )) {
                Label("settings.auto_smart_switch", systemImage: "sparkles")
            }
            .toggleStyle(.switch)
        } header: {
            Label(L10n.tr("settings.section.switch_behavior"), systemImage: "arrow.left.arrow.right.circle")
        }
    }

    private var languageSection: some View {
        Section {
            Picker(selection: Binding(
                get: { AppLocale.resolve(model.settings.locale) },
                set: { model.setLocale($0.identifier) }
            )) {
                ForEach(AppLocale.allCases) { locale in
                    Text(L10n.tr(locale.displayNameKey)).tag(locale)
                }
            } label: {
                Label("settings.language", systemImage: "globe")
            }
            .pickerStyle(.menu)
        } header: {
            Label(L10n.tr("settings.section.language"), systemImage: "globe")
        }
    }

    private var dataTransferSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("settings.transfer.description"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        exportButton
                        importButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        exportButton
                        importButton
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label(L10n.tr("settings.section.data_transfer"), systemImage: "lock.document")
        }
    }

    private var exportButton: some View {
        Button {
            transferDialogMode = .exportArchive
        } label: {
            Label(L10n.tr("settings.transfer.export"), systemImage: "square.and.arrow.up")
                .lineLimit(1)
        }
        .codexsiloActionButtonStyle(prominent: true)
    }

    private var importButton: some View {
        Button {
            transferDialogMode = .importArchive
        } label: {
            Label(L10n.tr("settings.transfer.import"), systemImage: "square.and.arrow.down")
                .lineLimit(1)
        }
        .codexsiloActionButtonStyle()
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }
}

private enum SettingsTransferDialogMode: String, Identifiable {
    case exportArchive
    case importArchive

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .exportArchive:
            return "settings.transfer.export_title"
        case .importArchive:
            return "settings.transfer.import_title"
        }
    }

    var messageKey: String {
        switch self {
        case .exportArchive:
            return "settings.transfer.export_message"
        case .importArchive:
            return "settings.transfer.import_message"
        }
    }

    var pathLabelKey: String {
        switch self {
        case .exportArchive:
            return "settings.transfer.export_path"
        case .importArchive:
            return "settings.transfer.import_file"
        }
    }

    var choosePathKey: String {
        switch self {
        case .exportArchive:
            return "settings.transfer.choose_export_path"
        case .importArchive:
            return "settings.transfer.choose_import_file"
        }
    }

    var actionKey: String {
        switch self {
        case .exportArchive:
            return "settings.transfer.export_action"
        case .importArchive:
            return "settings.transfer.import_action"
        }
    }

    var systemImage: String {
        switch self {
        case .exportArchive:
            return "square.and.arrow.up"
        case .importArchive:
            return "square.and.arrow.down"
        }
    }

    var requiresPasswordConfirmation: Bool {
        self == .exportArchive
    }
}

private struct SettingsDataTransferDialog: View {
    private static let archiveContentType = UTType(filenameExtension: AccountsDataTransferCodec.archiveFileExtension) ?? .data

    let mode: SettingsTransferDialogMode
    @ObservedObject var model: SettingsPageModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedURL: URL?
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.tr(mode.messageKey))
                        .font(.body)
                        .foregroundStyle(.primary)

                    if mode == .importArchive {
                        importWarning
                    }

                    pathSection
                    passwordSection

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button(L10n.tr("common.close")) {
                    dismiss()
                }
                .codexsiloActionButtonStyle()
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button {
                    submit()
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: mode.systemImage)
                        }
                        Text(L10n.tr(mode.actionKey))
                    }
                    .lineLimit(1)
                }
                .codexsiloActionButtonStyle(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Label(L10n.tr(mode.titleKey), systemImage: mode.systemImage)
                .font(.title2.weight(.semibold))
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var importWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            Text(L10n.tr("settings.transfer.import_warning"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .cardSurface(cornerRadius: 12, tint: .orange)
    }

    private var pathSection: some View {
        SectionCard(title: L10n.tr(mode.pathLabelKey)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(selectedURL?.path ?? L10n.tr("settings.transfer.no_path_selected"))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(selectedURL == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    selectPath()
                } label: {
                    Label(L10n.tr(mode.choosePathKey), systemImage: "folder")
                        .lineLimit(1)
                }
                .codexsiloActionButtonStyle()
            }
        }
    }

    private var passwordSection: some View {
        SectionCard(title: L10n.tr("settings.transfer.password")) {
            VStack(alignment: .leading, spacing: 12) {
                SecureField(L10n.tr("settings.transfer.password"), text: $password)
                    .textFieldStyle(.roundedBorder)

                if mode.requiresPasswordConfirmation {
                    SecureField(L10n.tr("settings.transfer.confirm_password"), text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func submit() {
        if let validationMessage = validationMessage() {
            errorMessage = validationMessage
            return
        }

        guard let selectedURL else { return }
        let password = password
        errorMessage = nil
        isSubmitting = true

        Task { @MainActor in
            let failureMessage: String?
            switch mode {
            case .exportArchive:
                failureMessage = await model.exportAccountData(to: selectedURL, password: password)
            case .importArchive:
                failureMessage = await model.importAccountData(from: selectedURL, password: password)
            }

            isSubmitting = false
            if let failureMessage {
                errorMessage = failureMessage
            } else {
                dismiss()
            }
        }
    }

    private func validationMessage() -> String? {
        if selectedURL == nil {
            return L10n.tr(
                mode == .exportArchive
                    ? "error.transfer.export_path_required"
                    : "error.transfer.import_file_required"
            )
        }
        if password.isEmpty {
            return L10n.tr("error.transfer.password_required")
        }
        if mode.requiresPasswordConfirmation, password != confirmPassword {
            return L10n.tr("error.transfer.password_mismatch")
        }
        return nil
    }

    private func selectPath() {
        switch mode {
        case .exportArchive:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.archiveContentType]
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.nameFieldStringValue = Self.defaultExportFileName()
            panel.isExtensionHidden = false
            if panel.runModal() == .OK {
                selectedURL = panel.url
            }
        case .importArchive:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [Self.archiveContentType]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            if panel.runModal() == .OK {
                selectedURL = panel.url
            }
        }
    }

    private static func defaultExportFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "CodexSilo-accounts-\(formatter.string(from: Date())).\(AccountsDataTransferCodec.archiveFileExtension)"
    }
}
