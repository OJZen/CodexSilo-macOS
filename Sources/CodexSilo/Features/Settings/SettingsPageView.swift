import SwiftUI
import AppKit

struct SettingsPageView: View {
    @ObservedObject var model: SettingsPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutRules.sectionSpacing) {
            pageHeader
                .padding(.horizontal, LayoutRules.pagePadding)

            Form {
                generalSection
                languageSection
                switchBehaviorSection
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)
        }
        .padding(.top, LayoutRules.pageTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await model.loadIfNeeded()
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: LayoutRules.listRowSpacing) {
            Text(L10n.tr("tab.settings"))
                .font(.largeTitle.weight(.semibold))

            Spacer(minLength: 0)

            Button(role: .destructive) {
                quitApp()
            } label: {
                Label("common.quit", systemImage: "power")
                    .lineLimit(1)
            }
            .codexsiloActionButtonStyle(tint: .red)
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

    private func quitApp() {
        NSApp.terminate(nil)
    }
}
