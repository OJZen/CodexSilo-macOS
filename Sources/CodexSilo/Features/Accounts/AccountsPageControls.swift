import SwiftUI

struct AccountsActionBarView: View {
    @ObservedObject var model: AccountsPageModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedLayout
            compactLayout
        }
    }

    private var expandedLayout: some View {
        HStack(alignment: .center, spacing: LayoutRules.listRowSpacing) {
            expandedPrimaryActions
            Spacer(minLength: LayoutRules.listRowSpacing)
            expandedSecondaryActions
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            primaryActions
            secondaryActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedPrimaryActions: some View {
        primaryActions
            .fixedSize(horizontal: true, vertical: false)
    }

    private var expandedSecondaryActions: some View {
        secondaryActions
            .fixedSize(horizontal: true, vertical: false)
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.importCurrentAuth() }
            } label: {
                Label(
                    model.isImporting
                        ? L10n.tr("accounts.action.importing")
                        : L10n.tr("accounts.action.import_current_auth"),
                    systemImage: "square.and.arrow.down"
                )
                .lineLimit(1)
            }
            .disabled(!model.canImportCurrentAuthAction)
            .codexsiloActionButtonStyle(prominent: true)

            Button {
                model.addAccountViaLogin()
            } label: {
                Label(
                    model.isAdding
                        ? L10n.tr("accounts.action.waiting_for_login")
                        : L10n.tr("accounts.action.add_account"),
                    systemImage: "plus"
                )
                .lineLimit(1)
            }
            .disabled(!model.canAddAccountAction)
            .codexsiloActionButtonStyle(prominent: true)

            Button {
                model.presentCustomImportEditor()
            } label: {
                Label("accounts.action.custom_import", systemImage: "slider.horizontal.3")
                    .lineLimit(1)
            }
            .disabled(!model.canEditAccountConfiguration)
            .codexsiloActionButtonStyle(prominent: true)

            if model.canCancelAddAccountAction {
                Button(role: .destructive) {
                    model.cancelAddAccountViaLogin()
                } label: {
                    Label("取消登录", systemImage: "xmark.circle")
                        .lineLimit(1)
                }
                .codexsiloActionButtonStyle(prominent: true, tint: .red)
            }
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 8) {
            Picker(
                selection: Binding(
                    get: { model.sortMode },
                    set: { model.setSortMode($0) }
                )
            ) {
                ForEach(AccountsSortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
                    .lineLimit(1)
            }
            .pickerStyle(.menu)
            .controlSize(.large)

            Button {
                Task { await model.smartSwitch() }
            } label: {
                Label("accounts.action.smart_switch", systemImage: "wand.and.stars")
                    .lineLimit(1)
            }
            .codexsiloActionButtonStyle()
            .disabled(!model.canSmartSwitchAction)

            Button {
                Task { await model.refreshUsage() }
            } label: {
                iconOnlyActionLabel(
                    systemImage: "arrow.trianglehead.clockwise.rotate.90",
                    isSpinning: model.isRefreshSpinnerActive,
                    opticalScale: 0.74
                )
            }
            .disabled(!model.canRefreshUsageAction)
            .codexsiloActionButtonStyle(tint: .mint)
            .help(L10n.tr("common.refresh_usage"))
            .accessibilityLabel(Text(L10n.tr("common.refresh_usage")))

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.toggleAllAccountsCollapsed()
                }
            } label: {
                iconOnlyActionLabel(
                    systemImage: model.areAllAccountsCollapsed
                        ? "rectangle.grid.2x2"
                        : "rectangle.compress.vertical",
                    opticalScale: 0.78
                )
            }
            .codexsiloActionButtonStyle()
            .help(
                model.areAllAccountsCollapsed
                    ? L10n.tr("accounts.action.expand_all")
                    : L10n.tr("accounts.action.collapse_all")
            )
            .accessibilityLabel(
                Text(
                    model.areAllAccountsCollapsed
                        ? L10n.tr("accounts.action.expand_all")
                        : L10n.tr("accounts.action.collapse_all")
                )
            )
        }
    }

    private func iconOnlyActionLabel(
        systemImage: String,
        isSpinning: Bool = false,
        opticalScale: CGFloat = 1
    ) -> some View {
        ToolbarIconLabel(
            systemImage: systemImage,
            isSpinning: isSpinning,
            opticalScale: opticalScale
        )
        .frame(width: 18, height: 18, alignment: .center)
        .contentShape(Rectangle())
    }
}
