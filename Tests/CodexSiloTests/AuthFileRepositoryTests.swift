import XCTest
@testable import CodexSilo

final class AuthFileRepositoryTests: XCTestCase {
    func testExtractAuthReadsAccountAndClaims() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345",
                "chatgpt_plan_type": "pro",
                "chatgpt_team_name": "Alpha Team"
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.accountID, "acct_12345")
        XCTAssertEqual(extracted.email, "dev@example.com")
        XCTAssertEqual(extracted.planType, "pro")
        XCTAssertEqual(extracted.teamName, "Alpha Team")
        XCTAssertEqual(extracted.accessToken, "access-token")
    }

    func testExtractAuthPrefersNonPersonalWorkspaceSlug() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let token = makeJWT(payload: [
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_12345",
                "chatgpt_plan_type": "team",
                "active_organization_id": "org-team",
                "organizations": [
                    [
                        "id": "org-personal",
                        "is_default": true,
                        "title": "Personal",
                        "slug": "personal"
                    ],
                    [
                        "id": "org-team",
                        "is_active": true,
                        "title": "Team Workspace",
                        "slug": "kqikiy"
                    ]
                ]
            ]
        ])

        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(token)
            ])
        ])

        let extracted = try repository.extractAuth(from: auth)

        XCTAssertEqual(extracted.accountID, "acct_12345")
        XCTAssertEqual(extracted.planType, "team")
        XCTAssertEqual(extracted.teamName, "kqikiy")
    }

    func testMakeChatGPTAuthBuildsCodexCompatibleShape() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let idToken = makeJWT(payload: [
            "email": "dev@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_67890",
                "chatgpt_plan_type": "plus"
            ]
        ])

        let auth = try repository.makeChatGPTAuth(from: ChatGPTOAuthTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: idToken,
            apiKey: "sk-proj-test"
        ))

        XCTAssertEqual(auth["auth_mode"]?.stringValue, "chatgpt")
        XCTAssertEqual(auth["OPENAI_API_KEY"]?.stringValue, "sk-proj-test")
        XCTAssertEqual(auth["tokens"]?["access_token"]?.stringValue, "access-token")
        XCTAssertEqual(auth["tokens"]?["refresh_token"]?.stringValue, "refresh-token")
        XCTAssertEqual(auth["tokens"]?["id_token"]?.stringValue, idToken)
        XCTAssertEqual(auth["tokens"]?["account_id"]?.stringValue, "acct_67890")
        XCTAssertNotNil(auth["last_refresh"]?.stringValue)
    }

    func testWriteCurrentAuthNormalizesFlatTokenShapeAndTimestamp() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let idToken = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_98765"
            ]
        ])
        let auth = JSONValue.object([
            "access_token": .string("access-token"),
            "refresh_token": .string("refresh-token"),
            "id_token": .string(idToken),
            "account_id": .string("acct_98765"),
            "last_refresh": .string("2026-03-19T12:57:06.735503"),
            "organization": .object([
                "name": .string("workspace-alpha")
            ]),
            "OPENAI_API_KEY": .string("sk-proj-test")
        ])

        try repository.writeCurrentAuth(auth)
        let written = try repository.readCurrentAuth()

        XCTAssertNil(written["access_token"])
        XCTAssertNil(written["refresh_token"])
        XCTAssertNil(written["id_token"])
        XCTAssertEqual(written["auth_mode"]?.stringValue, "chatgpt")
        XCTAssertEqual(written["tokens"]?["access_token"]?.stringValue, "access-token")
        XCTAssertEqual(written["tokens"]?["refresh_token"]?.stringValue, "refresh-token")
        XCTAssertEqual(written["tokens"]?["id_token"]?.stringValue, idToken)
        XCTAssertEqual(written["tokens"]?["account_id"]?.stringValue, "acct_98765")
        XCTAssertEqual(written["organization"]?["name"]?.stringValue, "workspace-alpha")
        XCTAssertEqual(written["OPENAI_API_KEY"]?.stringValue, "sk-proj-test")
        assertRFC3339Timestamp(written["last_refresh"]?.stringValue)
    }

    func testWriteCurrentAuthReplacesInvalidLastRefreshWithCompatibleTimestamp() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let idToken = makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_54321"
            ]
        ])
        let auth = JSONValue.object([
            "auth_mode": .string("chatgpt"),
            "last_refresh": .string("not-a-date"),
            "tokens": .object([
                "access_token": .string("access-token"),
                "id_token": .string(idToken)
            ])
        ])

        try repository.writeCurrentAuth(auth)
        let written = try repository.readCurrentAuth()

        XCTAssertNotEqual(written["last_refresh"]?.stringValue, "not-a-date")
        assertRFC3339Timestamp(written["last_refresh"]?.stringValue)
    }

    func testWriteCurrentAuthRejectsPayloadWithoutIDToken() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanup() }

        let repository = fixture.repository
        let auth = JSONValue.object([
            "tokens": .object([
                "access_token": .string("access-token")
            ])
        ])

        XCTAssertThrowsError(try repository.writeCurrentAuth(auth)) { error in
            XCTAssertEqual(error.localizedDescription, "auth.json missing id_token")
        }
    }

    private func makeJWT(payload: [String: Any]) -> String {
        let headerData = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)

        let header = base64URL(headerData)
        let body = base64URL(payloadData)
        return "\(header).\(body)."
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeRepositoryFixture() throws -> RepositoryFixture {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let authPath = tempDir.appendingPathComponent("auth.json")
        let configPath = tempDir.appendingPathComponent("config.toml")
        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: authPath,
            codexConfigPath: configPath,
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key", isDirectory: false)
        )

        return RepositoryFixture(
            repository: AuthFileRepository(paths: paths),
            cleanup: { try? FileManager.default.removeItem(at: tempDir) }
        )
    }

    private func assertRFC3339Timestamp(_ value: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            XCTFail("Expected timestamp", file: file, line: line)
            return
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        XCTAssertTrue(
            fractionalFormatter.date(from: value) != nil || plainFormatter.date(from: value) != nil,
            "Expected RFC3339 timestamp but received \(value)",
            file: file,
            line: line
        )
    }
}

private struct RepositoryFixture {
    let repository: AuthFileRepository
    let cleanup: () -> Void
}
