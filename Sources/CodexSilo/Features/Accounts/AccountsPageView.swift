import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct AccountsPageView: View {
    @ObservedObject var model: AccountsPageModel
    @State private var pendingDeletionAccount: AccountSummary?

    init(model: AccountsPageModel) {
        self.model = model
    }

    var body: some View {
        GeometryReader { proxy in
            contentLayout(availableWidth: max(0, proxy.size.width - LayoutRules.pagePadding * 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            await model.loadIfNeeded()
        }
        .sheet(
            item: Binding(
                get: { model.accountEditor },
                set: { model.accountEditor = $0 }
            )
        ) { draft in
            AccountConfigurationEditorView(
                draft: draft,
                onClose: {
                    model.dismissAccountEditor()
                },
                onSave: { updatedDraft in
                    await model.saveAccountEditor(updatedDraft)
                }
            )
            .frame(minWidth: 820, minHeight: 760)
        }
        .alert(
            "确认移除账户？",
            isPresented: Binding(
                get: { pendingDeletionAccount != nil },
                set: { presenting in
                    if !presenting {
                        pendingDeletionAccount = nil
                    }
                }
            ),
            presenting: pendingDeletionAccount
        ) { account in
            Button("取消", role: .cancel) {
                pendingDeletionAccount = nil
            }
            Button("移除账户", role: .destructive) {
                pendingDeletionAccount = nil
                Task { await model.deleteAccount(id: account.id) }
            }
        } message: { account in
            Text("将移除“\(account.label)”的本地账户配置，此操作无法撤销。")
        }
    }

    private func contentLayout(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
            pageHeader
                .padding(.horizontal, LayoutRules.pagePadding)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    contentView(availableWidth: availableWidth)
                }
                .padding(.top, LayoutRules.accountsContentTopPadding)
                .padding(.bottom, LayoutRules.pageBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, LayoutRules.pageTopPadding)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: LayoutRules.listRowSpacing) {
                Text(L10n.tr("tab.accounts"))
                    .font(.largeTitle.weight(.semibold))
            }

            AccountsActionBarView(model: model)
        }
    }

    @ViewBuilder
    private func contentView(availableWidth: CGFloat) -> some View {
        switch model.state {
        case .loading:
            ProgressView(L10n.tr("accounts.loading.message"))
                .frame(maxWidth: .infinity, minHeight: 180)
        case .empty(let message):
            EmptyStateView(title: L10n.tr("accounts.empty.title"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .error(let message):
            EmptyStateView(title: L10n.tr("accounts.error.load_failed"), message: message)
                .padding(.horizontal, LayoutRules.pagePadding)
        case .content(let accounts):
            let isOverviewMode = model.areAllAccountsCollapsed
            let columns = LayoutRules.accountsGridColumns(
                isOverviewMode: isOverviewMode,
                availableWidth: availableWidth
            )
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: LayoutRules.accountsRowSpacing
            ) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    AccountCardView(
                        account: account,
                        isCollapsed: model.isAccountCollapsed(account.id),
                        switching: model.switchingAccountID == account.id,
                        onSwitch: { Task { await model.switchAccount(id: account.id) } },
                        onEdit: { Task { await model.editAccount(id: account.id) } },
                        onDelete: { pendingDeletionAccount = account }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .animation(
                .spring(response: 0.36, dampingFraction: 0.84),
                value: accounts.map(\.id)
            )
            .padding(.horizontal, LayoutRules.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccountConfigurationEditorView: View {
    @State private var draft: AccountConfigurationDraft
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    #if canImport(AppKit)
    @State private var jsonEditorHeight = CGFloat(420)
    #endif

    let onClose: () -> Void
    let onSave: @MainActor (AccountConfigurationDraft) async -> String?

    init(
        draft: AccountConfigurationDraft,
        onClose: @escaping () -> Void,
        onSave: @escaping @MainActor (AccountConfigurationDraft) async -> String?
    ) {
        _draft = State(initialValue: draft)
        self.onClose = onClose
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountInfoSection
                    authJSONSection
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
                    onClose()
                }
                .codexsiloActionButtonStyle()
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("common.save")) {
                    saveErrorMessage = nil
                    isSaving = true
                    let value = draft
                    Task { @MainActor in
                        let errorMessage = await onSave(value)
                        isSaving = false
                        if let errorMessage {
                            saveErrorMessage = errorMessage
                        } else {
                            onClose()
                        }
                    }
                }
                .codexsiloActionButtonStyle(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "无法保存账户",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { presenting in
                    if !presenting {
                        saveErrorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var editorHeader: some View {
        HStack {
            Label(draft.navigationTitle, systemImage: editorHeaderSymbolName)
                .font(.title2.weight(.semibold))
                .labelStyle(.titleAndIcon)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var accountInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        formFieldLabel("账户名称")
                        editorTextField(title: "账户名称", text: $draft.label)
                    }

                    GridRow {
                        formFieldLabel("团队名称")
                        editorTextField(title: "团队名称", text: $draft.teamAlias)
                    }
                }

                Divider()

                Toggle("保存后设为当前账号", isOn: $draft.setAsCurrent)
                    .toggleStyle(.switch)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label("账户信息", systemImage: "person.text.rectangle")
                .font(.callout.weight(.medium))
        }
    }

    private var authJSONSection: some View {
        GroupBox {
            authJSONEditor
                .frame(height: editorHeight)
                .padding(12)
                .background(jsonEditorBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 4)
        } label: {
            Label {
                Text(verbatim: "auth.json")
            } icon: {
                Image(systemName: "curlybraces.square")
            }
                .font(.callout.weight(.medium))
        }
    }

    private func editorTextField(
        title: String,
        text: Binding<String>
    ) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .frame(maxWidth: 360)
            .accessibilityLabel(Text(title))
    }

    private func formFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 76, alignment: .leading)
    }

    private var editorHeaderSymbolName: String {
        draft.isEditingExistingAccount ? "slider.horizontal.3" : "square.and.arrow.down"
    }

    @ViewBuilder
    private var jsonEditorBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var authJSONEditor: some View {
        #if canImport(AppKit)
        NonWrappingCodeEditor(
            text: $draft.authJSONString,
            measuredHeight: $jsonEditorHeight
        )
        #else
        TextEditor(text: $draft.authJSONString)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        #endif
    }

    private var editorHeight: CGFloat {
        #if canImport(AppKit)
        max(420, jsonEditorHeight)
        #else
        420
        #endif
    }
}

#if canImport(AppKit)
private struct NonWrappingCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.textColor = NSColor.labelColor
        textView.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .regular
        )
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 0, height: 4)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.recalculateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView

        if textView.string != text {
            context.coordinator.isApplyingProgrammaticChange = true
            textView.string = text
            context.coordinator.isApplyingProgrammaticChange = false
        }

        context.coordinator.recalculateHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var measuredHeight: CGFloat

        weak var textView: NSTextView?
        var isApplyingProgrammaticChange = false

        init(text: Binding<String>, measuredHeight: Binding<CGFloat>) {
            _text = text
            _measuredHeight = measuredHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if !isApplyingProgrammaticChange {
                text = textView.string
            }
            recalculateHeight(for: textView)
        }

        func recalculateHeight() {
            guard let textView else { return }
            recalculateHeight(for: textView)
        }

        private func recalculateHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let contentHeight = ceil(usedRect.height + textView.textContainerInset.height * 2 + 2)
            let nextHeight = max(420, contentHeight)

            guard abs(measuredHeight - nextHeight) > 0.5 else { return }
            DispatchQueue.main.async {
                self.measuredHeight = nextHeight
            }
        }
    }
}
#endif
