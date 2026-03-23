import XCTest
@testable import CodexSilo

final class StoreFileRepositoryTests: XCTestCase {
    func testExtractFirstJSONObjectDataCanRecoverTrailingGarbage() throws {
        let malformed = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}} trailing text".data(using: .utf8)!

        let recovered = StoreFileRepository.extractFirstJSONObjectData(from: malformed)

        XCTAssertNotNil(recovered)
        let decoder = JSONDecoder()
        XCTAssertNoThrow(try decoder.decode(AccountsStore.self, from: recovered!))
    }

    func testLoadStoreRecoversWhenTrailingGarbageExists() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storePath = tempDir.appendingPathComponent("accounts.json")
        let raw = "{\"version\":1,\"accounts\":[],\"settings\":{\"launchAtStartup\":false,\"trayUsageDisplayMode\":\"remaining\",\"launchCodexAfterSwitch\":true,\"restartEditorsOnSwitch\":false,\"restartEditorTargets\":[],\"autoStartApiProxy\":false,\"remoteServers\":[],\"locale\":\"zh-CN\"}}\nINVALID".data(using: .utf8)!
        try raw.write(to: storePath)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: storePath,
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false)
        )

        let repository = StoreFileRepository(paths: paths)
        let store = try repository.loadStore()

        XCTAssertEqual(store.version, 1)
        XCTAssertEqual(store.accounts.count, 0)
    }

    func testAccountSummariesPreferStoredCurrentSelectionOverAuthFallback() {
        let account = StoredAccount(
            id: "acct-1",
            label: "Remote Selected",
            email: "remote@example.com",
            accountID: "remote-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let otherAccount = StoredAccount(
            id: "acct-2",
            label: "Local Auth",
            email: "local@example.com",
            accountID: "local-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [account, otherAccount],
            currentSelection: CurrentAccountSelection(
                accountID: "remote-account",
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: .defaultValue
        )

        let summaries = store.accountSummaries(currentAccountID: "local-account")

        XCTAssertEqual(
            summaries.first(where: { $0.accountID == "remote-account" })?.isCurrent,
            true
        )
        XCTAssertEqual(
            summaries.first(where: { $0.accountID == "local-account" })?.isCurrent,
            false
        )
    }

    func testAccountSummariesPreferCurrentVariantKeyWhenSameAccountHasMultiplePlans() {
        let plusAccount = StoredAccount(
            id: "acct-plus",
            label: "Plus",
            principalID: "same@example.com",
            email: "same@example.com",
            accountID: "shared-account",
            planType: "plus",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let proAccount = StoredAccount(
            id: "acct-pro",
            label: "Pro",
            principalID: "same@example.com",
            email: "same@example.com",
            accountID: "shared-account",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([:]),
            addedAt: 1,
            updatedAt: 2,
            usage: nil,
            usageError: nil
        )
        let store = AccountsStore(
            version: 1,
            accounts: [plusAccount, proAccount],
            currentSelection: CurrentAccountSelection(
                accountID: plusAccount.accountID,
                accountKey: plusAccount.accountKey,
                variantKey: plusAccount.variantKey,
                selectedAt: 123,
                sourceDeviceID: "device-a"
            ),
            settings: .defaultValue
        )

        let summaries = store.accountSummaries(
            currentAccountKey: plusAccount.accountKey,
            currentVariantKey: plusAccount.variantKey
        )

        XCTAssertEqual(summaries.first(where: { $0.id == "acct-plus" })?.isCurrent, true)
        XCTAssertEqual(summaries.first(where: { $0.id == "acct-pro" })?.isCurrent, false)
    }
}
