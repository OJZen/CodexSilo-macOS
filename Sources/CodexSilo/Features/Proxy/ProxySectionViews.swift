import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ApiProxySectionView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        SectionCard(title: L10n.tr("proxy.section.api_proxy")) {
            VStack(alignment: .leading, spacing: LayoutRules.proxyDetailCardSpacing) {
                proxyHeroContent
                proxyDetailGroup
            }
        }
    }

    private var proxyHeroContent: some View {
        proxyPanel {
            VStack(alignment: .leading, spacing: LayoutRules.proxySectionSpacing) {
                proxyMetricStrip
                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: LayoutRules.proxySectionSpacing) {
                        preferredPortEditor
                        Spacer(minLength: 0)
                        actionBar
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        preferredPortEditor
                        actionBar
                    }
                }

                Toggle(isOn: Binding(
                    get: { model.autoStartProxy },
                    set: { value in
                        Task { await model.setAutoStartProxy(value) }
                    }
                )) {
                    Text("proxy.start_on_launch")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
            }
        }
    }

    private var proxyDetailGroup: some View {
        proxyPanel {
            VStack(alignment: .leading, spacing: 12) {
                ProxyValueRow(
                    title: L10n.tr("proxy.detail.base_url"),
                    value: model.proxyStatus.baseURL ?? L10n.tr("proxy.value.generated_after_start"),
                    canCopy: model.proxyStatus.baseURL != nil
                )

                Divider()

                ProxyValueRow(
                    title: L10n.tr("proxy.detail.api_key"),
                    value: model.proxyStatus.apiKey ?? L10n.tr("proxy.value.generated_after_first_start"),
                    canCopy: model.proxyStatus.apiKey != nil
                ) {
                    Button {
                        Task { await model.refreshAPIKey() }
                    } label: {
                        Label("common.refresh", systemImage: "arrow.clockwise")
                    }
                    .codexsiloActionButtonStyle()
                    .disabled(model.loading)
                }

                Divider()

                ProxyDetailRow(
                    title: L10n.tr("proxy.detail.active_routed_account"),
                    headline: model.proxyStatus.activeAccountLabel ?? L10n.tr("proxy.info.no_request_matched"),
                    detailText: model.proxyStatus.activeAccountID ?? L10n.tr("proxy.info.active_account_hint")
                )

                Divider()

                ProxyDetailRow(
                    title: L10n.tr("proxy.detail.last_error"),
                    headline: model.proxyStatus.lastError ?? L10n.tr("common.none"),
                    detailText: ""
                )
            }
        }
    }

    private var proxyMetricStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LayoutRules.proxyMetricChipSpacing) {
                statusChip
                metricChip(text: L10n.tr("proxy.port_line_format", model.proxyStatus.port.map(String.init) ?? "--"))
                metricChip(text: L10n.tr("proxy.available_accounts_format", String(model.proxyStatus.availableAccounts)))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: LayoutRules.proxyMetricChipSpacing) {
                statusChip
                metricChip(text: L10n.tr("proxy.port_line_format", model.proxyStatus.port.map(String.init) ?? "--"))
                metricChip(text: L10n.tr("proxy.available_accounts_format", String(model.proxyStatus.availableAccounts)))
            }
        }
    }

    private var statusChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.proxyStatus.running ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            Text(model.proxyStatus.running ? L10n.tr("proxy.status.running") : L10n.tr("proxy.status.stopped"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, LayoutRules.proxyMetricChipHorizontalPadding)
        .padding(.vertical, LayoutRules.proxyMetricChipVerticalPadding)
        .frostedRoundedSurface(cornerRadius: 999, tint: model.proxyStatus.running ? .green : nil)
    }

    private func metricChip(text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, LayoutRules.proxyMetricChipHorizontalPadding)
            .padding(.vertical, LayoutRules.proxyMetricChipVerticalPadding)
            .frostedRoundedSurface(cornerRadius: 999)
    }

    private var preferredPortEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("proxy.port_line_format", "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("8787", text: $model.preferredPortText)
                .frostedRoundedInput()
                .frame(width: LayoutRules.proxyHeroPortFieldWidth)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("proxy.action.refresh_status") {
                Task { await model.refreshStatus() }
            }
            .liquidGlassActionButtonStyle(density: .compact)
            .disabled(model.loading)

            if model.proxyStatus.running {
                Button("proxy.action.stop_api_proxy", role: .destructive) {
                    Task { await model.stopProxy() }
                }
                .liquidGlassActionButtonStyle(prominent: true, tint: .red, density: .compact)
                .disabled(model.loading)
            } else {
                Button("proxy.action.start_api_proxy") {
                    Task { await model.startProxy() }
                }
                .liquidGlassActionButtonStyle(prominent: true, density: .compact)
                .disabled(model.loading)
            }
        }
    }

    private func proxyPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(LayoutRules.proxyPanelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedRoundedSurface(cornerRadius: 12)
    }
}

struct RemoteServersSectionView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        SectionCard(
            title: L10n.tr("proxy.section.remote_servers"),
            headerTrailing: {
                Button("proxy.action.add_server") {
                    Task { await model.addRemoteServer() }
                }
                .liquidGlassActionButtonStyle(prominent: true)
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("proxy.remote.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.remoteServers.isEmpty {
                    EmptyStateView(
                        title: L10n.tr("proxy.remote.empty.title"),
                        message: L10n.tr("proxy.remote.empty.message")
                    )
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.remoteServers) { server in
                            RemoteServerCardView(
                                server: server,
                                status: model.remoteStatuses[server.id],
                                logs: model.remoteLogs[server.id],
                                activeAction: model.remoteActions[server.id],
                                onSave: { updated in Task { await model.saveRemoteServer(updated) } },
                                onRemove: { id in Task { await model.removeRemoteServer(id: id) } },
                                onRefresh: { Task { await model.refreshRemote(server: server) } },
                                onDeploy: { Task { await model.deployRemote(server: server) } },
                                onStart: { Task { await model.startRemote(server: server) } },
                                onStop: { Task { await model.stopRemote(server: server) } },
                                onLogs: { Task { await model.readRemoteLogs(server: server) } }
                            )
                        }
                    }
                }
            }
        }
    }
}

struct ProxyInfoOnlySection: View {
    let title: String
    let message: String

    var body: some View {
        SectionCard(title: title) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProxyValueRow<Trailing: View>: View {
    let title: String
    let value: String
    let canCopy: Bool
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        value: String,
        canCopy: Bool,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.value = value
        self.canCopy = canCopy
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                trailing
                Button {
                    PlatformClipboard.copy(canCopy ? value : nil)
                } label: {
                    Label("common.copy", systemImage: "doc.on.doc")
                }
                .codexsiloActionButtonStyle()
                .disabled(!canCopy)
            }
            Text(value)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProxyDetailRow: View {
    let title: String
    let headline: String
    let detailText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            if !detailText.isEmpty {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RemoteServerCardView: View {
    let server: RemoteServerConfig
    let status: RemoteProxyStatus?
    let logs: String?
    let activeAction: RemoteServerAction?
    let onSave: (RemoteServerConfig) -> Void
    let onRemove: (String) -> Void
    let onRefresh: () -> Void
    let onDeploy: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onLogs: () -> Void

    @State private var draft: RemoteServerConfig
    @State private var isExpanded: Bool

    init(
        server: RemoteServerConfig,
        status: RemoteProxyStatus?,
        logs: String?,
        activeAction: RemoteServerAction?,
        onSave: @escaping (RemoteServerConfig) -> Void,
        onRemove: @escaping (String) -> Void,
        onRefresh: @escaping () -> Void,
        onDeploy: @escaping () -> Void,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onLogs: @escaping () -> Void
    ) {
        self.server = server
        self.status = status
        self.logs = logs
        self.activeAction = activeAction
        self.onSave = onSave
        self.onRemove = onRemove
        self.onRefresh = onRefresh
        self.onDeploy = onDeploy
        self.onStart = onStart
        self.onStop = onStop
        self.onLogs = onLogs
        _draft = State(initialValue: server)
        _isExpanded = State(initialValue: RemoteServerConfiguration.isPlaceholderDraft(server))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isExpanded {
                connectionSection
                authenticationSection
                actionBar
                statusSection
                detailsSection
                logsSection
                errorSection
            }
        }
        .padding(12)
        .cardSurface(cornerRadius: 14)
        .onChange(of: server) { _, newValue in
            draft = newValue
            if RemoteServerConfiguration.isPlaceholderDraft(draft) {
                isExpanded = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.label.isEmpty ? RemoteServerConfiguration.defaultLabel : draft.label)
                    .font(.headline)
                if !isExpanded {
                    Text("\(draft.sshUser)@\(draft.host):\(draft.listenPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            remoteStatusLabel
            CollapseChevronButton(isExpanded: isExpanded) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        }
    }

    private var remoteStatusLabel: some View {
        Label(
            RemoteServerConfiguration.statusLabel(status),
            systemImage: status?.running == true
                ? "checkmark.circle.fill"
                : "pause.circle"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(status?.running == true ? Color.green : Color.secondary)
    }

    private var connectionSection: some View {
        GroupBox {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: LayoutRules.proxyRemoteFieldMinWidth), spacing: 8)],
                spacing: 8
            ) {
                labeledField(title: "Name") {
                    TextField("tokyo-01", text: $draft.label)
                        .frostedRoundedInput()
                }
                labeledField(title: "Host") {
                    TextField("1.2.3.4", text: $draft.host)
                        .frostedRoundedInput()
                }
                labeledField(title: "SSH Port") {
                    TextField("22", value: $draft.sshPort, format: .number.grouping(.never))
                        .frostedRoundedInput()
                }
                labeledField(title: "SSH User") {
                    TextField(RemoteServerConfiguration.defaultSSHUser, text: $draft.sshUser)
                        .frostedRoundedInput()
                }
                labeledField(title: "Deploy Dir") {
                    TextField(RemoteServerConfiguration.defaultRemoteDir, text: $draft.remoteDir)
                        .frostedRoundedInput()
                }
                labeledField(title: "Proxy Port") {
                    TextField(
                        String(RemoteServerConfiguration.defaultProxyPort),
                        value: $draft.listenPort,
                        format: .number.grouping(.never)
                    )
                    .frostedRoundedInput()
                }
            }
        } label: {
            Text(verbatim: "Connection")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var authenticationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("SSH Auth", selection: $draft.authMode) {
                    Text("Path").tag("keyPath")
                    Text("Private key").tag("keyContent")
                    Text("Password").tag("password")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)

                switch draft.authMode {
                case "keyContent":
                    TextEditor(text: Binding(
                        get: { draft.privateKey ?? "" },
                        set: { draft.privateKey = $0 }
                    ))
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frostedRoundedSurface(cornerRadius: 8)
                case "password":
                    SecureField("SSH password", text: Binding(
                        get: { draft.password ?? "" },
                        set: { draft.password = $0 }
                    ))
                    .frostedRoundedInput()
                default:
                    HStack(spacing: 8) {
                        TextField("~/.ssh/id_ed25519", text: Binding(
                            get: { draft.identityFile ?? "" },
                            set: { draft.identityFile = $0 }
                        ))
                        .frostedRoundedInput()
                        #if canImport(AppKit)
                        Button {
                            if let path = chooseIdentityFilePath() {
                                draft.identityFile = path
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .liquidGlassActionButtonStyle()
                        .help("Choose key file")
                        #endif
                    }
                }
            }
        } label: {
            Text(verbatim: "SSH Authentication")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                remoteActionButton("common.save", kind: .save, prominent: true) { onSave(draft) }

                if status?.running == true {
                    remoteActionButton("common.stop", role: .destructive, kind: .stop, prominent: true, tint: .red, action: onStop)
                } else {
                    remoteActionButton("common.start", kind: .start, prominent: true, action: onStart)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("common.deploy", action: onDeploy)
                Button("common.refresh", action: onRefresh)
                Button("common.logs", action: onLogs)
                Divider()
                Button(role: .destructive) {
                    onRemove(server.id)
                } label: {
                    Text("common.remove")
                }
            } label: {
                if isSecondaryActionInProgress {
                    ProgressView()
                        .controlSize(.regular)
                } else {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(activeAction != nil)
        }
    }

    private var statusSection: some View {
        GroupBox {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: LayoutRules.proxyRemoteMetricMinWidth), spacing: 8)],
                spacing: 10
            ) {
                remoteMetric(title: "Installed", value: RemoteServerConfiguration.boolText(status?.installed))
                remoteMetric(title: "Systemd", value: RemoteServerConfiguration.boolText(status?.serviceInstalled))
                remoteMetric(title: "Enabled on boot", value: RemoteServerConfiguration.boolText(status?.enabled))
                remoteMetric(title: "Running", value: RemoteServerConfiguration.boolText(status?.running))
                remoteMetric(title: "PID", value: status?.pid.map(String.init) ?? "--")
            }
        } label: {
            Text(verbatim: "Status")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var detailsSection: some View {
        GroupBox {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: LayoutRules.proxyRemoteDetailMinWidth), spacing: 8)],
                spacing: 10
            ) {
                remoteDetailCard(title: "Remote Base URL", value: status?.baseURL ?? "--", canCopy: status?.baseURL != nil)
                remoteDetailCard(
                    title: "Remote API key",
                    value: status?.apiKey ?? "Generated after first start",
                    canCopy: status?.apiKey != nil
                )
                remoteDetailCard(
                    title: "Service name",
                    value: status?.serviceName ?? "Unknown",
                    canCopy: status?.serviceName != nil
                )
            }
        } label: {
            Text(verbatim: "Remote Access")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var logsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verbatim: "Remote logs")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        PlatformClipboard.copy(logs)
                    } label: {
                        Label("common.copy", systemImage: "doc.on.doc")
                    }
                    .codexsiloActionButtonStyle()
                    .disabled((logs ?? "").isEmpty)
                }

                ScrollView(.vertical) {
                    Text(logs?.isEmpty == false ? logs! : "Logs have not been loaded yet")
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: LayoutRules.proxyRemoteLogsHeight)
                .cardSurface(cornerRadius: 12)
                .scrollIndicators(.visible)
            }
        } label: {
            Text(verbatim: "Remote Logs")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var errorSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("proxy.detail.last_error"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(status?.lastError ?? L10n.tr("common.none"))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .cardSurface(cornerRadius: 12)
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func remoteMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: LayoutRules.proxyRemoteMetricHeight, alignment: .topLeading)
    }

    private func remoteDetailCard(title: String, value: String, canCopy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    PlatformClipboard.copy(canCopy ? value : nil)
                } label: {
                    Label("common.copy", systemImage: "doc.on.doc")
                }
                .codexsiloActionButtonStyle()
                .disabled(!canCopy)
            }
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func remoteActionButton(
        _ titleKey: LocalizedStringKey,
        role: ButtonRole? = nil,
        kind: RemoteServerAction,
        prominent: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isCurrent = activeAction == kind
        Button(role: role, action: action) {
            if isCurrent {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Text(titleKey)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: LayoutRules.proxyRemoteActionMinWidth)
        .liquidGlassActionButtonStyle(prominent: prominent, tint: tint)
        .disabled(activeAction != nil)
    }

    private var isSecondaryActionInProgress: Bool {
        switch activeAction {
        case .deploy, .refresh, .logs, .remove:
            return true
        default:
            return false
        }
    }

    private func chooseIdentityFilePath() -> String? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Select SSH key file"
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url?.path
        #else
        return nil
        #endif
    }
}
