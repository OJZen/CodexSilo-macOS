import SwiftUI

struct ApiProxySectionView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.proxyDetailCardSpacing) {
            proxyHeroContent
            proxyDetailGroup
        }
    }

    private var proxyHeroContent: some View {
        proxyPanel(tint: heroPanelTint) {
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

                proxyAccountPicker
            }
        }
    }

    private var proxyDetailGroup: some View {
        proxyPanel(tint: detailPanelTint) {
            VStack(alignment: .leading, spacing: 12) {
                ProxyValueRow(
                    title: model.proxyStatus.lanBaseURLs.isEmpty
                        ? L10n.tr("proxy.detail.base_url")
                        : L10n.tr("proxy.detail.local_base_url"),
                    value: model.proxyStatus.baseURL ?? L10n.tr("proxy.value.generated_after_start"),
                    canCopy: model.proxyStatus.baseURL != nil
                )

                if !model.proxyStatus.lanBaseURLs.isEmpty {
                    Divider()

                    ProxyValueRow(
                        title: L10n.tr("proxy.detail.lan_base_urls"),
                        value: model.proxyStatus.lanBaseURLs.joined(separator: "\n"),
                        canCopy: true
                    )
                }

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
                    .disabled(model.controlsBusy)
                }

                Divider()

                ProxyDetailRow(
                    title: L10n.tr("proxy.detail.selected_account"),
                    headline: model.selectedProxyAccountHeadline,
                    detailText: model.selectedProxyAccountDetailText
                )

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

                Divider()

                ProxyMetricsSection(
                    metrics: model.proxyStatus.metrics,
                    controlsBusy: model.controlsBusy
                ) {
                    Task { await model.resetMetrics() }
                }

                Divider()

                ProxyDetailRow(
                    title: L10n.tr("proxy.detail.last_response_at"),
                    headline: lastResponseHeadline,
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
                metricChip(text: L10n.tr("proxy.metric.in_flight_format", String(model.proxyStatus.metrics.inFlightRequests)))
                metricChip(text: L10n.tr("proxy.metric.total_requests_format", String(model.proxyStatus.metrics.totalRequests)))
                metricChip(text: L10n.tr("proxy.metric.total_tokens_format", String(model.proxyStatus.metrics.totalTokens)))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: LayoutRules.proxyMetricChipSpacing) {
                statusChip
                metricChip(text: L10n.tr("proxy.port_line_format", model.proxyStatus.port.map(String.init) ?? "--"))
                metricChip(text: L10n.tr("proxy.available_accounts_format", String(model.proxyStatus.availableAccounts)))
                metricChip(text: L10n.tr("proxy.metric.in_flight_format", String(model.proxyStatus.metrics.inFlightRequests)))
                metricChip(text: L10n.tr("proxy.metric.total_requests_format", String(model.proxyStatus.metrics.totalRequests)))
                metricChip(text: L10n.tr("proxy.metric.total_tokens_format", String(model.proxyStatus.metrics.totalTokens)))
            }
        }
    }

    private var lastResponseHeadline: String {
        guard let unixSeconds = model.proxyStatus.metrics.lastResponseAt else {
            return L10n.tr("proxy.value.never")
        }

        return Date(timeIntervalSince1970: TimeInterval(unixSeconds))
            .formatted(date: .abbreviated, time: .standard)
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

    private var heroPanelTint: Color {
        model.proxyStatus.running ? .teal : .orange
    }

    private var detailPanelTint: Color {
        model.proxyStatus.lastError == nil ? .blue : .orange
    }

    private var preferredPortEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("proxy.port_line_format", "").trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("8787", text: $model.preferredPortText)
                .frostedRoundedInput()
                .frame(width: LayoutRules.proxyHeroPortFieldWidth)
                .disabled(model.controlsBusy)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("proxy.action.refresh_status") {
                Task { await model.refreshStatus() }
            }
            .liquidGlassActionButtonStyle(density: .compact)
            .disabled(model.controlsBusy)

            Button {
                Task { await model.testLiveRequest() }
            } label: {
                HStack(spacing: 6) {
                    if model.testingLiveRequest {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(L10n.tr("proxy.action.test_live_request"))
                }
            }
            .liquidGlassActionButtonStyle(density: .compact)
            .disabled(
                model.controlsBusy
                    || !model.proxyStatus.running
                    || model.proxyStatus.baseURL == nil
                    || model.proxyStatus.apiKey == nil
            )

            if model.proxyStatus.running {
                Button("proxy.action.stop_api_proxy", role: .destructive) {
                    Task { await model.stopProxy() }
                }
                .liquidGlassActionButtonStyle(prominent: true, tint: .red, density: .compact)
                .disabled(model.controlsBusy)
            } else {
                Button("proxy.action.start_api_proxy") {
                    Task { await model.startProxy() }
                }
                .liquidGlassActionButtonStyle(prominent: true, density: .compact)
                .disabled(model.controlsBusy)
            }
        }
    }

    private var proxyAccountPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("proxy.selection.label"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 12) {
                Group {
                    if model.usesAutoUniformProxyAccountRouting {
                        disabledProxyAccountField(title: model.autoSwitchPickerTitle)
                    } else {
                        Picker("", selection: Binding(
                            get: { model.selectedProxyAccountPickerID },
                            set: { newValue in
                                Task { await model.setProxyAccountSelection(choiceID: newValue) }
                            }
                        )) {
                            Text(model.followCurrentProxyAccountTitle)
                                .tag(model.followCurrentSelectionID)

                            Section(L10n.tr("proxy.selection.custom_accounts_section")) {
                                ForEach(model.proxyAccountOptions) { option in
                                    Text(proxyAccountOptionTitle(option))
                                        .tag(option.id)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(model.controlsBusy || model.proxyAccountOptions.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: Binding(
                    get: { model.usesAutoUniformProxyAccountRouting },
                    set: { value in
                        Task { await model.setAutoSwitchProxyAccounts(value) }
                    }
                )) {
                    Text(L10n.tr("proxy.selection.auto_switch"))
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.regular)
                .disabled(model.controlsBusy || model.proxyAccountOptions.isEmpty)
            }

            Text(model.selectedProxyAccountDetailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func disabledProxyAccountField(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frostedRoundedInput()
        .opacity(0.65)
    }

    private func proxyAccountOptionTitle(_ option: ProxyAccountOption) -> String {
        if option.isCurrent {
            return L10n.tr("proxy.selection.account_current_format", option.label)
        }
        return option.label
    }

    private func proxyPanel<Content: View>(
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(LayoutRules.proxyPanelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedRoundedSurface(cornerRadius: 12, tint: tint)
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

private struct ProxyMetricsSection: View {
    let metrics: ApiProxyMetrics
    let controlsBusy: Bool
    let onReset: () -> Void

    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: 10),
        GridItem(.flexible(minimum: 120), spacing: 10),
        GridItem(.flexible(minimum: 120), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("proxy.detail.request_metrics"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    onReset()
                } label: {
                    Text(L10n.tr("proxy.action.reset_metrics"))
                }
                .codexsiloActionButtonStyle()
                .disabled(
                    controlsBusy
                        || metrics == .empty
                        || metrics.inFlightRequests > 0
                )
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ProxyMetricTile(
                    title: L10n.tr("proxy.metric.total_requests_label"),
                    value: metrics.totalRequests
                )
                ProxyMetricTile(
                    title: L10n.tr("proxy.metric.successful_requests_label"),
                    value: metrics.successfulRequests
                )
                ProxyMetricTile(
                    title: L10n.tr("proxy.metric.failed_requests_label"),
                    value: metrics.failedRequests
                )
                ProxyMetricTile(
                    title: L10n.tr("proxy.metric.prompt_tokens_label"),
                    value: metrics.promptTokens
                )
                ProxyMetricTile(
                    title: L10n.tr("proxy.metric.completion_tokens_label"),
                    value: metrics.completionTokens
                )
                ProxyMetricTile(
                    title: L10n.tr("proxy.metric.total_tokens_label"),
                    value: metrics.totalTokens
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProxyMetricTile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value.formatted())
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedRoundedSurface(cornerRadius: 10)
    }
}
