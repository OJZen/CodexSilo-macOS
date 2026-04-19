import XCTest
@testable import CodexSilo

final class SwiftNativeProxyRuntimeServiceTests: XCTestCase {
    func testDetectsUnsupportedReasoningSummaryNoneAsRetriable() {
        let body = """
        {"error":{"message":"Unsupported value: 'none' is not supported with the 'gpt-5.1-codex-max' model."}}
        """
        XCTAssertTrue(
            SwiftNativeProxyRuntimeService.shouldRetryWithAutoReasoningSummary(
                statusCode: 400,
                bodyText: body
            )
        )
        XCTAssertFalse(
            SwiftNativeProxyRuntimeService.shouldRetryWithAutoReasoningSummary(
                statusCode: 404,
                bodyText: body
            )
        )

        let quotedBody = """
        {"error":{"message":"Unsupported value: \\\"none\\\" for reasoning.summary"}}
        """
        XCTAssertTrue(
            SwiftNativeProxyRuntimeService.shouldRetryWithAutoReasoningSummary(
                statusCode: 400,
                bodyText: quotedBody
            )
        )
    }

    func testPromotesReasoningSummaryNoneToAuto() {
        let payload: [String: Any] = [
            "model": "gpt-5.1-codex-max",
            "reasoning": [
                "effort": "medium",
                "summary": "none"
            ]
        ]
        let adjusted = SwiftNativeProxyRuntimeService.payloadWithAutoReasoningSummaryIfNeeded(payload: payload)
        let reasoning = adjusted?["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")

        let payloadAuto: [String: Any] = [
            "model": "gpt-5.1-codex-max",
            "reasoning": [
                "summary": "auto"
            ]
        ]
        XCTAssertNil(
            SwiftNativeProxyRuntimeService.payloadWithAutoReasoningSummaryIfNeeded(payload: payloadAuto)
        )

        let payloadEffortNone: [String: Any] = [
            "model": "gpt-5.1-codex-max",
            "reasoning": [
                "effort": "none",
                "summary": "auto"
            ]
        ]
        let adjustedEffort = SwiftNativeProxyRuntimeService.payloadWithAutoReasoningSummaryIfNeeded(payload: payloadEffortNone)
        let adjustedReasoning = adjustedEffort?["reasoning"] as? [String: Any]
        XCTAssertEqual(adjustedReasoning?["effort"] as? String, "medium")
    }

    func testNormalizesReasoningSummaryForUpstream() {
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream("none"),
            "auto"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream("  NONE "),
            "auto"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream(nil),
            "auto"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningSummaryForUpstream("concise"),
            "concise"
        )
    }

    func testNormalizesReasoningEffortForUpstream() {
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "none",
                upstreamModel: "gpt-5.1-codex-max"
            ),
            "medium"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream("HIGH"),
            "high"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "xhigh",
                upstreamModel: "gpt-5.3-codex"
            ),
            "xhigh"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "minimal",
                upstreamModel: "gpt-5.3-codex"
            ),
            "medium"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(
                "none",
                upstreamModel: "gpt-4.1"
            ),
            "none"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream("unexpected"),
            "none"
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.normalizedReasoningEffortForUpstream(nil),
            "none"
        )
    }

    func testResolvesUpstreamRouteFamilyByModel() {
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5.4"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5-4"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5-codex-mini"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5-mini"),
            .codex
        )
        XCTAssertEqual(
            SwiftNativeProxyRuntimeService.resolveUpstreamRouteFamily(forUpstreamModel: "gpt-5.2"),
            .codex
        )
    }

    func testResolvesUpstreamBaseURLForBothRouteFamilies() {
        let codexFromOrigin = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com",
            routeFamily: .codex
        )
        XCTAssertEqual(codexFromOrigin, "https://chatgpt.com/backend-api/codex")

        let generalFromOrigin = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com",
            routeFamily: .general
        )
        XCTAssertEqual(generalFromOrigin, "https://chatgpt.com/backend-api")

        let codexFromResponses = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com/backend-api/codex/responses",
            routeFamily: .codex
        )
        XCTAssertEqual(codexFromResponses, "https://chatgpt.com/backend-api/codex")

        let generalFromResponses = SwiftNativeProxyRuntimeService.resolveUpstreamBaseURL(
            configuredBaseURL: "https://chatgpt.com/backend-api/responses",
            routeFamily: .general
        )
        XCTAssertEqual(generalFromResponses, "https://chatgpt.com/backend-api")
    }

    func testHealthAndModelsEndpoints() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let storeRepo = MockStoreRepository()
        let authRepo = MockAuthRepository()
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: authRepo
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertTrue(started.running)
        XCTAssertEqual(started.port, port)
        XCTAssertNotNil(started.apiKey)
        XCTAssertTrue(started.apiKey?.hasPrefix("sk-") == true)

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        let (healthData, healthResponse) = try await URLSession.shared.data(from: healthURL)
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try parseJSON(healthData)["ok"] as? Bool, true)

        let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        var modelsRequest = URLRequest(url: modelsURL)
        modelsRequest.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
        XCTAssertEqual((modelsResponse as? HTTPURLResponse)?.statusCode, 200)

        let modelsJSON = try parseJSON(modelsData)
        let modelItems = modelsJSON["data"] as? [[String: Any]]
        XCTAssertNotNil(modelItems)
        XCTAssertTrue((modelItems?.count ?? 0) > 0)
        let ids = (modelItems ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("gpt-5-4"))
        XCTAssertTrue(ids.contains("gpt-5.4"))
        XCTAssertTrue(ids.contains("gpt-5.3-codex"))
        XCTAssertTrue(ids.contains("gpt-5.2"))

        var modelsByAPIKeyHeader = URLRequest(url: modelsURL)
        modelsByAPIKeyHeader.setValue(started.apiKey ?? "", forHTTPHeaderField: "x-api-key")
        let (_, modelsByAPIKeyHeaderResponse) = try await URLSession.shared.data(for: modelsByAPIKeyHeader)
        XCTAssertEqual((modelsByAPIKeyHeaderResponse as? HTTPURLResponse)?.statusCode, 200)

        let modelAliases = [
            "/models",
            "/v1/models",
            "/v1/v1/models",
            "/codex/v1/models"
        ]
        for route in modelAliases {
            let aliasURL = URL(string: "http://127.0.0.1:\(port)\(route)")!
            var aliasRequest = URLRequest(url: aliasURL)
            aliasRequest.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
            let (_, aliasResponse) = try await URLSession.shared.data(for: aliasRequest)
            XCTAssertEqual((aliasResponse as? HTTPURLResponse)?.statusCode, 200, route)
        }
    }

    func testStartKeepsLegacyPersistedAPIKey() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        try FileManager.default.createDirectory(
            at: paths.proxyDaemonDataDirectory,
            withIntermediateDirectories: true
        )
        let legacyKey = "legacy-proxy-key"
        try legacyKey.write(to: paths.proxyDaemonKeyPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertEqual(started.apiKey, legacyKey)
    }

    func testStartBindsProxyToLoopbackByDefault() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository(),
            lanBaseURLResolver: { port in
                ["http://192.168.0.20:\(port)/v1"]
            }
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertEqual(started.baseURL, "http://127.0.0.1:\(port)/v1")
        XCTAssertTrue(started.lanBaseURLs.isEmpty)

        let listenerDescription = try listeningSocketDescription(for: port)
        XCTAssertTrue(listenerDescription.contains("127.0.0.1:\(port)"), listenerDescription)
    }

    func testStartBindsProxyToAllInterfacesWhenLanAccessEnabled() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(
                store: makeProxyStore(
                    settings: AppSettings(
                        launchAtStartup: false,
                        autoRefreshAccounts: true,
                        autoSmartSwitch: false,
                        autoStartApiProxy: false,
                        allowLanProxyAccess: true,
                        locale: AppLocale.automatic.identifier
                    )
                )
            ),
            authRepository: MockAuthRepository(),
            lanBaseURLResolver: { port in
                ["http://192.168.0.20:\(port)/v1"]
            }
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertEqual(started.baseURL, "http://127.0.0.1:\(port)/v1")
        XCTAssertEqual(started.lanBaseURLs, ["http://192.168.0.20:\(port)/v1"])

        let listenerDescription = try listeningSocketDescription(for: port)
        XCTAssertTrue(listenerDescription.contains("*:\(port)"), listenerDescription)
    }

    func testStatusExposesOnlyCurrentlySelectedAccountAsAvailableCandidate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let primary = makeStoredProxyAccount(
            id: "acct-1",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com"
        )
        let secondary = makeStoredProxyAccount(
            id: "acct-2",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com"
        )
        let selection = CurrentAccountSelection(
            accountID: secondary.accountID,
            accountKey: secondary.accountKey,
            variantKey: secondary.variantKey,
            selectedAt: 1,
            sourceDeviceID: "macos-local"
        )

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(
                store: makeProxyStore(
                    accounts: [primary, secondary],
                    currentSelection: selection
                )
            ),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 21000...29000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        XCTAssertEqual(started.availableAccounts, 1)
    }

    func testProxyRoutesRequestsUsingCurrentlySelectedAccountOnly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_selected",
                "created_at": 123,
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "selected ok"
                    ]]
                ]]
            ])
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let primary = makeStoredProxyAccount(
            id: "acct-1",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            usage: UsageSnapshot(
                fetchedAt: 1,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 5, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 5, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            )
        )
        let secondary = makeStoredProxyAccount(
            id: "acct-2",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            usage: UsageSnapshot(
                fetchedAt: 1,
                planType: "pro",
                fiveHour: UsageWindow(usedPercent: 80, windowSeconds: 18_000, resetAt: nil),
                oneWeek: UsageWindow(usedPercent: 80, windowSeconds: 604_800, resetAt: nil),
                credits: nil
            )
        )
        let selection = CurrentAccountSelection(
            accountID: secondary.accountID,
            accountKey: secondary.accountKey,
            variantKey: secondary.variantKey,
            selectedAt: 1,
            sourceDeviceID: "macos-local"
        )

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(
                store: makeProxyStore(
                    accounts: [primary, secondary],
                    currentSelection: selection
                )
            ),
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "route to selected"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let upstreamRequest = await upstreamProbe.lastRequest
        XCTAssertEqual(upstreamRequest?.headers["authorization"], "Bearer token-secondary")
        XCTAssertEqual(upstreamRequest?.headers["chatgpt-account-id"], "acct-secondary")

        let status = await runtime.status()
        XCTAssertEqual(status.activeAccountID, "acct-secondary")
        XCTAssertEqual(status.activeAccountLabel, "Secondary")
    }

    func testProxyRoutesRequestsUsingExplicitProxySelectionOverCurrentSelection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_proxy_selection",
                "created_at": 123,
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "proxy selection ok"
                    ]]
                ]]
            ])
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let primary = makeStoredProxyAccount(
            id: "acct-1",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com"
        )
        let secondary = makeStoredProxyAccount(
            id: "acct-2",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com"
        )
        let currentSelection = CurrentAccountSelection(
            accountID: secondary.accountID,
            accountKey: secondary.accountKey,
            variantKey: secondary.variantKey,
            selectedAt: 1,
            sourceDeviceID: "macos-local"
        )
        let proxySelection = ProxyAccountSelection(account: primary)

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(
                store: makeProxyStore(
                    accounts: [primary, secondary],
                    currentSelection: currentSelection,
                    proxySelection: proxySelection
                )
            ),
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "route to explicit proxy account"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let upstreamRequest = await upstreamProbe.lastRequest
        XCTAssertEqual(upstreamRequest?.headers["authorization"], "Bearer token-primary")
        XCTAssertEqual(upstreamRequest?.headers["chatgpt-account-id"], "acct-primary")

        let status = await runtime.status()
        XCTAssertEqual(status.activeAccountID, "acct-primary")
        XCTAssertEqual(status.activeAccountLabel, "Primary")
    }

    func testProxyRoutesRequestsUsingAutoUniformLoadAcrossAccounts() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_proxy_uniform",
                "created_at": 123,
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "proxy uniform ok"
                    ]]
                ]]
            ])
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let alpha = makeStoredProxyAccount(
            id: "acct-1",
            label: "Alpha",
            accountID: "acct-alpha",
            accessToken: "token-alpha",
            email: "alpha@example.com"
        )
        let beta = makeStoredProxyAccount(
            id: "acct-2",
            label: "Beta",
            accountID: "acct-beta",
            accessToken: "token-beta",
            email: "beta@example.com"
        )
        let gamma = makeStoredProxyAccount(
            id: "acct-3",
            label: "Gamma",
            accountID: "acct-gamma",
            accessToken: "token-gamma",
            email: "gamma@example.com"
        )

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(
                store: makeProxyStore(
                    accounts: [alpha, beta, gamma],
                    currentSelection: CurrentAccountSelection(
                        accountID: alpha.accountID,
                        accountKey: alpha.accountKey,
                        variantKey: alpha.variantKey,
                        selectedAt: 0,
                        sourceDeviceID: "macos-local"
                    ),
                    proxySelection: .autoUniform
                )
            ),
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        for index in 0..<4 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-5.4",
                "store": false,
                "input": [[
                    "type": "message",
                    "role": "user",
                    "content": [[
                        "type": "input_text",
                        "text": "uniform request \(index)"
                    ]]
                ]]
            ])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }

        let requests = await upstreamProbe.requests
        XCTAssertEqual(requests.map { $0.headers["authorization"] }, [
            "Bearer token-alpha",
            "Bearer token-beta",
            "Bearer token-gamma",
            "Bearer token-alpha"
        ])
        XCTAssertEqual(requests.map { $0.headers["chatgpt-account-id"] }, [
            "acct-alpha",
            "acct-beta",
            "acct-gamma",
            "acct-alpha"
        ])

        let status = await runtime.status()
        XCTAssertEqual(status.availableAccounts, 3)
        XCTAssertEqual(status.activeAccountID, "acct-alpha")
        XCTAssertEqual(status.activeAccountLabel, "Alpha")
    }

    func testSuccessfulProxyRequestDoesNotEmitVerbosePerRequestLogs() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_log_quiet",
                "created_at": 123,
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "ok"
                    ]]
                ]]
            ])
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let logger = RecordingAppLogger()
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository(),
            logger: logger
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "hello"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let scopes = logger.recordedScopes()
        XCTAssertFalse(scopes.contains("proxy.upstream_request_started"))
        XCTAssertFalse(scopes.contains("proxy.upstream_request_succeeded"))
        XCTAssertFalse(scopes.contains("proxy.upstream_attempt_completed"))
    }

    func testSuccessfulStreamingProxyRequestDoesNotEmitVerbosePerRequestLogs() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            Self.streamingResponsesSSE(
                chunks: [
                    "event: response.created\ndata: {\"id\":\"resp_stream_quiet\"}\n\n",
                    "event: response.completed\ndata: [DONE]\n\n"
                ],
                interChunkDelayMilliseconds: 10
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let logger = RecordingAppLogger()
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository(),
            logger: logger
        )

        let proxyPort = Int.random(in: 47001...52000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "input": [["role": "user", "content": "hello"]],
            "stream": true
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (responseBytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)

        var body = Data()
        for try await byte in responseBytes {
            body.append(byte)
        }
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("response.completed"))

        let scopes = logger.recordedScopes()
        XCTAssertFalse(scopes.contains("proxy.upstream_stream_started"))
        XCTAssertFalse(scopes.contains("proxy.upstream_stream_succeeded"))
        XCTAssertFalse(scopes.contains("proxy.upstream_stream_attempt_completed"))
        XCTAssertFalse(scopes.contains("proxy.upstream_stream_attempt_buffered_failure"))
    }

    func testStatusOnlyPublishesLanBaseURLsAfterRestartingIntoLanMode() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let storeRepository = LogTrackingStoreRepository(store: makeProxyStore())
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository,
            authRepository: MockAuthRepository(),
            lanBaseURLResolver: { port in
                ["http://192.168.0.20:\(port)/v1"]
            }
        )

        let port = Int.random(in: 21000...29000)
        _ = try await runtime.start(preferredPort: port)

        storeRepository.store.settings.allowLanProxyAccess = true
        let statusBeforeRestart = await runtime.status()
        XCTAssertTrue(statusBeforeRestart.lanBaseURLs.isEmpty)

        _ = await runtime.stop()
        _ = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let statusAfterRestart = await runtime.status()
        XCTAssertEqual(statusAfterRestart.lanBaseURLs, ["http://192.168.0.20:\(port)/v1"])
    }

    func testResponsesRejectsMissingModelOnAllAliases() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 30000...36000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let routes = [
            "/responses",
            "/v1/responses",
            "/v1/v1/responses",
            "/codex/v1/responses"
        ]

        for route in routes {
            let url = URL(string: "http://127.0.0.1:\(port)\(route)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["input": "hello"])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400, route)

            let json = try parseJSON(data)
            let error = json["error"] as? [String: Any]
            XCTAssertNotNil(error, route)
        }
    }

    func testChatCompletionsRejectsMissingMessagesOnAllAliases() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 36001...42000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let routes = [
            "/chat/completions",
            "/v1/chat/completions",
            "/v1/v1/chat/completions",
            "/codex/v1/chat/completions"
        ]

        for route in routes {
            let url = URL(string: "http://127.0.0.1:\(port)\(route)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-5"])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400, route)

            let json = try parseJSON(data)
            let error = json["error"] as? [String: Any]
            XCTAssertNotNil(error, route)
            XCTAssertEqual(error?["type"] as? String, "invalid_request_error", route)
        }
    }

    func testChatCompletionsRejectsUnsupportedChoiceCount() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 42001...47000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let cases: [Any] = [2, 1.5, true]
        for choiceCount in cases {
            let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-5",
                "n": choiceCount,
                "messages": [
                    [
                        "role": "user",
                        "content": "hello"
                    ]
                ]
            ])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

            let json = try parseJSON(data)
            let error = json["error"] as? [String: Any]
            XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
        }
    }

    func testChatCompletionsRejectsResponsesStyleInputWithoutMessages() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 42001...47000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5",
            "input": "hello from responses"
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        let json = try parseJSON(data)
        let error = json["error"] as? [String: Any]
        XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
    }

    func testCompletionsRejectsUnsupportedChoiceCount() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 42001...47000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let cases: [Any] = [2, 1.5, true]
        for choiceCount in cases {
            let url = URL(string: "http://127.0.0.1:\(port)/v1/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-5",
                "prompt": "hello",
                "n": choiceCount
            ])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

            let json = try parseJSON(data)
            let error = json["error"] as? [String: Any]
            XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
        }
    }

    func testCompletionsRejectsResponsesStyleInputWithoutPrompt() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 42001...47000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5",
            "input": "hello from responses"
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

        let json = try parseJSON(data)
        let error = json["error"] as? [String: Any]
        XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
        XCTAssertEqual(error?["message"] as? String, "Completions request missing prompt.")
    }

    func testCompletionsRejectsUnsupportedLegacyParameters() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 42001...47000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let cases: [[String: Any]] = [
            [
                "model": "gpt-5",
                "prompt": "hello",
                "suffix": "world"
            ],
            [
                "model": "gpt-5",
                "prompt": "hello",
                "best_of": 2
            ],
            [
                "model": "gpt-5",
                "prompt": "hello",
                "echo": true
            ],
            [
                "model": "gpt-5",
                "prompt": "hello",
                "echo": 0
            ],
            [
                "model": "gpt-5",
                "prompt": "hello",
                "logprobs": 2
            ],
            [
                "model": "gpt-5",
                "prompt": "hello",
                "logit_bias": [
                    "42": 10
                ]
            ]
        ]

        for body in cases {
            let url = URL(string: "http://127.0.0.1:\(port)/v1/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

            let json = try parseJSON(data)
            let error = json["error"] as? [String: Any]
            XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
        }
    }

    func testCompletionsRejectsTokenArrayPromptShapes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: MockStoreRepository(),
            authRepository: MockAuthRepository()
        )

        let port = Int.random(in: 42001...47000)
        let started = try await runtime.start(preferredPort: port)
        defer {
            Task { _ = await runtime.stop() }
        }

        let cases: [[String: Any]] = [
            [
                "model": "gpt-5",
                "prompt": [1, 2, 3]
            ],
            [
                "model": "gpt-5",
                "prompt": [
                    [1, 2, 3],
                    [4, 5, 6]
                ]
            ]
        ]

        for body in cases {
            let url = URL(string: "http://127.0.0.1:\(port)/v1/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)

            let json = try parseJSON(data)
            let error = json["error"] as? [String: Any]
            XCTAssertEqual(error?["type"] as? String, "invalid_request_error")
            XCTAssertEqual(
                error?["message"] as? String,
                "Token array prompts are not supported for completions."
            )
        }
    }

    func testChatCompletionsProxyForwardsToConfiguredUpstream() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 42001...47000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            let sse = """
            data: {"type":"response.completed","response":{"id":"resp_1","created_at":123,"model":"gpt-5.4","output":[{"type":"message","content":[{"type":"output_text","text":"hello from upstream"}]}],"usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8}}}

            data: [DONE]

            """
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data(sse.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 47001...52000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/codex/v1/chat/completions?trace=chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "temperature": 0.2,
            "top_p": 0.9,
            "stream_options": [
                "include_usage": true
            ],
            "metadata": [
                "source": "test-suite"
            ],
            "service_tier": "auto",
            "messages": [
                [
                    "role": "system",
                    "content": "Be concise."
                ],
                [
                    "role": "user",
                    "content": "hello"
                ]
            ]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("chat-test", forHTTPHeaderField: "Idempotency-Key")
        request.setValue("responses=v1", forHTTPHeaderField: "OpenAI-Beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try parseJSON(data)
        XCTAssertEqual(json["object"] as? String, "chat.completion")
        XCTAssertEqual(json["model"] as? String, "gpt-5-4")
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        XCTAssertEqual(message?["role"] as? String, "assistant")
        XCTAssertEqual(message?["content"] as? String, "hello from upstream")

        let upstreamRequest = await upstreamProbe.lastRequest
        XCTAssertEqual(upstreamRequest?.path, "/backend-api/codex/responses")
        XCTAssertEqual(upstreamRequest?.target, "/backend-api/codex/responses?trace=chat")
        XCTAssertEqual(upstreamRequest?.headers["authorization"], "Bearer token")
        XCTAssertEqual(upstreamRequest?.headers["chatgpt-account-id"], "acct")
        XCTAssertEqual(upstreamRequest?.headers["idempotency-key"], "chat-test")
        XCTAssertEqual(upstreamRequest?.headers["openai-beta"], "responses=v1")

        let upstreamBody = try XCTUnwrap(upstreamRequest?.jsonBody)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["temperature"] as? Double, 0.2)
        XCTAssertEqual(upstreamBody["top_p"] as? Double, 0.9)
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])
        XCTAssertEqual(upstreamBody["instructions"] as? String, "Be concise.")
        XCTAssertEqual((upstreamBody["metadata"] as? [String: Any])?["source"] as? String, "test-suite")
        XCTAssertEqual(upstreamBody["service_tier"] as? String, "auto")
        XCTAssertNil(upstreamBody["stream_options"])
        XCTAssertNil(upstreamBody["messages"])
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    func testChatCompletionsNormalizesOpenCodeStyleAliasesForCodexUpstream() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 47001...52000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            let sse = """
            data: {"type":"response.completed","response":{"id":"resp_aliases","created_at":123,"model":"gpt-5.4","output":[{"type":"message","content":[{"type":"output_text","text":"hello from upstream"}]}],"usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8}}}

            data: [DONE]

            """
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data(sse.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 47001...52000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "reasoningSummary": "auto",
            "reasoning_effort": "medium",
            "verbosity": "low",
            "stream": true,
            "stream_options": [
                "include_usage": true
            ],
            "messages": [
                [
                    "role": "system",
                    "content": "You are OpenCode."
                ],
                [
                    "role": "user",
                    "content": "hello"
                ]
            ]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let upstreamRequest = await upstreamProbe.lastRequest
        let upstreamBody = try XCTUnwrap(upstreamRequest?.jsonBody)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertNil(upstreamBody["stream_options"])
        XCTAssertNil(upstreamBody["reasoningSummary"])
        XCTAssertNil(upstreamBody["verbosity"])

        let reasoning = upstreamBody["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")

        let text = upstreamBody["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "low")
    }

    func testCompletionsProxyForwardsToConfiguredUpstream() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 47001...52000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data("""
                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_legacy","created_at":123,"model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"legacy hello"}]}],"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}

                """.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/completions?trace=legacy")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "prompt": "legacy prompt",
            "temperature": 0.4
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("legacy-test", forHTTPHeaderField: "Idempotency-Key")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try parseJSON(data)
        XCTAssertEqual(json["object"] as? String, "text_completion")
        XCTAssertEqual(json["model"] as? String, "gpt-5-4")
        let choices = json["choices"] as? [[String: Any]]
        XCTAssertEqual(choices?.first?["text"] as? String, "legacy hello")

        let upstreamRequest = await upstreamProbe.lastRequest
        XCTAssertEqual(upstreamRequest?.target, "/backend-api/codex/responses?trace=legacy")
        XCTAssertEqual(upstreamRequest?.headers["idempotency-key"], "legacy-test")

        let upstreamBody = try XCTUnwrap(upstreamRequest?.jsonBody)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["temperature"] as? Double, 0.4)
        XCTAssertEqual(
            upstreamBody["instructions"] as? String,
            SwiftNativeProxyRuntimeService.defaultRequiredInstructions
        )
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "legacy prompt")
    }

    func testCompletionsSupportsBatchedPromptArray() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 47001...52000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            let prompt: String
            if let input = await upstreamProbe.lastRequest?.jsonBody["input"] as? [[String: Any]],
               let content = input.first?["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                prompt = text
            } else {
                prompt = ""
            }
            let text = prompt == "first prompt" ? "first result" : "second result"
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data("""
                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_batch","created_at":321,"model":"gpt-5.4","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\(text)"}]}],"usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}

                """.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "prompt": ["first prompt", "second prompt"]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try parseJSON(data)
        let choices = try XCTUnwrap(json["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices[0]["text"] as? String, "first result")
        XCTAssertEqual(choices[1]["text"] as? String, "second result")
        XCTAssertEqual((json["usage"] as? [String: Any])?["total_tokens"] as? Int, 6)

        let requests = await upstreamProbe.requests
        XCTAssertEqual(requests.count, 2)
        let firstInput = try XCTUnwrap(requests.first?.jsonBody["input"] as? [[String: Any]])
        let lastInput = try XCTUnwrap(requests.last?.jsonBody["input"] as? [[String: Any]])
        XCTAssertEqual(((firstInput.first?["content"] as? [[String: Any]])?.first?["text"]) as? String, "first prompt")
        XCTAssertEqual(((lastInput.first?["content"] as? [[String: Any]])?.first?["text"]) as? String, "second prompt")
    }

    func testCompletionsMapsIncompleteMaxOutputTokensToLengthFinishReason() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 47001...52000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data("""
                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_length","created_at":123,"model":"gpt-5.4","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"truncated"}]}]}}

                """.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "prompt": "hello"
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try parseJSON(data)
        let choices = json["choices"] as? [[String: Any]]
        XCTAssertEqual(choices?.first?["finish_reason"] as? String, "length")
    }

    func testResponsesCompactProxyForwardsToConfiguredUpstream() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 52001...57000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse.json(statusCode: 200, object: [
                "type": "response.compact",
                "model": "gpt-5.4",
                "items": [
                    [
                        "type": "compaction",
                        "encrypted_content": "encrypted"
                    ]
                ]
            ])
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 57001...62000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/codex/v1/responses/compact")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "input": "hello compact"
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let json = try parseJSON(data)
        XCTAssertEqual(json["type"] as? String, "response.compact")
        XCTAssertEqual(json["model"] as? String, "gpt-5.4")

        let upstreamRequest = await upstreamProbe.lastRequest
        XCTAssertEqual(upstreamRequest?.path, "/backend-api/codex/responses/compact")
        XCTAssertEqual(upstreamRequest?.headers["authorization"], "Bearer token")
        XCTAssertEqual(upstreamRequest?.headers["chatgpt-account-id"], "acct")

        let upstreamBody = try XCTUnwrap(upstreamRequest?.jsonBody)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hello compact")
    }

    func testResponsesPreservesUpstreamStatusHeadersAndQuery() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse(
                statusCode: 429,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Retry-After": "7",
                    "X-Request-Id": "req_test_429"
                ],
                body: Data(#"{"error":{"message":"rate limited"}}"#.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 20000...20999)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses?trace=response")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "input": "hello",
            "store": true
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("response-test", forHTTPHeaderField: "Idempotency-Key")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 429)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Retry-After"), "7")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Request-Id"), "req_test_429")

        let json = try parseJSON(data)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "rate limited")

        let upstreamRequest = await upstreamProbe.lastRequest
        XCTAssertEqual(upstreamRequest?.target, "/backend-api/codex/responses?trace=response")
        XCTAssertEqual(upstreamRequest?.headers["idempotency-key"], "response-test")

        let upstreamBody = try XCTUnwrap(upstreamRequest?.jsonBody)
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertEqual(
            upstreamBody["instructions"] as? String,
            SwiftNativeProxyRuntimeService.defaultRequiredInstructions
        )
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "hello")
    }

    func testResponsesStreamingStartsBeforeUpstreamCompletes() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 52001...57000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            Self.streamingResponsesSSE(
                chunks: [
                    """
                    event: response.created
                    data: {"type":"response.created","response":{"id":"resp_stream","created_at":123,"model":"gpt-5.4"}}

                    """,
                    """
                    event: response.completed
                    data: {"type":"response.completed","response":{"id":"resp_stream","created_at":123,"model":"gpt-5.4","output":[{"type":"message","content":[{"type":"output_text","text":"stream ok"}]}]}}

                    data: [DONE]

                    """
                ],
                interChunkDelayMilliseconds: 350
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 47001...52000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "input": [
                [
                    "role": "user",
                    "content": "hello"
                ]
            ],
            "stream": true
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let start = Date()
        let (responseBytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue((response.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream"))

        var iterator = responseBytes.makeAsyncIterator()
        var partial = Data()
        while let byte = try await iterator.next() {
            partial.append(byte)
            if String(data: partial, encoding: .utf8)?.contains("response.created") == true {
                break
            }
        }

        let firstChunkDelay = Date().timeIntervalSince(start)
        XCTAssertLessThan(firstChunkDelay, 0.25)

        while let byte = try await iterator.next() {
            partial.append(byte)
        }

        let fullText = String(data: partial, encoding: .utf8) ?? ""
        XCTAssertTrue(fullText.contains("response.completed"))
        XCTAssertTrue(fullText.contains("stream ok"))
    }

    func testOpenCodeResponsesTitleFixtureCanonicalizesUpstreamPayload() async throws {
        let roundTrip = try await exerciseFixtureProxyRequest(
            route: "/v1/responses",
            fixtureName: "opencode_responses_title",
            upstreamResponse: completedResponsesSSE(text: "title ok")
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])
        XCTAssertEqual((upstreamBody["include"] as? [String]) ?? [], ["reasoning.encrypted_content"])
        XCTAssertEqual((upstreamBody["reasoning"] as? [String: Any])?["effort"] as? String, "low")

        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "developer")
        let firstContent = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(firstContent.first?["type"] as? String, "input_text")
    }

    func testOpenCodeResponsesMainFixtureCanonicalizesUpstreamPayload() async throws {
        let roundTrip = try await exerciseFixtureProxyRequest(
            route: "/v1/responses",
            fixtureName: "opencode_responses_main",
            upstreamResponse: completedResponsesSSE(text: "main ok")
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertNil(upstreamBody["stream_options"])
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])

        let reasoning = upstreamBody["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")

        let text = upstreamBody["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "low")
        XCTAssertEqual((upstreamBody["tools"] as? [[String: Any]])?.count, 1)
        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "developer")
    }

    func testOpenCodeChatCompletionsFixtureCanonicalizesUpstreamPayload() async throws {
        let roundTrip = try await exerciseFixtureProxyRequest(
            route: "/v1/chat/completions",
            fixtureName: "opencode_chat_completions",
            upstreamResponse: completedResponsesSSE(text: "chat ok")
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertNil(upstreamBody["stream_options"])
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])

        let reasoning = upstreamBody["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")

        let text = upstreamBody["text"] as? [String: Any]
        XCTAssertEqual(text?["verbosity"] as? String, "low")
        XCTAssertTrue((upstreamBody["instructions"] as? String)?.contains("You are OpenCode") == true)

        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    func testCodexCLIResponsesFixtureCanonicalizesUpstreamPayload() async throws {
        let roundTrip = try await exerciseFixtureProxyRequest(
            route: "/codex/v1/responses",
            fixtureName: "codex_cli_responses_minimal",
            upstreamResponse: completedResponsesSSE(text: "cli ok")
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertEqual(upstreamBody["store"] as? Bool, false)
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])

        let input = try XCTUnwrap(upstreamBody["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "message")
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    func testResponsesStripsCodexTokenLimitParameters() async throws {
        let storeRepository = LogTrackingStoreRepository(store: makeProxyStore())
        let logger = RecordingAppLogger()
        let roundTrip = try await exerciseProxyRequest(
            route: "/v1/responses",
            requestObject: [
                "model": "gpt-5.4",
                "input": "hello",
                "max_output_tokens": 128
            ],
            upstreamResponse: completedResponsesSSE(text: "hello"),
            storeRepository: storeRepository,
            logger: logger
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])
        XCTAssertTrue(try storeRepository.loadStore().proxyLiveTestLogs.isEmpty)
        XCTAssertEqual(storeRepository.proxyLogSaveCount, 0)
        XCTAssertEqual(
            logger.recordedScopes().filter { $0 == "proxy.compatibility_warning" }.count,
            1
        )
    }

    func testRepeatedCompatibilityWarningsAreThrottledBeforePersisting() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 47001...52000)
        let upstreamResponse = HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream; charset=utf-8"],
            body: Data("""
            data: {"type":"response.completed","response":{"id":"resp_fixture","created_at":123,"model":"gpt-5.4","output":[{"type":"message","content":[{"type":"output_text","text":"hello"}]}]}}

            data: [DONE]

            """.utf8)
        )
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            upstreamResponse
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepository = LogTrackingStoreRepository(store: makeProxyStore())
        let dateProvider = MutableDateProvider(now: 1_763_300_000)
        let logger = RecordingAppLogger()
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository,
            authRepository: MockAuthRepository(),
            dateProvider: dateProvider,
            logger: logger
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let requestObject: [String: Any] = [
            "model": "gpt-5.4",
            "input": "hello",
            "max_output_tokens": 128
        ]

        func makeRequest() throws -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: requestObject)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")
            return request
        }

        _ = try await URLSession.shared.data(for: makeRequest())
        XCTAssertEqual(try storeRepository.loadStore().proxyLiveTestLogs.count, 0)
        XCTAssertEqual(storeRepository.proxyLogSaveCount, 0)
        let warningLogsAfterFirstRequest = logger.recordedScopes().filter { $0 == "proxy.compatibility_warning" }.count
        XCTAssertEqual(warningLogsAfterFirstRequest, 1)

        _ = try await URLSession.shared.data(for: makeRequest())
        XCTAssertEqual(try storeRepository.loadStore().proxyLiveTestLogs.count, 0)
        XCTAssertEqual(storeRepository.proxyLogSaveCount, 0)
        XCTAssertEqual(
            logger.recordedScopes().filter { $0 == "proxy.compatibility_warning" }.count,
            warningLogsAfterFirstRequest
        )

        dateProvider.now += 301
        _ = try await URLSession.shared.data(for: makeRequest())
        XCTAssertEqual(try storeRepository.loadStore().proxyLiveTestLogs.count, 0)
        XCTAssertEqual(storeRepository.proxyLogSaveCount, 0)
        XCTAssertEqual(
            logger.recordedScopes().filter { $0 == "proxy.compatibility_warning" }.count,
            2
        )
    }

    func testChatCompletionsStripsCodexTokenLimitParameters() async throws {
        let roundTrip = try await exerciseProxyRequest(
            route: "/v1/chat/completions",
            requestObject: [
                "model": "gpt-5.4",
                "messages": [
                    [
                        "role": "user",
                        "content": "hello"
                    ]
                ],
                "max_tokens": 128
            ],
            upstreamResponse: completedResponsesSSE(text: "hello")
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])
    }

    func testCompletionsStripsCodexTokenLimitParameters() async throws {
        let roundTrip = try await exerciseProxyRequest(
            route: "/v1/completions",
            requestObject: [
                "model": "gpt-5.4",
                "prompt": "hello",
                "max_tokens": 128
            ],
            upstreamResponse: completedResponsesSSE(text: "hello")
        )

        let upstreamBody = roundTrip.snapshot.jsonBody
        XCTAssertEqual(upstreamBody["model"] as? String, "gpt-5.4")
        XCTAssertNil(upstreamBody["max_tokens"])
        XCTAssertNil(upstreamBody["max_output_tokens"])
    }

    func testResponsesPreservesExplicitInstructions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 52001...57000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data("event: response.completed\ndata: {\"id\":\"resp_1\",\"object\":\"response\",\"model\":\"gpt-5.4\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}\n\n".utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepo = StaticStoreRepository(
            store: AccountsStore(
                accounts: [
                    StoredAccount(
                        id: "acct-1",
                        label: "Primary",
                        email: "proxy@example.com",
                        accountID: "acct",
                        planType: "pro",
                        teamName: nil,
                        teamAlias: nil,
                        authJSON: .object(["tokens": .object(["access_token": .string("token"), "account_id": .string("acct"), "id_token": .string("id-token")])]),
                        addedAt: 0,
                        updatedAt: 0,
                        usage: nil,
                        usageError: nil
                    )
                ]
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepo,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 57001...62000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-4",
            "instructions": "Use markdown bullets.",
            "input": "hello"
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let upstreamRequest = await upstreamProbe.lastRequest
        let upstreamBody = try XCTUnwrap(upstreamRequest?.jsonBody)
        XCTAssertEqual(upstreamBody["instructions"] as? String, "Use markdown bullets.")
    }

    func testPayloadOversizeDetectionFromContentLengthHeader() {
        let oversized = ProxyRuntimeLimits.maxInboundRequestBytes + 1
        let raw = """
        POST /v1/responses HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: \(oversized)\r
        Content-Type: application/json\r
        \r
        {}
        """
        let buffer = Data(raw.utf8)
        XCTAssertTrue(SimpleHTTPServer.isPayloadOversized(buffer: buffer))
    }

    func testPayloadOversizeDetectionFromBufferedBytes() {
        let buffer = Data(repeating: 65, count: ProxyRuntimeLimits.maxInboundRequestBytes + 1)
        XCTAssertTrue(SimpleHTTPServer.isPayloadOversized(buffer: buffer))
    }

    func testPayloadOversizeDoesNotTriggerUnderLimit() {
        let allowed = ProxyRuntimeLimits.maxInboundRequestBytes - 128
        let raw = """
        POST /v1/responses HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Length: \(allowed)\r
        Content-Type: application/json\r
        \r
        {}
        """
        let buffer = Data(raw.utf8)
        XCTAssertFalse(SimpleHTTPServer.isPayloadOversized(buffer: buffer))
    }

    private func exerciseFixtureProxyRequest(
        route: String,
        fixtureName: String,
        upstreamResponse: HTTPResponse
    ) async throws -> (data: Data, response: HTTPURLResponse, snapshot: UpstreamRequestProbe.Snapshot) {
        let fixture = try loadFixtureJSON(named: fixtureName)
        return try await exerciseProxyRequest(
            route: route,
            requestObject: fixture,
            upstreamResponse: upstreamResponse
        )
    }

    private func exerciseProxyRequest(
        route: String,
        requestObject: [String: Any],
        upstreamResponse: HTTPResponse,
        storeRepository: AccountsStoreRepository? = nil,
        logger: AppLogger = NoopAppLogger.shared
    ) async throws -> (data: Data, response: HTTPURLResponse, snapshot: UpstreamRequestProbe.Snapshot) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 47001...52000)
        let upstreamProbe = UpstreamRequestProbe()
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { request in
            await upstreamProbe.record(request: request)
            return upstreamResponse
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository ?? StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository(),
            logger: logger
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)\(route)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: requestObject)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
        XCTAssertEqual(response.statusCode, 200)

        let snapshot = await upstreamProbe.lastRequest
        let unwrappedSnapshot = try XCTUnwrap(snapshot)
        return (data, response, unwrappedSnapshot)
    }

    private func loadFixtureJSON(named name: String) throws -> [String: Any] {
        let fixturesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Proxy", isDirectory: true)
        let url = fixturesDirectory.appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        return try parseJSON(data)
    }

    private func completedResponsesSSE(text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream; charset=utf-8"],
            body: Data("""
            data: {"type":"response.completed","response":{"id":"resp_fixture","created_at":123,"model":"gpt-5.4","output":[{"type":"message","content":[{"type":"output_text","text":"\(text)"}]}]}}

            data: [DONE]

            """.utf8)
        )
    }

    private static func streamingResponsesSSE(
        chunks: [String],
        interChunkDelayMilliseconds: UInt64
    ) -> HTTPResponse {
        HTTPResponse.stream(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream; charset=utf-8"],
            body: AsyncThrowingStream { continuation in
                Task {
                    for (index, chunk) in chunks.enumerated() {
                        continuation.yield(Data(chunk.utf8))
                        if index < chunks.count - 1 {
                            try? await Task.sleep(for: .milliseconds(interChunkDelayMilliseconds))
                        }
                    }
                    continuation.finish()
                }
            }
        )
    }

    func testStatusAccumulatesRequestAndTokenMetrics() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_metrics",
                "created_at": 123,
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "metrics ok"
                    ]]
                ]],
                "usage": [
                    "input_tokens": 12,
                    "output_tokens": 7,
                    "total_tokens": 19
                ]
            ])
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "hello metrics"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let status = await runtime.status()
        XCTAssertEqual(status.metrics.inFlightRequests, 0)
        XCTAssertEqual(status.metrics.totalRequests, 1)
        XCTAssertEqual(status.metrics.successfulRequests, 1)
        XCTAssertEqual(status.metrics.failedRequests, 0)
        XCTAssertEqual(status.metrics.promptTokens, 12)
        XCTAssertEqual(status.metrics.completionTokens, 7)
        XCTAssertEqual(status.metrics.totalTokens, 19)
        XCTAssertNotNil(status.metrics.lastResponseAt)
    }

    func testStatusTracksInFlightStreamingResponsesRequest() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            HTTPResponse.stream(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: AsyncThrowingStream { continuation in
                    Task {
                        continuation.yield(Data(#"data: {"type":"response.created","response":{"id":"resp_stream","created_at":123,"model":"gpt-5.4"}}"# .utf8))
                        continuation.yield(Data("\n\n".utf8))
                        try? await Task.sleep(for: .milliseconds(400))
                        continuation.yield(Data(#"data: {"type":"response.completed","response":{"id":"resp_stream","created_at":123,"model":"gpt-5.4","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"stream ok"}]}],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}"# .utf8))
                        continuation.yield(Data("\n\n".utf8))
                        continuation.yield(Data("data: [DONE]\n\n".utf8))
                        continuation.finish()
                    }
                }
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: StaticStoreRepository(store: makeProxyStore()),
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        let streamStarted = expectation(description: "stream started")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "stream": true,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "hello stream"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let responseTask = Task {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            _ = response
            streamStarted.fulfill()

            var iterator = bytes.makeAsyncIterator()
            while let _ = try await iterator.next() {}
        }

        await fulfillment(of: [streamStarted], timeout: 1.0)
        let inFlightStatus = await runtime.status()
        XCTAssertEqual(inFlightStatus.metrics.inFlightRequests, 1)
        XCTAssertEqual(inFlightStatus.metrics.totalRequests, 1)
        XCTAssertEqual(inFlightStatus.metrics.successfulRequests, 0)

        _ = try await responseTask.value

        let completedStatus = await runtime.status()
        XCTAssertEqual(completedStatus.metrics.inFlightRequests, 0)
        XCTAssertEqual(completedStatus.metrics.totalRequests, 1)
        XCTAssertEqual(completedStatus.metrics.successfulRequests, 1)
        XCTAssertEqual(completedStatus.metrics.failedRequests, 0)
        XCTAssertEqual(completedStatus.metrics.promptTokens, 4)
        XCTAssertEqual(completedStatus.metrics.completionTokens, 2)
        XCTAssertEqual(completedStatus.metrics.totalTokens, 6)
        XCTAssertNotNil(completedStatus.metrics.lastResponseAt)
    }

    func testProxyMetricsPersistIntoAccountsStoreAfterCompletedRequest() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data("""
                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_metrics_store","created_at":123,"model":"gpt-5.4","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"stored"}]}],"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}

                """.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepository = MutableStoreRepository(store: makeProxyStore())
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "persist metrics"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let persisted = try storeRepository.loadStore().proxyMetrics
        XCTAssertEqual(persisted.inFlightRequests, 0)
        XCTAssertEqual(persisted.totalRequests, 1)
        XCTAssertEqual(persisted.successfulRequests, 1)
        XCTAssertEqual(persisted.failedRequests, 0)
        XCTAssertEqual(persisted.promptTokens, 3)
        XCTAssertEqual(persisted.completionTokens, 2)
        XCTAssertEqual(persisted.totalTokens, 5)
        XCTAssertNotNil(persisted.lastResponseAt)
    }

    func testStatusLoadsPersistedProxyMetricsAndClearsTransientInFlightCount() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )

        let storeRepository = MutableStoreRepository(
            store: makeProxyStore().withPersistedProxyMetrics(
                ApiProxyMetrics(
                    inFlightRequests: 4,
                    totalRequests: 12,
                    successfulRequests: 10,
                    failedRequests: 2,
                    promptTokens: 120,
                    completionTokens: 45,
                    totalTokens: 165,
                    lastResponseAt: 1_763_200_000
                )
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository,
            authRepository: MockAuthRepository()
        )

        let status = await runtime.status()
        XCTAssertEqual(status.metrics.inFlightRequests, 0)
        XCTAssertEqual(status.metrics.totalRequests, 12)
        XCTAssertEqual(status.metrics.successfulRequests, 10)
        XCTAssertEqual(status.metrics.failedRequests, 2)
        XCTAssertEqual(status.metrics.promptTokens, 120)
        XCTAssertEqual(status.metrics.completionTokens, 45)
        XCTAssertEqual(status.metrics.totalTokens, 165)
        XCTAssertEqual(status.metrics.lastResponseAt, 1_763_200_000)
    }

    func testResetMetricsClearsRuntimeAndPersistedProxyMetrics() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let upstreamPort = Int.random(in: 62001...65000)
        let upstreamServer = try SimpleHTTPServer(port: UInt16(upstreamPort)) { _ in
            HTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                body: Data("""
                event: response.completed
                data: {"type":"response.completed","response":{"id":"resp_reset_metrics","created_at":123,"model":"gpt-5.4","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"reset ok"}]}],"usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}}

                """.utf8)
            )
        }
        upstreamServer.start()
        defer { upstreamServer.stop() }

        let paths = FileSystemPaths(
            applicationSupportDirectory: tempDir,
            accountStorePath: tempDir.appendingPathComponent("accounts.json"),
            codexAuthPath: tempDir.appendingPathComponent("auth.json"),
            codexConfigPath: tempDir.appendingPathComponent("config.toml"),
            proxyDaemonDataDirectory: tempDir.appendingPathComponent("proxyd", isDirectory: true),
            proxyDaemonKeyPath: tempDir.appendingPathComponent("proxyd/api-proxy.key")
        )
        try """
        chatgpt_base_url = "http://127.0.0.1:\(upstreamPort)"
        """.write(to: paths.codexConfigPath, atomically: true, encoding: .utf8)

        let storeRepository = MutableStoreRepository(
            store: makeProxyStore().withPersistedProxyMetrics(
                ApiProxyMetrics(
                    inFlightRequests: 0,
                    totalRequests: 9,
                    successfulRequests: 8,
                    failedRequests: 1,
                    promptTokens: 90,
                    completionTokens: 30,
                    totalTokens: 120,
                    lastResponseAt: 1_763_200_100
                )
            )
        )
        let runtime = SwiftNativeProxyRuntimeService(
            paths: paths,
            storeRepository: storeRepository,
            authRepository: MockAuthRepository()
        )

        let proxyPort = Int.random(in: 52001...57000)
        let started = try await runtime.start(preferredPort: proxyPort)
        defer {
            Task { _ = await runtime.stop() }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "store": false,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "reset metrics"
                ]]
            ]]
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(started.apiKey ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let statusBeforeReset = await runtime.status()
        XCTAssertEqual(statusBeforeReset.metrics.totalRequests, 10)
        XCTAssertNotNil(statusBeforeReset.activeAccountID)

        let resetStatus = try await runtime.resetMetrics()
        XCTAssertEqual(resetStatus.metrics, .empty)
        XCTAssertNil(resetStatus.activeAccountID)
        XCTAssertNil(resetStatus.activeAccountLabel)
        XCTAssertNil(resetStatus.lastError)

        let persisted = try storeRepository.loadStore().proxyMetrics
        XCTAssertEqual(persisted, .empty)
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private func listeningSocketDescription(for port: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [
            "-Pan",
            "-p", String(getpid()),
            "-iTCP:\(port)",
            "-sTCP:LISTEN"
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makeProxyStore(
        settings: AppSettings = .defaultValue,
        accounts: [StoredAccount]? = nil,
        currentSelection: CurrentAccountSelection? = nil,
        proxySelection: ProxyAccountSelection? = nil
    ) -> AccountsStore {
        let resolvedAccounts = accounts ?? [makeStoredProxyAccount()]
        return AccountsStore(
            accounts: resolvedAccounts,
            currentSelection: currentSelection ?? resolvedAccounts.first.map {
                CurrentAccountSelection(
                    accountID: $0.accountID,
                    accountKey: $0.accountKey,
                    variantKey: $0.variantKey,
                    selectedAt: 0,
                    sourceDeviceID: "macos-local"
                )
            },
            proxySelection: proxySelection,
            settings: settings
        )
    }

    private func makeStoredProxyAccount(
        id: String = "acct-1",
        label: String = "Primary",
        accountID: String = "acct",
        accessToken: String = "token",
        email: String = "proxy@example.com",
        usage: UsageSnapshot? = nil
    ) -> StoredAccount {
        StoredAccount(
            id: id,
            label: label,
            email: email,
            accountID: accountID,
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string(accessToken),
                    "account_id": .string(accountID),
                    "id_token": .string("id-token-\(id)")
                ])
            ]),
            addedAt: 0,
            updatedAt: 0,
            usage: usage,
            usageError: nil
        )
    }
}

private final class MockStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private let store: AccountsStore

    init(store: AccountsStore = {
        let account = StoredAccount(
            id: "acct-1",
            label: "Primary",
            email: "proxy@example.com",
            accountID: "acct",
            planType: "pro",
            teamName: nil,
            teamAlias: nil,
            authJSON: .object([
                "tokens": .object([
                    "access_token": .string("token"),
                    "account_id": .string("acct"),
                    "id_token": .string("id-token")
                ])
            ]),
            addedAt: 0,
            updatedAt: 0,
            usage: nil,
            usageError: nil
        )
        return AccountsStore(
            accounts: [account],
            currentSelection: CurrentAccountSelection(
                accountID: account.accountID,
                accountKey: account.accountKey,
                variantKey: account.variantKey,
                selectedAt: 0,
                sourceDeviceID: "macos-local"
            )
        )
    }()) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
    }
}

private final class RecordingAppLogger: AppLogger, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecordingAppLogger")
    private var scopes: [String] = []

    func log(
        _ level: LogLevel,
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String : String],
        operationID: String?
    ) {
        _ = level
        _ = message
        _ = metadata
        _ = operationID
        queue.sync {
            scopes.append("\(category.rawValue).\(event)")
        }
    }

    func recordedScopes() -> [String] {
        queue.sync { scopes }
    }

    func loadEntries(limit: Int) async throws -> [AppLogEntry] {
        _ = limit
        return []
    }

    func loadCombinedText(limit: Int) async throws -> String {
        _ = limit
        return ""
    }

    func clearLogs() async throws {
        queue.sync {
            scopes.removeAll()
        }
    }

    func logsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }
}

private final class StaticStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private let store: AccountsStore

    init(store: AccountsStore) {
        self.store = store.withDefaultCurrentSelectionIfNeeded()
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        _ = store
    }
}

private final class MutableStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    var store: AccountsStore
    private(set) var saveCount = 0

    init(store: AccountsStore) {
        self.store = store.withDefaultCurrentSelectionIfNeeded()
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store.withDefaultCurrentSelectionIfNeeded()
        saveCount += 1
    }
}

private final class LogTrackingStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    var store: AccountsStore
    private(set) var proxyLogSaveCount = 0

    init(store: AccountsStore) {
        self.store = store.withDefaultCurrentSelectionIfNeeded()
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        if store.proxyLiveTestLogs != self.store.proxyLiveTestLogs {
            proxyLogSaveCount += 1
        }
        self.store = store.withDefaultCurrentSelectionIfNeeded()
    }
}

private final class MutableDateProvider: DateProviding, @unchecked Sendable {
    var now: Int64

    init(now: Int64) {
        self.now = now
    }

    func unixSecondsNow() -> Int64 {
        now
    }
}

private extension AccountsStore {
    func withDefaultCurrentSelectionIfNeeded() -> AccountsStore {
        guard currentSelection == nil, let first = accounts.first else {
            return self
        }

        var copy = self
        copy.currentSelection = CurrentAccountSelection(
            accountID: first.accountID,
            accountKey: first.accountKey,
            variantKey: first.variantKey,
            selectedAt: 0,
            sourceDeviceID: "macos-local"
        )
        return copy
    }

    func withPersistedProxyMetrics(_ metrics: ApiProxyMetrics) -> AccountsStore {
        var copy = self
        copy.proxyMetrics = metrics
        return copy
    }
}

private final class MockAuthRepository: AuthRepository, @unchecked Sendable {
    func readCurrentAuth() throws -> JSONValue { .null }
    func readCurrentAuthOptional() throws -> JSONValue? { nil }
    func readAuth(from url: URL) throws -> JSONValue {
        _ = url
        return .null
    }
    func writeCurrentAuth(_ auth: JSONValue) throws {}
    func removeCurrentAuth() throws {}
    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        _ = tokens
        return .null
    }
    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        try ExtractedAuth.fromStoredAuth(auth)
    }
    func currentAuthAccountID() -> String? { nil }
}

private actor UpstreamRequestProbe {
    struct Snapshot {
        var target: String
        var path: String
        var headers: [String: String]
        var body: Data

        var jsonBody: [String: Any] {
            ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        }
    }

    private(set) var lastRequest: Snapshot?
    private(set) var requests: [Snapshot] = []

    func record(request: HTTPRequest) {
        let snapshot = Snapshot(target: request.target, path: request.path, headers: request.headers, body: request.body)
        lastRequest = snapshot
        requests.append(snapshot)
    }
}
