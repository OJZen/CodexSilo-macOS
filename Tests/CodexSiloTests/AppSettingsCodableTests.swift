import XCTest
@testable import CodexSilo

final class AppSettingsCodableTests: XCTestCase {
    func testDecodeLegacySettingsWithoutAutoRefreshOrAutoSmartSwitchUsesDefault() throws {
        let json = """
        {
          "launchAtStartup": true,
          "trayUsageDisplayMode": "remaining",
          "launchCodexAfterSwitch": true,
          "syncOpencodeOpenaiAuth": false,
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
}
