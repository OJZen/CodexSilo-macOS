import SwiftUI

/// Centralized layout inputs to avoid duplicated sizing logic across pages.
enum LayoutRules {
    static let pagePadding = CGFloat(20)
    static let pageTopPadding = CGFloat(16)
    static let pageBottomPadding = CGFloat(20)
    static let sectionSpacing = CGFloat(18)
    static let sectionHeaderSpacing = CGFloat(12)
    static let accountsContentTopPadding = CGFloat(8)
    static let cardRadius = CGFloat(14)
    static let cardContentPadding = CGFloat(18)
    static let liquidProgressHeight = CGFloat(12)
    static let liquidProgressInset = CGFloat(2)
    static let listRowSpacing = CGFloat(12)
    static let tabSwitcherMaxWidth = CGFloat(420)
    static let minimumWindowWidth = CGFloat(1160)
    static let defaultWindowWidth = CGFloat(1280)
    static let minimumWindowHeight = CGFloat(680)
    static let defaultWindowHeight = CGFloat(820)
    static let accountsRowSpacing = CGFloat(10)
    static let accountsExpandedCardMinWidth = CGFloat(300)
    static let accountsExpandedCardPreferredWidth = CGFloat(360)
    static let accountsExpandedCardMaxWidth = CGFloat(400)
    static let accountsCollapsedCardMinWidth = CGFloat(220)
    static let accountsCollapsedCardPreferredWidth = CGFloat(260)
    static let accountsCollapsedCardMaxWidth = CGFloat(300)
    static let toolbarIconPointSize = CGFloat(20)
    static let toolbarRefreshIconOpticalScale = CGFloat(0.82)
    static let proxyDetailCardSpacing = CGFloat(12)
    static let proxyPageContentMaxWidth = CGFloat(960)
    static let proxyPageHorizontalPadding = CGFloat(16)
    static let proxyPageTopPadding = CGFloat(10)
    static let proxyPageBottomPadding = CGFloat(16)
    static let proxySectionSpacing = CGFloat(14)
    static let proxyPanelPadding = CGFloat(14)
    static let proxyMetricChipSpacing = CGFloat(8)
    static let proxyMetricChipHorizontalPadding = CGFloat(12)
    static let proxyMetricChipVerticalPadding = CGFloat(8)
    static let proxyHeroPortFieldWidth = CGFloat(108)
    static let proxyRemoteFieldMinWidth = CGFloat(160)
    static let proxyRemoteActionMinWidth = CGFloat(118)
    static let proxyRemoteMetricMinWidth = CGFloat(108)
    static let proxyRemoteMetricHeight = CGFloat(68)
    static let proxyRemoteDetailMinWidth = CGFloat(220)
    static let proxyRemoteLogsHeight = CGFloat(120)
    static let proxyPublicModeMinWidth = CGFloat(240)
    static let proxyPublicFieldMinWidth = CGFloat(220)
    static let proxyPublicStatusCardMinWidth = CGFloat(170)

    static func accountsGridColumns(
        isOverviewMode: Bool,
        availableWidth: CGFloat
    ) -> [GridItem] {
        let minimumWidth = isOverviewMode
            ? accountsCollapsedCardMinWidth
            : accountsExpandedCardMinWidth
        let preferredWidth = isOverviewMode
            ? accountsCollapsedCardPreferredWidth
            : accountsExpandedCardPreferredWidth
        let columnCount = max(
            1,
            Int((max(availableWidth, minimumWidth) + accountsRowSpacing) / (preferredWidth + accountsRowSpacing))
        )

        return Array(
            repeating: GridItem(
                .flexible(minimum: minimumWidth, maximum: isOverviewMode ? accountsCollapsedCardMaxWidth : accountsExpandedCardMaxWidth),
                spacing: accountsRowSpacing,
                alignment: .top
            ),
            count: columnCount
        )
    }
}
