import XCTest
@testable import CodexSilo

final class AppSettingsCodableTests: XCTestCase {
    func testDefaultSettingsUseAutomaticLocaleSelection() {
        XCTAssertEqual(AppSettings.defaultValue.locale, AppLocale.automatic.identifier)
    }

    func testDecodeLegacySettingsWithoutAutoRefreshOrAutoSmartSwitchUsesDefault() throws {
        let json = """
        {
          "launchAtStartup": true,
          "trayUsageDisplayMode": "remaining",
          "launchCodexAfterSwitch": true,
          "restartEditorsOnSwitch": false,
          "restartEditorTargets": [],
          "autoStartApiProxy": true,
          "remoteServers": [],
          "locale": "en"
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.autoRefreshAccounts, true)
        XCTAssertEqual(decoded.autoSmartSwitch, false)
        XCTAssertEqual(decoded.autoStartApiProxy, true)
        XCTAssertEqual(decoded.locale, AppLocale.english.identifier)
    }

    func testDecodeAutomaticLocaleSelectionPreservesAutoValue() throws {
        let json = """
        {
          "launchAtStartup": false,
          "launchCodexAfterSwitch": true,
          "restartEditorsOnSwitch": false,
          "restartEditorTargets": [],
          "autoStartApiProxy": false,
          "remoteServers": [],
          "locale": "auto"
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.locale, AppLocale.automatic.identifier)
    }

    func testEncodeSettingsOmitsLegacyEditorRestartKeys() throws {
        let data = try JSONEncoder().encode(AppSettings.defaultValue)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("restartEditorsOnSwitch"))
        XCTAssertFalse(json.contains("restartEditorTargets"))
    }
}
