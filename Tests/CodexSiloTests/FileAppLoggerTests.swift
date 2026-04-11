import XCTest
@testable import CodexSilo

final class FileAppLoggerTests: XCTestCase {
    func testLoggerWritesRedactedEntriesToPrivateLogFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = FileAppLogger(
            paths: makePaths(in: tempDir),
            configuration: .init(maxFileSizeBytes: 512 * 1_024, retentionDays: 7)
        )

        logger.error(
            category: .auth,
            event: "token_exchange_failed",
            message: "Bearer sk-a4aeeb4b523e4bdf87bc6ac431e70308 for ojunedev@gmail.com failed.",
            metadata: [
                "Authorization": "Bearer sk-a4aeeb4b523e4bdf87bc6ac431e70308",
                "email": "ojunedev@gmail.com",
                "account_id": "account-12345678",
                "password": "super-secret"
            ],
            operationID: "operation-12345678"
        )

        let entries = try await waitForEntries(from: logger, minimumCount: 1)
        XCTAssertEqual(entries.first?.scope, "auth.token_exchange_failed")

        let text = try await logger.loadCombinedText(limit: 10)
        XCTAssertFalse(text.contains("sk-a4aeeb4b523e4bdf87bc6ac431e70308"))
        XCTAssertFalse(text.contains("ojunedev@gmail.com"))
        XCTAssertFalse(text.contains("account-12345678"))
        XCTAssertFalse(text.contains("super-secret"))
        XCTAssertTrue(text.contains("Bearer <redacted>"))
        XCTAssertTrue(text.contains("oj***@gmail.com"))
        XCTAssertTrue(text.contains(LogRedactor.maskIdentifier("account-12345678")))
        XCTAssertTrue(text.contains(LogRedactor.maskIdentifier("operation-12345678")))

        let logsDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: makePaths(in: tempDir).logsDirectory.path)
        let logFileAttributes = try FileManager.default.attributesOfItem(atPath: makePaths(in: tempDir).currentLogFilePath.path)
        XCTAssertEqual((logsDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((logFileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLoggerPrunesExpiredArchivedLogsOnWrite() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = makePaths(in: tempDir)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        let expiredArchive = paths.logsDirectory.appendingPathComponent("app-1999-01-01-000000.log")
        try Data("old log\n".utf8).write(to: expiredArchive)
        let expiredDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -10, to: Date()) ?? Date.distantPast
        try FileManager.default.setAttributes([.modificationDate: expiredDate], ofItemAtPath: expiredArchive.path)

        let logger = FileAppLogger(
            paths: paths,
            configuration: .init(maxFileSizeBytes: 512 * 1_024, retentionDays: 7)
        )
        logger.info(
            category: .app,
            event: "bootstrap_succeeded",
            message: "Bootstrap finished."
        )

        _ = try await waitForEntries(from: logger, minimumCount: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredArchive.path))
    }

    func testLoggerRedactsURLQueryParametersInMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = FileAppLogger(
            paths: makePaths(in: tempDir),
            configuration: .init(maxFileSizeBytes: 512 * 1_024, retentionDays: 7)
        )

        logger.info(
            category: .auth,
            event: "oauth_browser_opened",
            message: "Opened browser for OAuth authorization.",
            metadata: [
                "url": "https://auth.openai.com/oauth/authorize?state=abc123&code_challenge=secret&allowed_workspace_id=workspace-12345678"
            ]
        )

        _ = try await waitForEntries(from: logger, minimumCount: 1)
        let text = try await logger.loadCombinedText(limit: 10)
        XCTAssertTrue(text.contains("https://auth.openai.com/oauth/authorize"))
        XCTAssertFalse(text.contains("state=abc123"))
        XCTAssertFalse(text.contains("code_challenge=secret"))
        XCTAssertFalse(text.contains("allowed_workspace_id=workspace-12345678"))
    }

    func testLoggerRedactsJSONAndFormEncodedTokenAssignments() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = FileAppLogger(
            paths: makePaths(in: tempDir),
            configuration: .init(maxFileSizeBytes: 512 * 1_024, retentionDays: 7)
        )

        logger.error(
            category: .auth,
            event: "token_exchange_failed",
            message: #"Upstream body: {"access_token":"plain-secret","refresh_token":"refresh-secret","id_token":"eyJ.header.payload","api_key":"sk-super-secret"}"#,
            metadata: [
                "detail": "subject_token=eyJ.subject.payload&password=super-secret"
            ]
        )

        _ = try await waitForEntries(from: logger, minimumCount: 1)
        let text = try await logger.loadCombinedText(limit: 10)
        XCTAssertFalse(text.contains("plain-secret"))
        XCTAssertFalse(text.contains("refresh-secret"))
        XCTAssertFalse(text.contains("eyJ.header.payload"))
        XCTAssertFalse(text.contains("eyJ.subject.payload"))
        XCTAssertFalse(text.contains("sk-super-secret"))
        XCTAssertFalse(text.contains("super-secret"))
        XCTAssertTrue(text.contains(#""access_token":"<redacted>""#))
        XCTAssertTrue(text.contains(#""refresh_token":"<redacted>""#))
        XCTAssertTrue(text.contains(#""id_token":"<redacted>""#) || text.contains(#""id_token":"<redacted-jwt>""#))
        XCTAssertTrue(text.contains("subject_token=<redacted>"))
        XCTAssertTrue(text.contains("password=<redacted>"))
    }

    private func waitForEntries(
        from logger: FileAppLogger,
        minimumCount: Int
    ) async throws -> [AppLogEntry] {
        for _ in 0..<20 {
            let entries = try await logger.loadEntries(limit: max(minimumCount, 10))
            if entries.count >= minimumCount {
                return entries
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Timed out waiting for file log entries.")
        return try await logger.loadEntries(limit: max(minimumCount, 10))
    }

    private func makePaths(in directory: URL) -> FileSystemPaths {
        FileSystemPaths(
            applicationSupportDirectory: directory,
            accountStorePath: directory.appendingPathComponent("accounts.json"),
            codexAuthPath: directory.appendingPathComponent("auth.json"),
            codexConfigPath: directory.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: directory.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: directory.appendingPathComponent("proxyd/api-proxy.key")
        )
    }
}
