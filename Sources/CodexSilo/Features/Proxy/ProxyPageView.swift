import SwiftUI

struct ProxyPageView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
                pageHeader
                ApiProxySectionView(model: model)
            }
            .padding(.horizontal, LayoutRules.pagePadding)
            .padding(.top, LayoutRules.pageTopPadding)
            .padding(.bottom, LayoutRules.pageBottomPadding)
        }
        .scrollIndicators(.hidden)
        .task {
            await model.loadIfNeeded()
        }
        .onDisappear {
            model.handlePageDisappear()
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("tab.proxy"))
                .font(.largeTitle.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                statusSummaryRow
                VStack(alignment: .leading, spacing: 4) {
                    statusIndicator
                    proxyMetadataRow
                }
            }
        }
    }

    private var statusSummaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            statusIndicator
            proxyMetadataRow
            if let refreshedAtText {
                refreshIndicator(text: refreshedAtText)
            }
        }
    }

    private var statusIndicator: some View {
        Label(
            model.proxyStatus.running
                ? L10n.tr("proxy.status.running")
                : L10n.tr("proxy.status.stopped"),
            systemImage: model.proxyStatus.running
                ? "checkmark.circle.fill"
                : "pause.circle.fill"
        )
        .font(.subheadline.weight(.medium))
        .foregroundStyle(model.proxyStatus.running ? Color.green : Color.secondary)
    }

    private var proxyMetadataRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.tr("proxy.port_line_format", model.proxyStatus.port.map(String.init) ?? "--"))
            Text(L10n.tr("proxy.available_accounts_format", String(model.proxyStatus.availableAccounts)))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func refreshIndicator(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
            Text(verbatim: text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var refreshedAtText: String? {
        guard let epoch = model.lastRefreshedAt, epoch > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return LocalizedDateFormatterCache.shared.string(
            from: date,
            locale: .autoupdatingCurrent,
            dateStyle: Calendar.autoupdatingCurrent.isDateInToday(date) ? .none : .short,
            timeStyle: .short
        )
    }
}
