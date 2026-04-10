import SwiftUI

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
                .disabled(model.controlsBusy)
            }
        }
    }

    private var proxyDetailGroup: some View {
        proxyPanel {
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

                ProxyValueRow(
                    title: L10n.tr("proxy.detail.request_metrics"),
                    value: requestMetricsValue,
                    canCopy: false
                ) {
                    Button {
                        Task { await model.resetMetrics() }
                    } label: {
                        Text(L10n.tr("proxy.action.reset_metrics"))
                    }
                    .codexsiloActionButtonStyle()
                    .disabled(
                        model.controlsBusy
                            || model.proxyStatus.metrics == .empty
                            || model.proxyStatus.metrics.inFlightRequests > 0
                    )
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

    private var requestMetricsValue: String {
        let metrics = model.proxyStatus.metrics
        return [
            "\(L10n.tr("proxy.metric.in_flight_label")): \(metrics.inFlightRequests)",
            "\(L10n.tr("proxy.metric.total_requests_label")): \(metrics.totalRequests)",
            "\(L10n.tr("proxy.metric.successful_requests_label")): \(metrics.successfulRequests)",
            "\(L10n.tr("proxy.metric.failed_requests_label")): \(metrics.failedRequests)",
            "\(L10n.tr("proxy.metric.prompt_tokens_label")): \(metrics.promptTokens)",
            "\(L10n.tr("proxy.metric.completion_tokens_label")): \(metrics.completionTokens)",
            "\(L10n.tr("proxy.metric.total_tokens_label")): \(metrics.totalTokens)"
        ].joined(separator: "\n")
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
