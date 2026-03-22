import SwiftUI

struct PublicAccessSection: View {
    @ObservedObject var model: ProxyPageModel
    let onCopy: (String?) -> Void

    var body: some View {
        SectionCard(
            title: L10n.tr("proxy.section.public_access"),
            headerTrailing: {
                CollapseChevronButton(isExpanded: model.cloudflaredExpanded) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.cloudflaredSectionExpanded.toggle()
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.publicAccessEnabled },
                    set: { value in
                        model.publicAccessEnabled = value
                        Task { await model.setPublicAccessEnabled(value) }
                    }
                )) {
                    Text(L10n.tr("proxy.toggle.enable_public_access"))
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.regular)

                if model.cloudflaredExpanded {
                    expandedContent
                }
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !model.proxyStatus.running {
            callout(
                title: L10n.tr("proxy.public.callout.start_local_first_title"),
                message: L10n.tr("proxy.public.callout.start_local_first_message")
            )
        }

        if !model.cloudflaredStatus.installed {
            installSection
        } else {
            modeSection

            if model.cloudflaredTunnelMode == .quick {
                callout(
                    title: L10n.tr("proxy.public.quick_note_title"),
                    message: L10n.tr("proxy.public.quick_note_message")
                )
            }

            if model.cloudflaredTunnelMode == .named {
                namedTunnelForm
            }

            toolbar
            statusSection
        }
    }

    private var installSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("proxy.public.install_title"))
                        .font(.headline)
                    Text(L10n.tr("proxy.public.install_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button("proxy.public.install_action") {
                    Task { await model.installCloudflared() }
                }
                .liquidGlassActionButtonStyle(prominent: true)
                .disabled(model.loading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(L10n.tr("proxy.public.not_installed_label"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { model.cloudflaredTunnelMode },
                    set: { model.cloudflaredTunnelMode = $0 }
                )) {
                    Text(L10n.tr("proxy.public.mode.quick_title"))
                        .tag(CloudflaredTunnelMode.quick)
                    Text(L10n.tr("proxy.public.mode.named_title"))
                        .tag(CloudflaredTunnelMode.named)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.large)
                .disabled(!model.canEditCloudflaredInput)

                Text(selectedModeKicker)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(selectedModeMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedModeKicker: String {
        switch model.cloudflaredTunnelMode {
        case .quick:
            L10n.tr("proxy.public.mode.quick_kicker")
        case .named:
            L10n.tr("proxy.public.mode.named_kicker")
        }
    }

    private var selectedModeMessage: String {
        switch model.cloudflaredTunnelMode {
        case .quick:
            L10n.tr("proxy.public.mode.quick_message")
        case .named:
            L10n.tr("proxy.public.mode.named_message")
        }
    }

    private var namedTunnelForm: some View {
        GroupBox {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: LayoutRules.proxyPublicFieldMinWidth), spacing: 10)],
                spacing: 10
            ) {
                labeledField(
                    title: L10n.tr("proxy.public.field.api_token"),
                    content: {
                        SecureField(
                            L10n.tr("proxy.public.field.api_token_placeholder"),
                            text: Binding(
                                get: { model.cloudflaredNamedInput.apiToken },
                                set: { model.cloudflaredNamedInput.apiToken = $0 }
                            )
                        )
                        .frostedRoundedInput()
                        .disabled(!model.canEditCloudflaredInput)
                    }
                )

                labeledField(
                    title: L10n.tr("proxy.public.field.account_id"),
                    content: {
                        TextField(
                            L10n.tr("proxy.public.field.account_id_placeholder"),
                            text: Binding(
                                get: { model.cloudflaredNamedInput.accountID },
                                set: { model.cloudflaredNamedInput.accountID = $0 }
                            )
                        )
                        .frostedRoundedInput()
                        .disabled(!model.canEditCloudflaredInput)
                    }
                )

                labeledField(
                    title: L10n.tr("proxy.public.field.zone_id"),
                    content: {
                        TextField(
                            L10n.tr("proxy.public.field.zone_id_placeholder"),
                            text: Binding(
                                get: { model.cloudflaredNamedInput.zoneID },
                                set: { model.cloudflaredNamedInput.zoneID = $0 }
                            )
                        )
                        .frostedRoundedInput()
                        .disabled(!model.canEditCloudflaredInput)
                    }
                )

                labeledField(
                    title: L10n.tr("proxy.public.field.hostname"),
                    content: {
                        TextField(
                            L10n.tr("proxy.public.field.hostname_placeholder"),
                            text: Binding(
                                get: { model.cloudflaredNamedInput.hostname },
                                set: { model.cloudflaredNamedInput.hostname = $0 }
                            )
                        )
                        .frostedRoundedInput()
                        .disabled(!model.canEditCloudflaredInput)
                    }
                )
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { model.cloudflaredUseHTTP2 },
                set: { model.cloudflaredUseHTTP2 = $0 }
            )) {
                Text(L10n.tr("proxy.toggle.use_http2"))
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.regular)
            .disabled(!model.canEditCloudflaredInput)

            HStack(spacing: 8) {
                Button("proxy.public.refresh_status") {
                    Task { await model.refreshCloudflared() }
                }
                .liquidGlassActionButtonStyle()
                .disabled(model.loading)

                if model.cloudflaredStatus.running {
                    Button("proxy.public.stop_action", role: .destructive) {
                        Task { await model.stopCloudflared() }
                    }
                    .liquidGlassActionButtonStyle(prominent: true, tint: .red)
                    .disabled(model.loading)
                } else {
                    Button("proxy.public.start_action") {
                        Task { await model.startCloudflared() }
                    }
                    .liquidGlassActionButtonStyle(prominent: true)
                    .disabled(!model.canStartCloudflared)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PublicAccessDetailRow(
                    title: L10n.tr("proxy.public.status_title"),
                    headline: model.cloudflaredStatus.running ? L10n.tr("proxy.status.running") : L10n.tr("proxy.status.stopped"),
                    message: model.cloudflaredStatus.running
                        ? L10n.tr("proxy.public.status_running_message")
                        : L10n.tr("proxy.public.status_stopped_message")
                )

                Divider()

                PublicAccessDetailRow(
                    title: L10n.tr("proxy.public.url_title"),
                    headline: model.cloudflaredStatus.publicURL ?? L10n.tr("proxy.value.generated_after_start"),
                    message: "",
                    canCopy: model.cloudflaredStatus.publicURL != nil
                ) {
                    onCopy(model.cloudflaredStatus.publicURL)
                }

                Divider()

                PublicAccessDetailRow(
                    title: L10n.tr("proxy.public.install_path_title"),
                    headline: model.cloudflaredStatus.binaryPath ?? L10n.tr("proxy.public.not_detected"),
                    message: ""
                )

                Divider()

                PublicAccessDetailRow(
                    title: L10n.tr("proxy.detail.last_error"),
                    headline: model.cloudflaredStatus.lastError ?? L10n.tr("common.none"),
                    message: ""
                )
            }
        }
    }

    private func callout(title: String, message: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeledField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct PublicAccessDetailRow: View {
    let title: String
    let headline: String
    let message: String
    let canCopy: Bool
    let onCopy: (() -> Void)?

    init(
        title: String,
        headline: String,
        message: String,
        canCopy: Bool = false,
        onCopy: (() -> Void)? = nil
    ) {
        self.title = title
        self.headline = headline
        self.message = message
        self.canCopy = canCopy
        self.onCopy = onCopy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let onCopy {
                    Button(action: onCopy) {
                        Label("common.copy", systemImage: "doc.on.doc")
                    }
                    .codexsiloActionButtonStyle()
                    .disabled(!canCopy)
                }
            }

            Text(headline)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
