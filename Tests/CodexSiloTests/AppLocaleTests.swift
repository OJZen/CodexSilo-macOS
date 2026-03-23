import XCTest
@testable import CodexSilo

final class AppLocaleTests: XCTestCase {
    func testResolveSupportsAutomaticSelection() {
        XCTAssertEqual(AppLocale.resolve("auto"), .automatic)
        XCTAssertEqual(AppLocale.resolve("system"), .automatic)
    }

    func testResolveNormalizesLegacyIdentifiers() {
        XCTAssertEqual(AppLocale.resolve("en-US"), .english)
        XCTAssertEqual(AppLocale.resolve("zh-CN"), .simplifiedChinese)
        XCTAssertEqual(AppLocale.resolve("ja-JP"), .japanese)
        XCTAssertEqual(AppLocale.resolve("ko-KR"), .korean)
    }

    func testResolveFallsBackToEnglish() {
        XCTAssertEqual(AppLocale.resolve("pt-BR"), .english)
        XCTAssertEqual(AppLocale.resolve(""), .english)
    }

    func testPreferredUsesFirstSupportedSystemLanguage() {
        XCTAssertEqual(AppLocale.preferred(from: ["fr-FR", "ja-JP", "en-US"]), .french)
        XCTAssertEqual(AppLocale.preferred(from: ["de-DE", "en-GB"]), .german)
        XCTAssertEqual(AppLocale.preferred(from: ["zh-CN", "en-US"]), .simplifiedChinese)
    }

    func testEffectiveUsesSystemLanguageForAutomaticSelection() {
        XCTAssertEqual(AppLocale.effective(from: AppLocale.automatic.identifier, preferredIdentifiers: ["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(
            AppLocale.effectiveIdentifier(for: AppLocale.automatic.identifier, preferredIdentifiers: ["zh-CN", "en-US"]),
            AppLocale.simplifiedChinese.identifier
        )
    }
}
