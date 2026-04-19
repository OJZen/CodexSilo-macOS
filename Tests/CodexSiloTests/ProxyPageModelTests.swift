import XCTest
@testable import CodexSilo

@MainActor
final class ProxyPageModelTests: XCTestCase {
    func testLoadIfNeededUsesStoredAutoStartSettingAndRefreshesStatus() async {
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                proxyLiveTestLogs: [
                    ProxyLiveTestLogEntry(
                        id: "log-1",
                        createdAt: 1_763_216_100,
                        model: "gpt-5.4",
                        status: .error,
                        message: "HTTP 400: invalid request"
                    )
                ],
                settings: AppSettings(
                    launchAtStartup: false,
                    autoRefreshAccounts: true,
                    autoSmartSwitch: false,
                    autoStartApiProxy: true,
                    locale: AppLocale.english.identifier
                )
            )
        )
        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: 9001,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:9001",
                availableAccounts: 2,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository,
            dateProvider: FixedDateProvider(unixSeconds: 1_763_216_000)
        )

        await model.loadIfNeeded()

        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.preferredPortText, "9001")
        XCTAssertEqual(model.lastRefreshedAt, 1_763_216_000)
        XCTAssertEqual(model.liveTestLogs.count, 1)
        XCTAssertEqual(model.liveTestLogs.first?.message, "HTTP 400: invalid request")
    }

    func testLoadIfNeededLoadsStoredProxyAccountSelection() async {
        let primary = makeStoredProxyAccount(
            id: "stored-primary",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            teamAlias: "Alpha Team"
        )
        let secondary = makeStoredProxyAccount(
            id: "stored-secondary",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            teamAlias: "Beta Team"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [primary, secondary],
                currentSelection: makeCurrentSelection(for: secondary),
                proxySelection: ProxyAccountSelection(account: primary)
            )
        )
        let model = makeModel(
            runtimeService: StubProxyRuntimeService(statusResult: makeRunningProxyStatus()),
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.selectedProxyAccountRoutingMode, .fixedAccount)
        XCTAssertEqual(model.currentProxyAccountOptionID, secondary.id)
        XCTAssertEqual(model.selectedProxyAccountOptionID, primary.id)
        XCTAssertEqual(model.selectedProxyAccountHeadline, primary.label)
        XCTAssertEqual(model.selectedProxyAccountDetailText, "Alpha Team · primary@example.com")
        XCTAssertEqual(model.proxyAccountOptions.first?.id, secondary.id)
    }

    func testSetProxyAccountSelectionPersistsExplicitSelection() async throws {
        let primary = makeStoredProxyAccount(
            id: "stored-primary",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            teamAlias: "Alpha Team"
        )
        let secondary = makeStoredProxyAccount(
            id: "stored-secondary",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            teamAlias: "Beta Team"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [primary, secondary],
                currentSelection: makeCurrentSelection(for: primary)
            )
        )
        let runtimeService = StubProxyRuntimeService(statusResult: makeRunningProxyStatus())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()
        await model.setProxyAccountSelection(choiceID: secondary.id)

        let savedStore = try storeRepository.loadStore()
        XCTAssertEqual(savedStore.proxySelection, ProxyAccountSelection(account: secondary))
        XCTAssertEqual(model.selectedProxyAccountRoutingMode, .fixedAccount)
        XCTAssertEqual(model.currentProxyAccountOptionID, primary.id)
        XCTAssertEqual(model.selectedProxyAccountOptionID, secondary.id)
        XCTAssertEqual(model.selectedProxyAccountHeadline, secondary.label)
        XCTAssertEqual(model.selectedProxyAccountDetailText, "Beta Team · secondary@example.com")
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(model.notice?.text, L10n.tr("proxy.notice.selected_account_updated"))
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
    }

    func testSetProxyAccountSelectionCanReturnToFollowCurrentAccount() async throws {
        let primary = makeStoredProxyAccount(
            id: "stored-primary",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            teamAlias: "Alpha Team"
        )
        let secondary = makeStoredProxyAccount(
            id: "stored-secondary",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            teamAlias: "Beta Team"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [primary, secondary],
                currentSelection: makeCurrentSelection(for: secondary),
                proxySelection: ProxyAccountSelection(account: primary)
            )
        )
        let runtimeService = StubProxyRuntimeService(statusResult: makeRunningProxyStatus())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()
        await model.setProxyAccountSelection(choiceID: model.followCurrentSelectionID)

        let savedStore = try storeRepository.loadStore()
        XCTAssertNil(savedStore.proxySelection)
        XCTAssertNil(model.selectedProxyAccountRoutingMode)
        XCTAssertNil(model.selectedProxyAccountOptionID)
        XCTAssertTrue(model.followsCurrentProxyAccount)
        XCTAssertEqual(model.selectedProxyAccountPickerID, model.followCurrentSelectionID)
        XCTAssertEqual(
            model.selectedProxyAccountHeadline,
            L10n.tr("proxy.selection.follow_current_format", secondary.label)
        )
        XCTAssertEqual(model.selectedProxyAccountDetailText, "Beta Team · secondary@example.com")
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
    }

    func testSetAutoSwitchProxyAccountsCanEnableAutoUniformLoad() async throws {
        let primary = makeStoredProxyAccount(
            id: "stored-primary",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            teamAlias: "Alpha Team"
        )
        let secondary = makeStoredProxyAccount(
            id: "stored-secondary",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            teamAlias: "Beta Team"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [primary, secondary],
                currentSelection: makeCurrentSelection(for: primary)
            )
        )
        let runtimeService = StubProxyRuntimeService(statusResult: makeRunningProxyStatus())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()
        await model.setAutoSwitchProxyAccounts(true)

        let savedStore = try storeRepository.loadStore()
        XCTAssertEqual(savedStore.proxySelection, .autoUniform)
        XCTAssertEqual(model.selectedProxyAccountRoutingMode, .autoUniform)
        XCTAssertTrue(model.usesAutoUniformProxyAccountRouting)
        XCTAssertEqual(model.autoSwitchPickerTitle, "Primary")
        XCTAssertEqual(
            model.selectedProxyAccountHeadline,
            L10n.tr("proxy.selection.auto_switch")
        )
        XCTAssertEqual(
            model.selectedProxyAccountDetailText,
            L10n.tr("proxy.info.selected_account_auto_uniform_last_hit_format", "2", "Primary")
        )
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
    }

    func testSetAutoSwitchProxyAccountsCanReturnToFollowCurrentAccount() async throws {
        let primary = makeStoredProxyAccount(
            id: "stored-primary",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            teamAlias: "Alpha Team"
        )
        let secondary = makeStoredProxyAccount(
            id: "stored-secondary",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            teamAlias: "Beta Team"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [primary, secondary],
                currentSelection: makeCurrentSelection(for: secondary),
                proxySelection: .autoUniform
            )
        )
        let runtimeService = StubProxyRuntimeService(statusResult: makeRunningProxyStatus())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()
        await model.setAutoSwitchProxyAccounts(false)

        let savedStore = try storeRepository.loadStore()
        XCTAssertNil(savedStore.proxySelection)
        XCTAssertNil(model.selectedProxyAccountRoutingMode)
        XCTAssertNil(model.selectedProxyAccountOptionID)
        XCTAssertTrue(model.followsCurrentProxyAccount)
        XCTAssertEqual(model.selectedProxyAccountPickerID, model.followCurrentSelectionID)
        XCTAssertEqual(
            model.selectedProxyAccountHeadline,
            L10n.tr("proxy.selection.follow_current_format", secondary.label)
        )
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
    }

    func testSetAutoSwitchProxyAccountsRestoresPreviousExplicitSelection() async throws {
        let primary = makeStoredProxyAccount(
            id: "stored-primary",
            label: "Primary",
            accountID: "acct-primary",
            accessToken: "token-primary",
            email: "primary@example.com",
            teamAlias: "Alpha Team"
        )
        let secondary = makeStoredProxyAccount(
            id: "stored-secondary",
            label: "Secondary",
            accountID: "acct-secondary",
            accessToken: "token-secondary",
            email: "secondary@example.com",
            teamAlias: "Beta Team"
        )
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                accounts: [primary, secondary],
                currentSelection: makeCurrentSelection(for: primary),
                proxySelection: ProxyAccountSelection(account: secondary)
            )
        )
        let runtimeService = StubProxyRuntimeService(statusResult: makeRunningProxyStatus())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()
        await model.setAutoSwitchProxyAccounts(true)
        await model.setAutoSwitchProxyAccounts(false)

        let savedStore = try storeRepository.loadStore()
        XCTAssertEqual(savedStore.proxySelection, ProxyAccountSelection(account: secondary))
        XCTAssertEqual(model.selectedProxyAccountRoutingMode, .fixedAccount)
        XCTAssertEqual(model.selectedProxyAccountOptionID, secondary.id)
        XCTAssertFalse(model.followsCurrentProxyAccount)
        XCTAssertEqual(model.selectedProxyAccountPickerID, secondary.id)
        XCTAssertEqual(model.selectedProxyAccountHeadline, secondary.label)
        XCTAssertEqual(model.selectedProxyAccountDetailText, "Beta Team · secondary@example.com")
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 2)
    }

    func testBootstrapStartsProxyWhenAutoStartEnabledAndProxyIsStopped() async {
        let runtimeService = StubProxyRuntimeService(
            statusResult: .idle,
            startResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787",
                availableAccounts: 1,
                activeAccountID: nil,
                activeAccountLabel: nil,
                lastError: nil
            )
        )
        let model = makeModel(
            runtimeService: runtimeService,
            dateProvider: FixedDateProvider(unixSeconds: 1_763_216_100)
        )

        await model.bootstrapOnAppLaunch(
            using: AppSettings(
                launchAtStartup: false,
                autoRefreshAccounts: true,
                autoSmartSwitch: false,
                autoStartApiProxy: true,
                locale: AppLocale.english.identifier
            )
        )

        XCTAssertEqual(runtimeService.startCalls, [nil])
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.preferredPortText, "8787")
    }

    func testStartProxyUsesPreferredPortAndPublishesSuccessNotice() async {
        let runtimeService = StubProxyRuntimeService(
            startResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787",
                availableAccounts: 3,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(runtimeService: runtimeService)
        model.preferredPortText = "8787"

        await model.startProxy()

        XCTAssertEqual(runtimeService.startCalls, [8787])
        XCTAssertEqual(runtimeService.syncAccountsStoreCallCount, 1)
        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(model.notice?.text, L10n.tr("proxy.notice.api_proxy_started"))
    }

    func testTestLiveRequestPublishesSuccessNoticeAndRefreshesStatus() async throws {
        let port = Int.random(in: 22000...24999)
        let probe = ProxyLiveTestRequestProbe()
        let server = try SimpleHTTPServer(port: UInt16(port)) { request in
            await probe.record(request: request)
            return HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_live_test",
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "OK"
                    ]]
                ]]
            ])
        }
        server.start()
        defer { server.stop() }

        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: port,
                apiKey: "test-proxy-key",
                baseURL: "http://127.0.0.1:\(port)/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository,
            dateProvider: FixedDateProvider(unixSeconds: 1_763_216_200)
        )

        await model.loadIfNeeded()
        await model.testLiveRequest()

        let request = await probe.lastRequest
        XCTAssertEqual(request?.path, "/v1/responses")
        XCTAssertEqual(request?.headers["authorization"], "Bearer test-proxy-key")

        let body = try XCTUnwrap(request?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5.4")
        XCTAssertNil(json["stream"])
        XCTAssertNil(json["instructions"])
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertNil(json["max_output_tokens"])
        assertLiveTestInputShape(json["input"], file: #filePath, line: #line)

        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(
            model.notice?.text,
            L10n.tr("proxy.notice.test_request_succeeded_format", "gpt-5.4", "OK")
        )
        XCTAssertEqual(runtimeService.statusCallCount, 2)
        XCTAssertEqual(model.lastRefreshedAt, 1_763_216_200)
        let store = try storeRepository.loadStore()
        XCTAssertEqual(store.proxyLiveTestLogs.count, 1)
        XCTAssertEqual(store.proxyLiveTestLogs.first?.status, .success)
        XCTAssertEqual(store.proxyLiveTestLogs.first?.model, "gpt-5.4")
        XCTAssertEqual(store.proxyLiveTestLogs.first?.message, "OK")
    }

    func testTestLiveRequestUsesGpt54WithoutFallbackWhenRejected() async throws {
        let port = Int.random(in: 25000...27999)
        let probe = ProxyLiveTestRequestProbe()
        let server = try SimpleHTTPServer(port: UInt16(port)) { request in
            await probe.record(request: request)
            return HTTPResponse.json(statusCode: 403, object: [
                "error": [
                    "message": "You do not have access to model gpt-5.4.",
                    "type": "invalid_request_error"
                ]
            ])
        }
        server.start()
        defer { server.stop() }

        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: port,
                apiKey: "test-proxy-key",
                baseURL: "http://127.0.0.1:\(port)/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(runtimeService: runtimeService)

        await model.loadIfNeeded()
        await model.testLiveRequest()

        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)

        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        XCTAssertEqual(body["store"] as? Bool, false)
        assertLiveTestInputShape(body["input"], file: #filePath, line: #line)
        XCTAssertEqual(model.notice?.style, .error)
        XCTAssertEqual(
            model.notice?.text,
            "Live test tried gpt-5.4. HTTP 403: You do not have access to model gpt-5.4."
        )
    }

    func testTestLiveRequestShowsErrorWhenProxyIsNotRunning() async {
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let model = makeModel(storeRepository: storeRepository)

        await model.testLiveRequest()

        XCTAssertEqual(model.notice?.style, .error)
        XCTAssertEqual(
            model.notice?.text,
            L10n.tr("proxy.notice.test_request_requires_running_proxy")
        )
        XCTAssertEqual(model.notice?.autoDismissDelay, .seconds(12))
        let store = try? storeRepository.loadStore()
        XCTAssertEqual(store?.proxyLiveTestLogs.first?.status, .error)
    }

    func testTestLiveRequestErrorIncludesAttemptedModelsAndUsesLongerNoticeDelay() async throws {
        let port = Int.random(in: 31000...33999)
        let server = try SimpleHTTPServer(port: UInt16(port)) { _ in
            HTTPResponse.json(statusCode: 403, object: [
                "error": [
                    "message": "You do not have access to this model.",
                    "type": "invalid_request_error"
                ]
            ])
        }
        server.start()
        defer { server.stop() }

        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: port,
                apiKey: "test-proxy-key",
                baseURL: "http://127.0.0.1:\(port)/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(runtimeService: runtimeService)

        await model.loadIfNeeded()
        await model.testLiveRequest()

        XCTAssertEqual(model.notice?.style, .error)
        XCTAssertEqual(model.notice?.autoDismissDelay, .seconds(12))
        XCTAssertEqual(
            model.notice?.text,
            "Live test tried gpt-5.4. HTTP 403: You do not have access to this model."
        )
        XCTAssertEqual(model.liveTestLogs.first?.message, "Live test tried gpt-5.4. HTTP 403: You do not have access to this model.")
    }

    func testTestLiveRequestFallsBackToCompactAfterResponsesNotFound() async throws {
        let port = Int.random(in: 34000...36999)
        let probe = ProxyLiveTestRequestProbe()
        let server = try SimpleHTTPServer(port: UInt16(port)) { request in
            await probe.record(request: request)
            switch request.path {
            case "/v1/responses":
                return HTTPResponse.json(statusCode: 404, object: [
                    "error": "not_found"
                ])
            case "/v1/responses/compact":
                return HTTPResponse.json(statusCode: 200, object: [
                    "type": "response.compact",
                    "model": "gpt-5.4",
                    "output_text": "OK"
                ])
            default:
                return HTTPResponse.json(statusCode: 404, object: [
                    "error": "unexpected_path"
                ])
            }
        }
        server.start()
        defer { server.stop() }

        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: port,
                apiKey: "test-proxy-key",
                baseURL: "http://127.0.0.1:\(port)/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let storeRepository = InMemoryAccountsStoreRepository(store: AccountsStore())
        let model = makeModel(
            runtimeService: runtimeService,
            storeRepository: storeRepository
        )

        await model.loadIfNeeded()
        await model.testLiveRequest()

        let requests = await probe.requests
        XCTAssertEqual(requests.map(\.path), ["/v1/responses", "/v1/responses/compact"])

        let firstBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        XCTAssertEqual(firstBody["store"] as? Bool, false)
        assertLiveTestInputShape(firstBody["input"], file: #filePath, line: #line)

        let secondBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
        XCTAssertEqual(secondBody["store"] as? Bool, false)
        assertLiveTestInputShape(secondBody["input"], file: #filePath, line: #line)

        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(
            model.notice?.text,
            L10n.tr("proxy.notice.test_request_succeeded_format", "gpt-5.4", "OK")
        )

        let store = try storeRepository.loadStore()
        XCTAssertEqual(store.proxyLiveTestLogs.first?.status, .success)
        XCTAssertEqual(store.proxyLiveTestLogs.first?.message, "OK")
    }

    func testRefreshAPIKeyIsIgnoredWhileLiveRequestIsInFlight() async throws {
        let port = Int.random(in: 28000...30999)
        let probe = ProxyLiveTestRequestProbe()
        let server = try SimpleHTTPServer(port: UInt16(port)) { request in
            await probe.record(request: request)
            try? await Task.sleep(nanoseconds: 200_000_000)
            return HTTPResponse.json(statusCode: 200, object: [
                "id": "resp_slow",
                "model": "gpt-5.4",
                "status": "completed",
                "output": [[
                    "type": "message",
                    "content": [[
                        "type": "output_text",
                        "text": "OK"
                    ]]
                ]]
            ])
        }
        server.start()
        defer { server.stop() }

        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: port,
                apiKey: "test-proxy-key",
                baseURL: "http://127.0.0.1:\(port)/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil
            )
        )
        let model = makeModel(runtimeService: runtimeService)
        await model.loadIfNeeded()

        let task = Task { await model.testLiveRequest() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await model.refreshAPIKey()
        await task.value

        XCTAssertEqual(runtimeService.refreshAPIKeyCallCount, 0)
        XCTAssertEqual(model.notice?.style, .success)
    }

    func testResetMetricsPublishesSuccessNoticeAndRefreshesStatus() async {
        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil,
                metrics: ApiProxyMetrics(
                    inFlightRequests: 0,
                    totalRequests: 5,
                    successfulRequests: 4,
                    failedRequests: 1,
                    promptTokens: 20,
                    completionTokens: 10,
                    totalTokens: 30,
                    lastResponseAt: 1_763_216_250
                )
            ),
            resetMetricsResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787/v1",
                availableAccounts: 1,
                activeAccountID: nil,
                activeAccountLabel: nil,
                lastError: nil,
                metrics: .empty
            )
        )
        let model = makeModel(
            runtimeService: runtimeService,
            dateProvider: FixedDateProvider(unixSeconds: 1_763_216_300)
        )

        await model.loadIfNeeded()
        await model.resetMetrics()

        XCTAssertEqual(runtimeService.resetMetricsCallCount, 1)
        XCTAssertEqual(model.proxyStatus.metrics, .empty)
        XCTAssertNil(model.proxyStatus.activeAccountID)
        XCTAssertNil(model.proxyStatus.activeAccountLabel)
        XCTAssertNil(model.proxyStatus.lastError)
        XCTAssertEqual(model.lastRefreshedAt, 1_763_216_300)
        XCTAssertEqual(model.notice?.style, .success)
        XCTAssertEqual(model.notice?.text, L10n.tr("proxy.notice.metrics_reset"))
    }

    func testClearLiveTestLogsRemovesPersistedHistory() async throws {
        let storeRepository = InMemoryAccountsStoreRepository(
            store: AccountsStore(
                proxyLiveTestLogs: [
                    ProxyLiveTestLogEntry(
                        id: "log-1",
                        createdAt: 1_763_216_100,
                        model: "gpt-5.4",
                        status: .error,
                        message: "HTTP 400: invalid request"
                    )
                ]
            )
        )
        let model = makeModel(storeRepository: storeRepository)

        await model.loadIfNeeded()
        XCTAssertEqual(model.liveTestLogs.count, 1)

        await model.clearLiveTestLogs()

        XCTAssertTrue(model.liveTestLogs.isEmpty)
        let store = try storeRepository.loadStore()
        XCTAssertTrue(store.proxyLiveTestLogs.isEmpty)
    }

    func testAutoRefreshUpdatesStatusEveryIntervalWhilePageIsVisible() async {
        let runtimeService = StubProxyRuntimeService(
            statusResult: ApiProxyStatus(
                running: true,
                port: 8787,
                apiKey: "api-key",
                baseURL: "http://127.0.0.1:8787/v1",
                availableAccounts: 1,
                activeAccountID: "acct-1",
                activeAccountLabel: "Primary",
                lastError: nil,
                metrics: ApiProxyMetrics(
                    inFlightRequests: 0,
                    totalRequests: 1,
                    successfulRequests: 1,
                    failedRequests: 0,
                    promptTokens: 10,
                    completionTokens: 5,
                    totalTokens: 15,
                    lastResponseAt: 1_763_216_350
                )
            )
        )
        let model = makeModel(
            runtimeService: runtimeService,
            autoRefreshInterval: .milliseconds(50)
        )

        await model.loadIfNeeded()
        XCTAssertEqual(runtimeService.statusCallCount, 1)
        XCTAssertEqual(model.proxyStatus.metrics.totalRequests, 1)

        runtimeService.statusResult = ApiProxyStatus(
            running: true,
            port: 8787,
            apiKey: "api-key",
            baseURL: "http://127.0.0.1:8787/v1",
            availableAccounts: 1,
            activeAccountID: "acct-1",
            activeAccountLabel: "Primary",
            lastError: nil,
            metrics: ApiProxyMetrics(
                inFlightRequests: 0,
                totalRequests: 3,
                successfulRequests: 2,
                failedRequests: 1,
                promptTokens: 30,
                completionTokens: 12,
                totalTokens: 42,
                lastResponseAt: 1_763_216_351
            )
        )

        try? await Task.sleep(for: .milliseconds(140))

        XCTAssertGreaterThanOrEqual(runtimeService.statusCallCount, 2)
        XCTAssertEqual(model.proxyStatus.metrics.totalRequests, 3)
        XCTAssertEqual(model.proxyStatus.metrics.totalTokens, 42)

        model.handlePageDisappear()
    }

    private func makeModel(
        runtimeService: StubProxyRuntimeService = StubProxyRuntimeService(),
        store: AccountsStore = AccountsStore(),
        storeRepository: AccountsStoreRepository? = nil,
        launchAtStartupService: StubLaunchAtStartupService = StubLaunchAtStartupService(),
        dateProvider: DateProviding = FixedDateProvider(unixSeconds: 1_763_216_000),
        autoRefreshInterval: Duration = .seconds(1)
    ) -> ProxyPageModel {
        let resolvedStoreRepository = storeRepository ?? InMemoryAccountsStoreRepository(store: store)
        let proxyCoordinator = ProxyCoordinator(
            proxyService: runtimeService,
            storeRepository: resolvedStoreRepository,
            dateProvider: dateProvider
        )
        let settingsCoordinator = SettingsCoordinator(
            storeRepository: resolvedStoreRepository,
            launchAtStartupService: launchAtStartupService
        )

        return ProxyPageModel(
            coordinator: proxyCoordinator,
            settingsCoordinator: settingsCoordinator,
            dateProvider: dateProvider,
            autoRefreshInterval: autoRefreshInterval
        )
    }
}

private struct FailingAccountsStoreRepository: AccountsStoreRepository {
    func loadStore() throws -> AccountsStore {
        AccountsStore()
    }

    func saveStore(_ store: AccountsStore) throws {
        _ = store
        throw AppError.io("boom")
    }
}

private final class InMemoryAccountsStoreRepository: AccountsStoreRepository, @unchecked Sendable {
    private var store: AccountsStore

    init(store: AccountsStore) {
        self.store = store
    }

    func loadStore() throws -> AccountsStore {
        store
    }

    func saveStore(_ store: AccountsStore) throws {
        self.store = store
    }
}

private struct FixedDateProvider: DateProviding {
    let unixSeconds: Int64

    func unixSecondsNow() -> Int64 {
        unixSeconds
    }
}

private struct StubLaunchAtStartupService: LaunchAtStartupServiceProtocol {
    var setEnabledError: Error? = nil

    func setEnabled(_ enabled: Bool) throws {
        _ = enabled
        if let setEnabledError {
            throw setEnabledError
        }
    }

    func syncWithStoreValue(_ enabled: Bool) throws {
        _ = enabled
    }
}

private final class StubProxyRuntimeService: ProxyRuntimeService, @unchecked Sendable {
    var statusResult: ApiProxyStatus
    var startResult: ApiProxyStatus
    var stopResult: ApiProxyStatus
    var refreshAPIKeyResult: ApiProxyStatus
    var resetMetricsResult: ApiProxyStatus
    private(set) var startCalls: [Int?] = []
    private(set) var syncAccountsStoreCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var refreshAPIKeyCallCount = 0
    private(set) var resetMetricsCallCount = 0

    init(
        statusResult: ApiProxyStatus = .idle,
        startResult: ApiProxyStatus = .idle,
        stopResult: ApiProxyStatus = .idle,
        refreshAPIKeyResult: ApiProxyStatus = .idle,
        resetMetricsResult: ApiProxyStatus = .idle
    ) {
        self.statusResult = statusResult
        self.startResult = startResult
        self.stopResult = stopResult
        self.refreshAPIKeyResult = refreshAPIKeyResult
        self.resetMetricsResult = resetMetricsResult
    }

    func status() async -> ApiProxyStatus {
        statusCallCount += 1
        return statusResult
    }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        startCalls.append(preferredPort)
        return startResult
    }

    func stop() async -> ApiProxyStatus {
        stopResult
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        refreshAPIKeyCallCount += 1
        return refreshAPIKeyResult
    }

    func resetMetrics() async throws -> ApiProxyStatus {
        resetMetricsCallCount += 1
        return resetMetricsResult
    }

    func syncAccountsStore() async throws {
        syncAccountsStoreCallCount += 1
    }
}

private actor ProxyLiveTestRequestProbe {
    private(set) var lastRequest: HTTPRequest?
    private(set) var requests: [HTTPRequest] = []

    func record(request: HTTPRequest) {
        lastRequest = request
        requests.append(request)
    }
}

private func makeRunningProxyStatus(
    port: Int = 8787,
    availableAccounts: Int = 1,
    activeAccountID: String? = "acct-1",
    activeAccountLabel: String? = "Primary"
) -> ApiProxyStatus {
    ApiProxyStatus(
        running: true,
        port: port,
        apiKey: "api-key",
        baseURL: "http://127.0.0.1:\(port)/v1",
        availableAccounts: availableAccounts,
        activeAccountID: activeAccountID,
        activeAccountLabel: activeAccountLabel,
        lastError: nil
    )
}

private func makeCurrentSelection(
    for account: StoredAccount,
    selectedAt: Int64 = 0,
    sourceDeviceID: String = "macos-local"
) -> CurrentAccountSelection {
    CurrentAccountSelection(
        accountID: account.accountID,
        accountKey: account.accountKey,
        variantKey: account.variantKey,
        selectedAt: selectedAt,
        sourceDeviceID: sourceDeviceID
    )
}

private func makeStoredProxyAccount(
    id: String = "acct-1",
    label: String = "Primary",
    accountID: String = "acct",
    accessToken: String = "token",
    email: String = "proxy@example.com",
    teamName: String? = nil,
    teamAlias: String? = nil,
    usage: UsageSnapshot? = nil
) -> StoredAccount {
    StoredAccount(
        id: id,
        label: label,
        email: email,
        accountID: accountID,
        planType: "pro",
        teamName: teamName,
        teamAlias: teamAlias,
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

private func assertLiveTestInputShape(
    _ value: Any?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let items = value as? [[String: Any]]
    XCTAssertEqual(items?.count, 1, file: file, line: line)

    let message = items?.first
    XCTAssertEqual(message?["type"] as? String, "message", file: file, line: line)
    XCTAssertEqual(message?["role"] as? String, "user", file: file, line: line)

    let content = message?["content"] as? [[String: Any]]
    XCTAssertEqual(content?.count, 1, file: file, line: line)
    XCTAssertEqual(content?.first?["type"] as? String, "input_text", file: file, line: line)
    XCTAssertEqual(content?.first?["text"] as? String, "Reply with OK only.", file: file, line: line)
}
