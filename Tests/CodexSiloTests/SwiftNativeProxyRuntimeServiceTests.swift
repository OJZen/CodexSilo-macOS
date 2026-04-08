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

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5",
            "n": 2,
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
            "max_completion_tokens": 256,
            "metadata": [
                "source": "test-suite"
            ],
            "service_tier": "auto",
            "messages": [
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
        XCTAssertEqual(upstreamBody["temperature"] as? Double, 0.2)
        XCTAssertEqual(upstreamBody["top_p"] as? Double, 0.9)
        XCTAssertEqual(upstreamBody["max_output_tokens"] as? Int, 256)
        XCTAssertEqual((upstreamBody["metadata"] as? [String: Any])?["source"] as? String, "test-suite")
        XCTAssertEqual(upstreamBody["service_tier"] as? String, "auto")
        XCTAssertNil(upstreamBody["messages"])
        XCTAssertNotNil(upstreamBody["input"] as? [[String: Any]])
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
        XCTAssertEqual(upstreamBody["input"] as? String, "hello compact")
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
        XCTAssertEqual(upstreamBody["store"] as? Bool, true)
        XCTAssertEqual(upstreamBody["stream"] as? Bool, true)
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

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}

private final class MockStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    func loadStore() throws -> AccountsStore {
        AccountsStore()
    }

    func saveStore(_ store: AccountsStore) throws {
    }
}

private final class StaticStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private let store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        _ = store
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
        ExtractedAuth(accountID: "acct", accessToken: "token", email: nil, planType: nil, teamName: nil)
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

    func record(request: HTTPRequest) {
        lastRequest = Snapshot(target: request.target, path: request.path, headers: request.headers, body: request.body)
    }
}
