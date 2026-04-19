import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor SwiftNativeProxyRuntimeService: ProxyRuntimeService {
    private enum ProxyLogDefaults {
        static let compatibilityWarningThrottleSeconds: Int64 = 300
    }

    enum UpstreamRouteFamily: Equatable {
        case codex
        case general
    }

    enum UpstreamEndpointKind: Equatable {
        case responses
        case responsesCompact
    }

    enum DownstreamRequestKind: Equatable {
        case responses
        case responsesCompact
        case chatCompletions
        case completions
    }

    enum ProxyRequestObservationOutcome {
        case success
        case failure
        case cancelled
    }

    struct NormalizedProxyRequest {
        var requestedModel: String
        var payload: [String: Any]
        var downstreamStream: Bool
        var endpointKind: UpstreamEndpointKind
    }

    private static let stableClientModels = [
        "gpt-5",
        "gpt-5-4",
        "gpt-5.4",
        "gpt-5-mini",
        "gpt-5.1",
        "gpt-5.2",
        "gpt-5.3"
    ]

    private static let compatibilityCodexModels = [
        "gpt-5-codex",
        "gpt-5-codex-mini",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1-codex-max",
        "gpt-5.2-codex",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark"
    ]

    private static let clientVisibleModels = stableClientModels + compatibilityCodexModels
    private static let defaultCodexClientVersion = "0.101.0"
    private static let defaultCodexUserAgent = "codex_cli_rs/0.101.0 (Mac OS 26.0.1; arm64) Apple_Terminal/464"
    static let defaultRequiredInstructions = "Assist the user with the request."
    private static let excludedForwardRequestHeaders: Set<String> = [
        "accept",
        "authorization",
        "connection",
        "content-length",
        "content-type",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "user-agent",
        "version",
        "session_id",
        "session-id",
        "x-api-key"
    ]
    private static let excludedForwardResponseHeaders: Set<String> = [
        "connection",
        "content-encoding",
        "content-length",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade"
    ]
    private static let responsesPaths: Set<String> = [
        "/responses",
        "/v1/responses",
        "/v1/v1/responses",
        "/codex/v1/responses"
    ]
    private static let responsesCompactPaths: Set<String> = [
        "/responses/compact",
        "/v1/responses/compact",
        "/v1/v1/responses/compact",
        "/codex/v1/responses/compact"
    ]
    private static let modelsPaths: Set<String> = [
        "/models",
        "/v1/models",
        "/v1/v1/models",
        "/codex/v1/models"
    ]
    private static let chatCompletionsPaths: Set<String> = [
        "/chat/completions",
        "/v1/chat/completions",
        "/v1/v1/chat/completions",
        "/codex/v1/chat/completions"
    ]
    private static let completionsPaths: Set<String> = [
        "/completions",
        "/v1/completions",
        "/v1/v1/completions",
        "/codex/v1/completions"
    ]

    private let paths: FileSystemPaths
    private let storeRepository: AccountsStoreRepository
    private let authRepository: AuthRepository
    private let dateProvider: DateProviding
    private let lanBaseURLResolver: @Sendable (Int) -> [String]
    private let logger: AppLogger

    private var server: SimpleHTTPServer?
    private var runningPort: Int?
    private var activeBindScope: SimpleHTTPServer.BindScope?
    private var activeAccountID: String?
    private var activeAccountLabel: String?
    private var lastError: String?
    private var metrics: ApiProxyMetrics = .empty
    private var didLoadPersistedMetrics = false
    private var activeObservedRequestIDs = Set<Int>()
    private var nextObservedRequestID = 0
    private var compatibilityWarningLastLoggedAt: [String: Int64] = [:]
    private var autoUniformLoadCursor = 0

    private let models = SwiftNativeProxyRuntimeService.clientVisibleModels

    init(
        paths: FileSystemPaths,
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository,
        dateProvider: DateProviding = SystemDateProvider(),
        lanBaseURLResolver: @escaping @Sendable (Int) -> [String] = SwiftNativeProxyRuntimeService.defaultLanBaseURLs(for:),
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.paths = paths
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.dateProvider = dateProvider
        self.lanBaseURLResolver = lanBaseURLResolver
        self.logger = logger
    }

    func status() async -> ApiProxyStatus {
        loadPersistedMetricsIfNeeded()
        let running = server != nil
        let apiKey = (try? ensurePersistedAPIKey()) ?? nil
        let availableAccounts = (try? loadCandidatePlan().candidates.count) ?? 0
        let localBaseURL = runningPort.map { "http://127.0.0.1:\($0)/v1" }
        let lanBaseURLs: [String]
        if running,
           activeBindScope == .allInterfaces,
           let port = runningPort {
            lanBaseURLs = lanBaseURLResolver(port)
        } else {
            lanBaseURLs = []
        }

        return ApiProxyStatus(
            running: running,
            port: running ? runningPort : nil,
            apiKey: apiKey,
            baseURL: localBaseURL,
            lanBaseURLs: lanBaseURLs,
            availableAccounts: availableAccounts,
            activeAccountID: activeAccountID,
            activeAccountLabel: activeAccountLabel,
            lastError: lastError,
            metrics: metrics
        )
    }

    func start(preferredPort: Int?) async throws -> ApiProxyStatus {
        loadPersistedMetricsIfNeeded()
        if server != nil {
            return await status()
        }

        let desiredPort = preferredPort ?? 8787
        guard desiredPort > 0 && desiredPort < 65536 else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_port_format", String(desiredPort)))
        }
        logger.info(
            category: .proxy,
            event: "runtime_start_requested",
            message: "Starting Swift native proxy runtime.",
            metadata: ["port": String(desiredPort)]
        )

        _ = try ensurePersistedAPIKey()
        let bindScope: SimpleHTTPServer.BindScope = currentSettings().allowLanProxyAccess
            ? .allInterfaces
            : .loopbackOnly

        let boundServer: SimpleHTTPServer
        do {
            boundServer = try SimpleHTTPServer(port: UInt16(desiredPort), bindScope: bindScope) { [weak self] request in
                guard let self else {
                    return HTTPResponse.json(statusCode: 500, object: ["error": ["message": "Proxy runtime unavailable"]])
                }
                return await self.handle(request: request)
            }
            boundServer.start()
        } catch {
            lastError = L10n.tr("error.proxy_runtime.start_swift_proxy_failed_format", error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "runtime_start_failed",
                message: "Failed to start Swift native proxy runtime.",
                metadata: [
                    "port": String(desiredPort),
                    "error": error.localizedDescription
                ]
            )
            throw AppError.io(lastError ?? L10n.tr("error.proxy_runtime.start_failed"))
        }

        server = boundServer
        runningPort = desiredPort
        activeBindScope = bindScope
        lastError = nil

        let healthy = await waitForHealth(port: desiredPort)
        if !healthy {
            _ = await stop()
            lastError = L10n.tr("error.proxy_runtime.health_check_failed")
            logger.error(
                category: .proxy,
                event: "runtime_health_check_failed",
                message: "Proxy runtime failed health check after startup.",
                metadata: ["port": String(desiredPort)]
            )
            throw AppError.io(lastError ?? L10n.tr("error.proxy_runtime.start_failed"))
        }

        logger.info(
            category: .proxy,
            event: "runtime_start_succeeded",
            message: "Swift native proxy runtime started.",
            metadata: [
                "port": String(desiredPort),
                "bind_scope": bindScope == .allInterfaces ? "all_interfaces" : "loopback_only"
            ]
        )
        return await status()
    }

    func stop() async -> ApiProxyStatus {
        server?.stop()
        server = nil
        runningPort = nil
        activeBindScope = nil
        activeAccountID = nil
        activeAccountLabel = nil
        logger.info(
            category: .proxy,
            event: "runtime_stop_succeeded",
            message: "Swift native proxy runtime stopped."
        )
        return await status()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        let key = randomAPIKey()
        try persistAPIKey(key)
        logger.info(
            category: .proxy,
            event: "runtime_api_key_refreshed",
            message: "Proxy runtime API key refreshed."
        )
        return await status()
    }

    func resetMetrics() async throws -> ApiProxyStatus {
        loadPersistedMetricsIfNeeded()

        guard activeObservedRequestIDs.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.reset_metrics_in_flight"))
        }

        metrics = .empty
        activeAccountID = nil
        activeAccountLabel = nil
        lastError = nil
        persistMetricsIfPossible()
        logger.info(
            category: .proxy,
            event: "runtime_metrics_reset",
            message: "Proxy runtime metrics reset."
        )
        return await status()
    }

    func syncAccountsStore() async throws {
        guard activeObservedRequestIDs.isEmpty else {
            return
        }
        loadPersistedMetricsIfNeeded(forceReload: true)
        autoUniformLoadCursor = 0
        logger.debug(
            category: .proxy,
            event: "runtime_sync_accounts_store",
            message: "Reloaded proxy runtime persisted metrics before start."
        )
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" && request.method == "GET" {
            return HTTPResponse.json(statusCode: 200, object: [
                "ok": true,
                "status": "ok",
                "timestamp": Int(dateProvider.unixSecondsNow())
            ])
        }

        guard isAuthorized(request.headers) else {
            logger.warning(
                category: .proxy,
                event: "request_unauthorized",
                message: "Rejected proxy request because API key authorization failed.",
                metadata: [
                    "method": request.method,
                    "route": request.path
                ]
            )
            return jsonError(statusCode: 401, message: "Invalid proxy api key.")
        }

        if Self.modelsPaths.contains(request.path) && request.method == "GET" {
            let list = models.map { model in
                [
                    "id": model,
                    "object": "model",
                    "created": 0,
                    "owned_by": "openai"
                ] as [String: Any]
            }
            return HTTPResponse.json(statusCode: 200, object: ["object": "list", "data": list])
        }

        if Self.responsesPaths.contains(request.path) && request.method == "POST" {
            return await observeProxyRequest {
                await handleResponsesRequest(request)
            }
        }

        if Self.responsesCompactPaths.contains(request.path) && request.method == "POST" {
            return await observeProxyRequest {
                await handleResponsesCompactRequest(request)
            }
        }

        if Self.chatCompletionsPaths.contains(request.path) && request.method == "POST" {
            return await observeProxyRequest {
                await handleChatCompletionsRequest(request)
            }
        }

        if Self.completionsPaths.contains(request.path) && request.method == "POST" {
            return await observeProxyRequest {
                await handleCompletionsRequest(request)
            }
        }

        logger.warning(
            category: .proxy,
            event: "unsupported_route",
            message: "Rejected proxy request because the route is unsupported.",
            metadata: [
                "method": request.method,
                "route": request.path
            ]
        )
        return jsonError(
            statusCode: 404,
            message: L10n.tr("error.proxy_runtime.unsupported_route")
        )
    }

    private func observeProxyRequest(
        _ operation: () async -> HTTPResponse
    ) async -> HTTPResponse {
        let requestID = beginObservedProxyRequest()
        let response = await operation()
        return observeProxyResponse(response, requestID: requestID)
    }

    private func beginObservedProxyRequest() -> Int {
        nextObservedRequestID += 1
        let requestID = nextObservedRequestID
        activeObservedRequestIDs.insert(requestID)
        metrics.inFlightRequests += 1
        metrics.totalRequests += 1
        return requestID
    }

    private func observeProxyResponse(_ response: HTTPResponse, requestID: Int) -> HTTPResponse {
        switch response.body {
        case .data(let body):
            let outcome: ProxyRequestObservationOutcome = (200..<300).contains(response.statusCode) ? .success : .failure
            let usage = outcome == .success
                ? extractUsageFromDownstreamBody(statusCode: response.statusCode, headers: response.headers, body: body)
                : nil
            completeObservedProxyRequest(requestID, outcome: outcome, usage: usage)
            return response

        case .stream(let bodyStream):
            let observedStream = makeObservedStreamingBody(
                from: bodyStream,
                requestID: requestID,
                statusCode: response.statusCode
            )
            return HTTPResponse.stream(
                statusCode: response.statusCode,
                headers: response.headers,
                body: observedStream
            )
        }
    }

    private func completeObservedProxyRequest(
        _ requestID: Int,
        outcome: ProxyRequestObservationOutcome,
        usage: [String: Any]? = nil
    ) {
        guard activeObservedRequestIDs.remove(requestID) != nil else {
            return
        }

        metrics.inFlightRequests = max(0, metrics.inFlightRequests - 1)

        switch outcome {
        case .success:
            metrics.successfulRequests += 1
            metrics.lastResponseAt = dateProvider.unixSecondsNow()
            if let usage {
                applyUsageMetrics(usage)
            }

        case .failure:
            metrics.failedRequests += 1
            metrics.lastResponseAt = dateProvider.unixSecondsNow()

        case .cancelled:
            break
        }

        persistMetricsIfPossible()
    }

    private func loadPersistedMetricsIfNeeded(forceReload: Bool = false) {
        guard forceReload || !didLoadPersistedMetrics else {
            return
        }

        let persistedMetrics = (try? storeRepository.loadStore().proxyMetrics) ?? .empty
        metrics = persistedMetrics.persistedValue
        didLoadPersistedMetrics = true
    }

    private func persistMetricsIfPossible() {
        guard didLoadPersistedMetrics else {
            return
        }

        do {
            var store = try storeRepository.loadStore()
            store.proxyMetrics = metrics.persistedValue
            try storeRepository.saveStore(store)
        } catch {
            // Keep runtime metrics in memory even if persistence temporarily fails.
        }
    }

    private func handleResponsesRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: request.body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let normalized: NormalizedProxyRequest
        do {
            normalized = try normalizeProxyRequest(object, kind: .responses)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        if normalized.downstreamStream {
            do {
                return try await streamResponsesOverCandidates(
                    payload: normalized.payload,
                    request: request,
                    endpointKind: normalized.endpointKind
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        let upstream: UpstreamResponse
        do {
            upstream = try await sendOverCandidates(
                payload: normalized.payload,
                request: request,
                endpointKind: normalized.endpointKind
            )
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        guard (200..<300).contains(upstream.statusCode) else {
            return downstreamResponse(from: upstream)
        }

        do {
            let completed = try completedResponseObject(from: upstream)
            return jsonResponse(statusCode: 200, object: completed, baseHeaders: upstream.headers)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    private func handleChatCompletionsRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: request.body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let normalized: NormalizedProxyRequest
        do {
            normalized = try normalizeProxyRequest(object, kind: .chatCompletions)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        do {
            upstream = try await sendOverCandidates(
                payload: normalized.payload,
                request: request,
                endpointKind: normalized.endpointKind
            )
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        guard (200..<300).contains(upstream.statusCode) else {
            return downstreamResponse(from: upstream)
        }

        if normalized.downstreamStream {
            do {
                let sse = try convertResponsesSSEToChatCompletionsSSE(
                    upstream.body,
                    fallbackModel: normalized.requestedModel
                )
                return response(
                    statusCode: 200,
                    body: sse,
                    baseHeaders: upstream.headers,
                    defaultContentType: "text/event-stream; charset=utf-8"
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        do {
            let completed = try completedResponseObject(from: upstream)
            let completion = convertCompletedResponseToChatCompletion(
                completed,
                fallbackModel: normalized.requestedModel
            )
            return jsonResponse(statusCode: 200, object: completion, baseHeaders: upstream.headers)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    private func handleResponsesCompactRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: request.body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let normalized: NormalizedProxyRequest
        do {
            normalized = try normalizeProxyRequest(object, kind: .responsesCompact)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        do {
            upstream = try await sendOverCandidates(
                payload: normalized.payload,
                request: request,
                endpointKind: normalized.endpointKind
            )
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        return downstreamResponse(from: upstream)
    }

    private func handleCompletionsRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let object: [String: Any]
        do {
            object = try parseJSONObject(from: request.body)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        if let prompts = try? normalizedLegacyPrompts(object["prompt"]),
           prompts.count > 1 {
            let downstreamStream = (object["stream"] as? Bool) ?? false
            guard !downstreamStream else {
                return jsonError(statusCode: 400, message: "Streaming is not supported for batched completions prompts.")
            }
            return await handleBatchedCompletionsRequest(object, prompts: prompts, request: request)
        }

        let normalized: NormalizedProxyRequest
        do {
            normalized = try normalizeProxyRequest(object, kind: .completions)
        } catch {
            return jsonError(statusCode: 400, message: error.localizedDescription)
        }

        let upstream: UpstreamResponse
        do {
            upstream = try await sendOverCandidates(
                payload: normalized.payload,
                request: request,
                endpointKind: normalized.endpointKind
            )
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }

        guard (200..<300).contains(upstream.statusCode) else {
            return downstreamResponse(from: upstream)
        }

        if normalized.downstreamStream {
            do {
                let sse = try convertResponsesSSEToCompletionsSSE(
                    upstream.body,
                    fallbackModel: normalized.requestedModel
                )
                return response(
                    statusCode: 200,
                    body: sse,
                    baseHeaders: upstream.headers,
                    defaultContentType: "text/event-stream; charset=utf-8"
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }
        }

        do {
            let completed = try completedResponseObject(from: upstream)
            let completion = convertCompletedResponseToLegacyCompletion(
                completed,
                fallbackModel: normalized.requestedModel
            )
            return jsonResponse(statusCode: 200, object: completion, baseHeaders: upstream.headers)
        } catch {
            return jsonError(statusCode: 502, message: error.localizedDescription)
        }
    }

    private func handleBatchedCompletionsRequest(
        _ object: [String: Any],
        prompts: [String],
        request: HTTPRequest
    ) async -> HTTPResponse {
        let requestedModel = (object["model"] as? String) ?? "gpt-5"
        var baseHeaders: [String: String] = [:]
        var choices: [[String: Any]] = []
        var usageBuckets: [[String: Any]] = []
        var responseID = "cmpl_\(UUID().uuidString)"
        var createdAt = Int(dateProvider.unixSecondsNow())
        var resolvedModel = normalizeModelForClient(requestedModel)

        for (index, prompt) in prompts.enumerated() {
            var promptRequest = object
            promptRequest["prompt"] = prompt

            let normalized: NormalizedProxyRequest
            do {
                normalized = try normalizeProxyRequest(promptRequest, kind: .completions)
            } catch {
                return jsonError(statusCode: 400, message: error.localizedDescription)
            }

            let upstream: UpstreamResponse
            do {
                upstream = try await sendOverCandidates(
                    payload: normalized.payload,
                    request: request,
                    endpointKind: normalized.endpointKind
                )
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }

            guard (200..<300).contains(upstream.statusCode) else {
                return downstreamResponse(from: upstream)
            }

            let completed: [String: Any]
            do {
                completed = try completedResponseObject(from: upstream)
            } catch {
                return jsonError(statusCode: 502, message: error.localizedDescription)
            }

            if index == 0 {
                baseHeaders = upstream.headers
                responseID = (completed["id"] as? String) ?? responseID
                createdAt = (completed["created_at"] as? Int) ?? createdAt
                resolvedModel = normalizeModelForClient((completed["model"] as? String) ?? requestedModel)
            }

            let completion = convertCompletedResponseToLegacyCompletion(completed, fallbackModel: requestedModel)
            if let choice = (completion["choices"] as? [[String: Any]])?.first {
                var choice = choice
                choice["index"] = index
                choices.append(choice)
            }
            if let usage = completion["usage"] as? [String: Any] {
                usageBuckets.append(usage)
            }
        }

        var root: [String: Any] = [
            "id": responseID,
            "object": "text_completion",
            "created": createdAt,
            "model": resolvedModel,
            "choices": choices
        ]
        if let usage = aggregateOpenAIUsage(usageBuckets) {
            root["usage"] = usage
        }

        return jsonResponse(statusCode: 200, object: root, baseHeaders: baseHeaders)
    }

    private func sendOverCandidates(
        payload: [String: Any],
        request: HTTPRequest,
        endpointKind: UpstreamEndpointKind = .responses
    ) async throws -> UpstreamResponse {
        let operationID = UUID().uuidString
        let candidatePlan = try loadCandidatePlan()
        let candidates = orderedCandidatesForRequest(candidatePlan)
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }
        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        var lastRetriableResponse: UpstreamResponse?
        for candidate in candidates {
            do {
                let response = try await sendUpstream(
                    payload: payload,
                    candidate: candidate,
                    request: request,
                    endpointKind: endpointKind,
                    operationID: operationID
                )
                if response.statusCode >= 200 && response.statusCode < 300 {
                    activeAccountID = candidate.accountID
                    activeAccountLabel = candidate.label
                    lastError = nil
                    return response
                }

                let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                failureDetails.append(detail)

                if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                    retryFailures.append(retryFailure)
                    lastRetriableResponse = response
                    logger.warning(
                        category: .proxy,
                        event: "upstream_request_retrying",
                        message: "Upstream proxy request will retry with the next candidate account.",
                        metadata: [
                            "route": request.path,
                            "account_id": candidate.accountID,
                            "status_code": String(response.statusCode)
                        ],
                        operationID: operationID
                    )
                    continue
                } else {
                    lastError = detail
                    logger.error(
                        category: .proxy,
                        event: "upstream_request_non_retriable_failure",
                        message: "Upstream proxy request failed with a non-retriable response.",
                        metadata: [
                            "route": request.path,
                            "account_id": candidate.accountID,
                            "status_code": String(response.statusCode)
                        ],
                        operationID: operationID
                    )
                    return response
                }
            } catch {
                let detail = "\(candidate.label): \(error.localizedDescription)"
                failureDetails.append(detail)
                logger.warning(
                    category: .proxy,
                    event: "upstream_request_candidate_failed",
                    message: "Upstream proxy request failed for a candidate account.",
                    metadata: [
                        "route": request.path,
                        "account_id": candidate.accountID,
                        "error": error.localizedDescription
                    ],
                    operationID: operationID
                )
            }
        }

        if let lastRetriableResponse {
            let summary = buildRetriableFailureSummary(retryFailures)
            let message = summary.isEmpty
                ? L10n.tr("error.proxy_runtime.all_accounts_unavailable")
                : L10n.tr("error.proxy_runtime.all_accounts_unavailable_with_summary_format", summary)
            lastError = message
            logger.error(
                category: .proxy,
                event: "upstream_request_all_candidates_exhausted",
                message: "Upstream proxy request exhausted all retryable candidate accounts.",
                metadata: ["route": request.path],
                operationID: operationID
            )
            return lastRetriableResponse
        }

        let preview = failureDetails.prefix(2).joined(separator: " | ")
        let message = failureDetails.count > 2
            ? L10n.tr("error.proxy_runtime.upstream_failed_with_more_format", preview, String(failureDetails.count - 2))
            : L10n.tr("error.proxy_runtime.upstream_failed_format", preview)
        lastError = message
        logger.error(
            category: .proxy,
            event: "upstream_request_failed",
            message: "Upstream proxy request failed across all candidates.",
            metadata: [
                "route": request.path,
                "failure_preview": preview
            ],
            operationID: operationID
        )
        throw AppError.network(message)
    }

    private func streamResponsesOverCandidates(
        payload: [String: Any],
        request: HTTPRequest,
        endpointKind: UpstreamEndpointKind = .responses
    ) async throws -> HTTPResponse {
        let operationID = UUID().uuidString
        let candidatePlan = try loadCandidatePlan()
        let candidates = orderedCandidatesForRequest(candidatePlan)
        guard !candidates.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.no_accounts_available"))
        }
        var failureDetails: [String] = []
        var retryFailures: [RetryFailureInfo] = []
        var lastRetriableResponse: UpstreamResponse?

        for candidate in candidates {
            do {
                let result = try await sendStreamingUpstream(
                    payload: payload,
                    candidate: candidate,
                    request: request,
                    endpointKind: endpointKind,
                    operationID: operationID
                )

                switch result {
                case .streaming(let response):
                    activeAccountID = candidate.accountID
                    activeAccountLabel = candidate.label
                    lastError = nil
                    return streamingResponse(
                        statusCode: response.statusCode,
                        body: response.body,
                        baseHeaders: response.headers,
                        defaultContentType: "text/event-stream; charset=utf-8"
                    )

                case .buffered(let response):
                    let bodyText = String(data: response.body, encoding: .utf8) ?? ""
                    let detail = "\(candidate.label): \(response.statusCode) \(truncateForError(bodyText, maxLength: 120))"
                    failureDetails.append(detail)

                    if let retryFailure = classifyRetryFailure(statusCode: response.statusCode, bodyText: bodyText) {
                        retryFailures.append(retryFailure)
                        lastRetriableResponse = response
                        logger.warning(
                            category: .proxy,
                            event: "upstream_stream_retrying",
                            message: "Upstream streaming proxy request will retry with the next candidate account.",
                            metadata: [
                                "route": request.path,
                                "account_id": candidate.accountID,
                                "status_code": String(response.statusCode)
                            ],
                            operationID: operationID
                        )
                        continue
                    } else {
                        lastError = detail
                        logger.error(
                            category: .proxy,
                            event: "upstream_stream_non_retriable_failure",
                            message: "Upstream streaming proxy request failed with a non-retriable response.",
                            metadata: [
                                "route": request.path,
                                "account_id": candidate.accountID,
                                "status_code": String(response.statusCode)
                            ],
                            operationID: operationID
                        )
                        return downstreamResponse(from: response)
                    }
                }
            } catch {
                let detail = "\(candidate.label): \(error.localizedDescription)"
                failureDetails.append(detail)
                logger.warning(
                    category: .proxy,
                    event: "upstream_stream_candidate_failed",
                    message: "Upstream streaming proxy request failed for a candidate account.",
                    metadata: [
                        "route": request.path,
                        "account_id": candidate.accountID,
                        "error": error.localizedDescription
                    ],
                    operationID: operationID
                )
            }
        }

        if let lastRetriableResponse {
            let summary = buildRetriableFailureSummary(retryFailures)
            let message = summary.isEmpty
                ? L10n.tr("error.proxy_runtime.all_accounts_unavailable")
                : L10n.tr("error.proxy_runtime.all_accounts_unavailable_with_summary_format", summary)
            lastError = message
            logger.error(
                category: .proxy,
                event: "upstream_stream_all_candidates_exhausted",
                message: "Upstream streaming proxy request exhausted all retryable candidate accounts.",
                metadata: ["route": request.path],
                operationID: operationID
            )
            return downstreamResponse(from: lastRetriableResponse)
        }

        let preview = failureDetails.prefix(2).joined(separator: " | ")
        let message = failureDetails.count > 2
            ? L10n.tr("error.proxy_runtime.upstream_failed_with_more_format", preview, String(failureDetails.count - 2))
            : L10n.tr("error.proxy_runtime.upstream_failed_format", preview)
        lastError = message
        logger.error(
            category: .proxy,
            event: "upstream_stream_failed",
            message: "Upstream streaming proxy request failed across all candidates.",
            metadata: [
                "route": request.path,
                "failure_preview": preview
            ],
            operationID: operationID
        )
        throw AppError.network(message)
    }

    private func sendUpstream(
        payload: [String: Any],
        candidate: ProxyCandidate,
        request: HTTPRequest,
        endpointKind: UpstreamEndpointKind,
        operationID: String
    ) async throws -> UpstreamResponse {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.invalid_upstream_payload"))
        }

        let firstResponse = try await performUpstreamRequest(
            payload: payload,
            candidate: candidate,
            request: request,
            endpointKind: endpointKind
        )
        let firstBodyText = String(data: firstResponse.body, encoding: .utf8) ?? ""
        if Self.shouldRetryWithAutoReasoningSummary(statusCode: firstResponse.statusCode, bodyText: firstBodyText),
           let adjustedPayload = Self.payloadWithAutoReasoningSummaryIfNeeded(payload: payload) {
            logger.warning(
                category: .proxy,
                event: "upstream_auto_reasoning_retry",
                message: "Retrying upstream request with normalized reasoning summary.",
                metadata: [
                    "route": request.path,
                    "account_id": candidate.accountID,
                    "status_code": String(firstResponse.statusCode)
                ],
                operationID: operationID
            )
            return try await performUpstreamRequest(
                payload: adjustedPayload,
                candidate: candidate,
                request: request,
                endpointKind: endpointKind
            )
        }

        return firstResponse
    }

    private func sendStreamingUpstream(
        payload: [String: Any],
        candidate: ProxyCandidate,
        request: HTTPRequest,
        endpointKind: UpstreamEndpointKind,
        operationID: String
    ) async throws -> UpstreamStreamingResult {
        let firstResponse = try await performUpstreamStreamingRequest(
            payload: payload,
            candidate: candidate,
            request: request,
            endpointKind: endpointKind
        )

        if case .buffered(let firstBuffered) = firstResponse {
            let firstBodyText = String(data: firstBuffered.body, encoding: .utf8) ?? ""
            if Self.shouldRetryWithAutoReasoningSummary(statusCode: firstBuffered.statusCode, bodyText: firstBodyText),
               let adjustedPayload = Self.payloadWithAutoReasoningSummaryIfNeeded(payload: payload) {
                logger.warning(
                    category: .proxy,
                    event: "upstream_stream_auto_reasoning_retry",
                    message: "Retrying upstream streaming request with normalized reasoning summary.",
                    metadata: [
                        "route": request.path,
                        "account_id": candidate.accountID,
                        "status_code": String(firstBuffered.statusCode)
                    ],
                    operationID: operationID
                )
                return try await performUpstreamStreamingRequest(
                    payload: adjustedPayload,
                    candidate: candidate,
                    request: request,
                    endpointKind: endpointKind
                )
            }
        }

        return firstResponse
    }

    private func performUpstreamRequest(
        payload: [String: Any],
        candidate: ProxyCandidate,
        request downstreamRequest: HTTPRequest,
        endpointKind: UpstreamEndpointKind
    ) async throws -> UpstreamResponse {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let upstreamModel = (payload["model"] as? String) ?? "gpt-5.4"
        let version = Self.normalizedForwardHeader(downstreamRequest.headers["version"]) ?? Self.defaultCodexClientVersion
        let sessionID = Self.normalizedForwardHeader(downstreamRequest.headers["session_id"])
            ?? Self.normalizedForwardHeader(downstreamRequest.headers["session-id"])
            ?? UUID().uuidString
        let userAgent = Self.normalizedForwardHeader(downstreamRequest.headers["user-agent"]) ?? Self.defaultCodexUserAgent
        var request = URLRequest(
            url: upstreamEndpoint(
                forUpstreamModel: upstreamModel,
                endpointKind: endpointKind,
                queryItems: downstreamRequest.queryItems
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.httpBody = body
        applyForwardHeaders(downstreamRequest.headers, to: &request)
        request.setValue("Bearer \(candidate.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(candidate.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            preferredUpstreamAcceptHeader(payload: payload, endpointKind: endpointKind),
            forHTTPHeaderField: "Accept"
        )
        request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
        request.setValue(version, forHTTPHeaderField: "Version")
        request.setValue(sessionID, forHTTPHeaderField: "Session_id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")

        let (responseBytes, response) = try await URLSession.shared.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 500
        var responseBody = Data()
        responseBody.reserveCapacity(64 * 1024)

        for try await byte in responseBytes {
            responseBody.append(byte)
            if responseBody.count > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                throw AppError.network(
                    L10n.tr(
                        "error.proxy_runtime.upstream_response_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                    )
                )
            }
        }

        return UpstreamResponse(
            statusCode: statusCode,
            headers: Self.responseHeaders(from: httpResponse),
            body: responseBody
        )
    }

    private func performUpstreamStreamingRequest(
        payload: [String: Any],
        candidate: ProxyCandidate,
        request downstreamRequest: HTTPRequest,
        endpointKind: UpstreamEndpointKind
    ) async throws -> UpstreamStreamingResult {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let upstreamModel = (payload["model"] as? String) ?? "gpt-5.4"
        let version = Self.normalizedForwardHeader(downstreamRequest.headers["version"]) ?? Self.defaultCodexClientVersion
        let sessionID = Self.normalizedForwardHeader(downstreamRequest.headers["session_id"])
            ?? Self.normalizedForwardHeader(downstreamRequest.headers["session-id"])
            ?? UUID().uuidString
        let userAgent = Self.normalizedForwardHeader(downstreamRequest.headers["user-agent"]) ?? Self.defaultCodexUserAgent
        var request = URLRequest(
            url: upstreamEndpoint(
                forUpstreamModel: upstreamModel,
                endpointKind: endpointKind,
                queryItems: downstreamRequest.queryItems
            )
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.httpBody = body
        applyForwardHeaders(downstreamRequest.headers, to: &request)
        request.setValue("Bearer \(candidate.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(candidate.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            preferredUpstreamAcceptHeader(payload: payload, endpointKind: endpointKind),
            forHTTPHeaderField: "Accept"
        )
        request.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
        request.setValue(version, forHTTPHeaderField: "Version")
        request.setValue(sessionID, forHTTPHeaderField: "Session_id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")

        let (responseBytes, response) = try await URLSession.shared.bytes(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 500
        let headers = Self.responseHeaders(from: httpResponse)

        if (200..<300).contains(statusCode) {
            return .streaming(
                UpstreamStreamingResponse(
                    statusCode: statusCode,
                    headers: headers,
                    body: makeStreamingBody(from: responseBytes)
                )
            )
        }

        let responseBody = try await bufferedResponseData(from: responseBytes)
        return .buffered(
            UpstreamResponse(
                statusCode: statusCode,
                headers: headers,
                body: responseBody
            )
        )
    }

    private func bufferedResponseData(from responseBytes: URLSession.AsyncBytes) async throws -> Data {
        var responseBody = Data()
        responseBody.reserveCapacity(64 * 1024)

        for try await byte in responseBytes {
            responseBody.append(byte)
            if responseBody.count > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                throw AppError.network(
                    L10n.tr(
                        "error.proxy_runtime.upstream_response_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                    )
                )
            }
        }

        return responseBody
    }

    private func makeStreamingBody(from responseBytes: URLSession.AsyncBytes) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                var chunk = Data()
                chunk.reserveCapacity(1024)
                var totalBytes = 0

                do {
                    for try await byte in responseBytes {
                        chunk.append(byte)
                        totalBytes += 1

                        if totalBytes > ProxyRuntimeLimits.maxUpstreamResponseBytes {
                            throw AppError.network(
                                L10n.tr(
                                    "error.proxy_runtime.upstream_response_too_large_format",
                                    ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxUpstreamResponseBytes)
                                )
                            )
                        }

                        if byte == 0x0A || chunk.count >= 1024 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }

                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeObservedStreamingBody(
        from stream: AsyncThrowingStream<Data, Error>,
        requestID: Int,
        statusCode: Int
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let accumulator = StreamingUsageAccumulator()

            continuation.onTermination = { @Sendable termination in
                guard case .cancelled = termination else { return }
                Task { [self] in
                    await completeObservedProxyRequest(requestID, outcome: .cancelled)
                }
            }

            Task.detached { [self] in
                do {
                    for try await chunk in stream {
                        accumulator.consume(chunk)
                        continuation.yield(chunk)
                    }

                    let usage = (200..<300).contains(statusCode) ? accumulator.finalUsage() : nil
                    await completeObservedProxyRequest(
                        requestID,
                        outcome: (200..<300).contains(statusCode) ? .success : .failure,
                        usage: usage
                    )
                    continuation.finish()
                } catch {
                    await completeObservedProxyRequest(requestID, outcome: .failure)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func applyForwardHeaders(_ downstreamHeaders: [String: String], to request: inout URLRequest) {
        for (key, value) in downstreamHeaders {
            guard !Self.excludedForwardRequestHeaders.contains(key),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func extractUsageFromDownstreamBody(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) -> [String: Any]? {
        guard (200..<300).contains(statusCode) else {
            return nil
        }

        if isLikelySSEBody(headers: headers, body: body) {
            return extractUsageFromSSEBody(body)
        }

        guard let object = try? parseJSONObject(from: body) else {
            return nil
        }

        return object["usage"] as? [String: Any]
    }

    private func applyUsageMetrics(_ usage: [String: Any]) {
        let counts = normalizedUsageCounts(from: usage)
        if let promptTokens = counts.promptTokens {
            metrics.promptTokens += promptTokens
        }
        if let completionTokens = counts.completionTokens {
            metrics.completionTokens += completionTokens
        }
        if let totalTokens = counts.totalTokens {
            metrics.totalTokens += totalTokens
        } else if let promptTokens = counts.promptTokens,
                  let completionTokens = counts.completionTokens {
            metrics.totalTokens += promptTokens + completionTokens
        }
    }

    private func normalizedUsageCounts(from usage: [String: Any]) -> NormalizedUsageCounts {
        let promptTokens = integerValue(
            usage["prompt_tokens"]
                ?? usage["input_tokens"]
        )
        let completionTokens = integerValue(
            usage["completion_tokens"]
                ?? usage["output_tokens"]
        )
        let totalTokens = integerValue(usage["total_tokens"])

        return NormalizedUsageCounts(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens
        )
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String,
           let integer = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return integer
        }
        return nil
    }

    private func downstreamResponse(from upstream: UpstreamResponse, defaultContentType: String? = nil) -> HTTPResponse {
        response(
            statusCode: upstream.statusCode,
            body: upstream.body,
            baseHeaders: upstream.headers,
            defaultContentType: defaultContentType
        )
    }

    private func response(
        statusCode: Int,
        body: Data,
        baseHeaders: [String: String],
        defaultContentType: String? = nil
    ) -> HTTPResponse {
        var headers = baseHeaders.filter { key, _ in
            !Self.excludedForwardResponseHeaders.contains(key.lowercased())
        }
        if let defaultContentType,
           headers["content-type"] == nil,
           headers["Content-Type"] == nil {
            headers["Content-Type"] = defaultContentType
        }
        return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private func streamingResponse(
        statusCode: Int,
        body: AsyncThrowingStream<Data, Error>,
        baseHeaders: [String: String],
        defaultContentType: String? = nil
    ) -> HTTPResponse {
        var headers = baseHeaders.filter { key, _ in
            !Self.excludedForwardResponseHeaders.contains(key.lowercased())
        }
        if let defaultContentType,
           headers["content-type"] == nil,
           headers["Content-Type"] == nil {
            headers["Content-Type"] = defaultContentType
        }
        return HTTPResponse.stream(statusCode: statusCode, headers: headers, body: body)
    }

    private func jsonResponse(statusCode: Int, object: Any, baseHeaders: [String: String]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let sanitizedBaseHeaders = baseHeaders.filter { key, _ in
            key.lowercased() != "content-type"
        }
        return response(
            statusCode: statusCode,
            body: data,
            baseHeaders: sanitizedBaseHeaders.merging(["Content-Type": "application/json; charset=utf-8"]) { _, new in new }
        )
    }

    private func preferredUpstreamAcceptHeader(
        payload: [String: Any],
        endpointKind: UpstreamEndpointKind
    ) -> String {
        switch endpointKind {
        case .responses:
            let expectsStreaming = (payload["stream"] as? Bool) ?? false
            return expectsStreaming ? "text/event-stream" : "application/json"
        case .responsesCompact:
            return "application/json"
        }
    }

    private func isLikelySSEResponse(_ upstream: UpstreamResponse) -> Bool {
        isLikelySSEBody(headers: upstream.headers, body: upstream.body)
    }

    private func isLikelySSEBody(headers: [String: String], body: Data) -> Bool {
        if let contentType = headers["content-type"]?.lowercased(),
           contentType.contains("text/event-stream") {
            return true
        }

        guard let bodyText = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !bodyText.isEmpty else {
            return false
        }

        return bodyText.hasPrefix("data:") || bodyText.hasPrefix("event:")
    }

    private func extractUsageFromSSEBody(_ body: Data) -> [String: Any]? {
        let events = parseSSEEvents(from: body)
        var latestUsage: [String: Any]?

        for event in events {
            guard event.data != "[DONE]",
                  let payloadData = event.data.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }
            if let usage = extractUsagePayload(from: parsed) {
                latestUsage = usage
            }
        }

        return latestUsage
    }

    private func extractUsagePayload(from payload: [String: Any]) -> [String: Any]? {
        if let usage = payload["usage"] as? [String: Any] {
            return usage
        }
        if let response = payload["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private static func responseHeaders(from response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var headers: [String: String] = [:]
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String else { continue }
            headers[key.lowercased()] = String(describing: rawValue)
        }
        return headers
    }

    static func shouldRetryWithAutoReasoningSummary(statusCode: Int, bodyText: String) -> Bool {
        guard statusCode == 400 else { return false }
        let normalized = bodyText.lowercased()
        return normalized.contains("unsupported value")
            && normalized.contains("none")
            && (normalized.contains("model")
                || normalized.contains("reasoning.summary")
                || normalized.contains("reasoning.effort"))
    }

    static func payloadWithAutoReasoningSummaryIfNeeded(payload: [String: Any]) -> [String: Any]? {
        guard var reasoning = payload["reasoning"] as? [String: Any] else {
            return nil
        }

        let summaryRaw = (reasoning["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let effortRaw = (reasoning["effort"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let shouldFixSummary = summaryRaw == "none"
        let shouldFixEffort = effortRaw == "none"

        guard shouldFixSummary || shouldFixEffort else {
            return nil
        }

        var updated = payload
        if shouldFixSummary {
            reasoning["summary"] = "auto"
        }
        if shouldFixEffort {
            reasoning["effort"] = "medium"
        }
        updated["reasoning"] = reasoning
        return updated
    }

    static func normalizedReasoningSummaryForUpstream(_ summary: String?) -> String {
        let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = raw.lowercased()
        if lowered.isEmpty || lowered == "none" {
            return "auto"
        }
        return raw
    }

    static func normalizedReasoningForUpstream(_ reasoning: [String: Any], upstreamModel: String? = nil) -> [String: Any] {
        var result = reasoning
        let effort = normalizedReasoningEffortForUpstream(result["effort"] as? String, upstreamModel: upstreamModel)
        result["effort"] = effort
        let summary = result["summary"] as? String
        result["summary"] = normalizedReasoningSummaryForUpstream(summary)
        return result
    }

    static func normalizedReasoningEffortForUpstream(_ effort: String?, upstreamModel: String? = nil) -> String {
        let raw = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let routeFamily = upstreamModel.map(resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        let defaultEffort = defaultReasoningEffortForUpstream(upstreamModel)

        if raw.isEmpty {
            return defaultEffort
        }

        if routeFamily == .codex {
            switch raw {
            case "low", "medium", "high", "xhigh":
                return raw
            case "none", "minimal":
                return defaultEffort
            default:
                return defaultEffort
            }
        }

        switch raw {
        case "none", "minimal", "low", "medium", "high", "xhigh":
            return raw
        default:
            return defaultEffort
        }
    }

    static func defaultReasoningEffortForUpstream(_ upstreamModel: String?) -> String {
        let routeFamily = upstreamModel.map(resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        return routeFamily == .codex ? "medium" : "none"
    }

    static func normalizedForwardHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadCandidatePlan() throws -> ProxyCandidatePlan {
        let store = try storeRepository.loadStore()
        if store.proxySelection?.mode == .autoUniform {
            let candidates = store.accounts.compactMap { account in
                try? makeProxyCandidate(from: account)
            }
            return ProxyCandidatePlan(
                routingMode: .autoUniform,
                candidates: candidates.sorted(by: stableAutoUniformCandidateOrder)
            )
        }

        guard let selection = effectiveProxySelection(in: store) else {
            return ProxyCandidatePlan(routingMode: .targetedSelection, candidates: [])
        }

        let candidates = try store.accounts.compactMap { account -> ProxyCandidate? in
            guard account.matchesSelection(
                accountKey: selection.accountKey,
                variantKey: selection.variantKey
            ) else {
                return nil
            }
            return try makeProxyCandidate(from: account)
        }

        return ProxyCandidatePlan(
            routingMode: .targetedSelection,
            candidates: candidates.sorted { lhs, rhs in
                lhs.remainingScore > rhs.remainingScore
            }
        )
    }

    private func effectiveProxySelection(
        in store: AccountsStore
    ) -> (accountKey: String, variantKey: String?)? {
        if let proxySelection = store.proxySelection,
           let proxyAccountKey = proxySelection.resolvedAccountKey,
           store.accounts.contains(where: {
               $0.matchesSelection(
                   accountKey: proxyAccountKey,
                   variantKey: proxySelection.resolvedVariantKey
               )
           }) {
            return (
                accountKey: proxyAccountKey,
                variantKey: proxySelection.resolvedVariantKey
            )
        }

        if let currentSelection = store.currentSelection,
           store.accounts.contains(where: {
               $0.matchesSelection(
                   accountKey: currentSelection.resolvedAccountKey,
                   variantKey: currentSelection.resolvedVariantKey
               )
           }) {
            return (
                accountKey: currentSelection.resolvedAccountKey,
                variantKey: currentSelection.resolvedVariantKey
            )
        }

        return nil
    }

    private func makeProxyCandidate(from account: StoredAccount) throws -> ProxyCandidate {
        let extracted = try authRepository.extractAuth(from: account.authJSON)
        return ProxyCandidate(
            id: account.id,
            label: account.label,
            accountID: extracted.accountID,
            accessToken: extracted.accessToken,
            authJSON: account.authJSON,
            oneWeekUsed: account.usage?.oneWeek?.usedPercent,
            fiveHourUsed: account.usage?.fiveHour?.usedPercent
        )
    }

    private func orderedCandidatesForRequest(_ plan: ProxyCandidatePlan) -> [ProxyCandidate] {
        switch plan.routingMode {
        case .targetedSelection:
            return plan.candidates
        case .autoUniform:
            guard !plan.candidates.isEmpty else { return [] }
            let offset = autoUniformLoadCursor % plan.candidates.count
            autoUniformLoadCursor = (autoUniformLoadCursor + 1) % plan.candidates.count
            return Array(plan.candidates[offset...]) + Array(plan.candidates[..<offset])
        }
    }

    private func stableAutoUniformCandidateOrder(lhs: ProxyCandidate, rhs: ProxyCandidate) -> Bool {
        let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
        if labelOrder != .orderedSame {
            return labelOrder == .orderedAscending
        }
        return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
    }

    private func parseJSONObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.request_body_must_be_object"))
        }
        return dict
    }

    private func normalizeProxyRequest(
        _ request: [String: Any],
        kind: DownstreamRequestKind
    ) throws -> NormalizedProxyRequest {
        switch kind {
        case .responses:
            return try normalizeResponsesProxyRequest(
                request,
                endpointKind: .responses,
                requiresInstructions: true
            )
        case .responsesCompact:
            return try normalizeResponsesProxyRequest(
                request,
                endpointKind: .responsesCompact,
                requiresInstructions: false
            )
        case .chatCompletions:
            let draft = try convertChatRequestToResponses(request)
            return try canonicalizeResponsesPayload(
                draft.payload,
                requestedModel: draft.requestedModel,
                downstreamStream: draft.downstreamStream,
                endpointKind: .responses,
                requiresInstructions: true
            )
        case .completions:
            let draft = try convertLegacyCompletionsRequestToResponses(request)
            return try canonicalizeResponsesPayload(
                draft.payload,
                requestedModel: draft.requestedModel,
                downstreamStream: draft.downstreamStream,
                endpointKind: .responses,
                requiresInstructions: true
            )
        }
    }

    private func normalizeResponsesProxyRequest(
        _ request: [String: Any],
        endpointKind: UpstreamEndpointKind,
        requiresInstructions: Bool
    ) throws -> NormalizedProxyRequest {
        guard let rawModel = request["model"] as? String,
              !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }

        let downstreamStream = (request["stream"] as? Bool) ?? false
        return try canonicalizeResponsesPayload(
            request,
            requestedModel: rawModel,
            downstreamStream: downstreamStream,
            endpointKind: endpointKind,
            requiresInstructions: requiresInstructions
        )
    }

    private func canonicalizeResponsesPayload(
        _ request: [String: Any],
        requestedModel: String,
        downstreamStream: Bool,
        endpointKind: UpstreamEndpointKind,
        requiresInstructions: Bool
    ) throws -> NormalizedProxyRequest {
        let upstreamModel = try mapClientModelToUpstream(requestedModel)
        var payload = request
        payload["model"] = upstreamModel
        hoistReasoningAliases(into: &payload)
        hoistTextAliases(into: &payload)
        enforceRequiredCodexUpstreamDefaults(in: &payload, upstreamModel: upstreamModel)
        stripUnsupportedCodexUpstreamParameters(in: &payload, upstreamModel: upstreamModel)
        try canonicalizeCodexInputStructure(in: &payload, upstreamModel: upstreamModel)

        if endpointKind == .responses && !downstreamStream {
            payload["stream"] = true
        }

        if requiresInstructions {
            ensureRequiredInstructions(in: &payload)
        }

        let currentReasoning = payload["reasoning"] as? [String: Any] ?? [:]
        if !currentReasoning.isEmpty {
            payload["reasoning"] = Self.normalizedReasoningForUpstream(
                currentReasoning,
                upstreamModel: upstreamModel
            )
        }

        return NormalizedProxyRequest(
            requestedModel: requestedModel,
            payload: payload,
            downstreamStream: downstreamStream,
            endpointKind: endpointKind
        )
    }

    private func currentSettings() -> AppSettings {
        (try? storeRepository.loadStore().settings) ?? .defaultValue
    }

    private func convertChatRequestToResponses(
        _ request: [String: Any]
    ) throws -> (requestedModel: String, payload: [String: Any], downstreamStream: Bool) {
        guard let rawModel = request["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }

        guard let messages = request["messages"] as? [Any] else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.chat_missing_messages"))
        }

        let downstreamStream = (request["stream"] as? Bool) ?? false
        var payload = request
        payload.removeValue(forKey: "messages")
        payload.removeValue(forKey: "functions")
        payload.removeValue(forKey: "function_call")
        payload.removeValue(forKey: "stream_options")
        if let requestedChoices = request["n"] {
            _ = try validatedSingleChoiceCount(requestedChoices, context: "chat completions")
            payload.removeValue(forKey: "n")
        }

        let inferredInstructions = normalizedInstructionsValue(from: payload["instructions"])
            ?? inferredInstructions(from: messages)
        let shouldHoistDeveloperMessagesToInstructions = normalizedInstructionsValue(from: payload["instructions"]) == nil
            && inferredInstructions != nil

        var input: [[String: Any]] = []
        for raw in messages {
            guard let message = raw as? [String: Any] else {
                throw AppError.invalidData(L10n.tr("error.proxy_runtime.messages_item_must_be_object"))
            }

            guard let role = message["role"] as? String, !role.isEmpty else {
                throw AppError.invalidData(L10n.tr("error.proxy_runtime.message_missing_role"))
            }

            if shouldHoistDeveloperMessagesToInstructions,
               role == "system" || role == "developer" {
                continue
            }

            if role == "tool" {
                let callID = (message["tool_call_id"] as? String) ?? ""
                let output = stringifyMessageContent(message["content"])
                input.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ])
                continue
            }

            let mappedRole: String
            switch role {
            case "system", "developer": mappedRole = "developer"
            case "assistant": mappedRole = "assistant"
            default: mappedRole = "user"
            }

            let contentParts = convertMessageContentToCodexParts(role: role, content: message["content"])
            input.append([
                "type": "message",
                "role": mappedRole,
                "content": contentParts
            ])

            if role == "assistant",
               let toolCalls = message["tool_calls"] as? [Any] {
                for rawToolCall in toolCalls {
                    guard let toolCall = rawToolCall as? [String: Any] else { continue }
                    let toolType = (toolCall["type"] as? String) ?? "function"
                    if toolType != "function" { continue }
                    guard let function = toolCall["function"] as? [String: Any] else { continue }

                    let name = (function["name"] as? String) ?? ""
                    let arguments = stringifyJSONField(function["arguments"])
                    let callID = (toolCall["id"] as? String) ?? ""
                    input.append([
                        "type": "function_call",
                        "call_id": callID,
                        "name": name,
                        "arguments": arguments
                    ])
                }
            }
        }

        let reasoningEffort = (request["reasoningEffort"] as? String)
            ?? (request["reasoning_effort"] as? String)
            ?? ((payload["reasoning"] as? [String: Any])?["effort"] as? String)
        var reasoning = payload["reasoning"] as? [String: Any] ?? [:]
        if let reasoningEffort {
            reasoning["effort"] = reasoningEffort
        }
        if !reasoning.isEmpty {
            payload["reasoning"] = reasoning
        }

        payload["stream"] = downstreamStream
        payload["input"] = input
        payload["instructions"] = inferredInstructions ?? Self.defaultRequiredInstructions

        let rawTools = (request["tools"] as? [Any]) ?? legacyFunctionsAsTools(request["functions"])
        if let tools = rawTools {
            var convertedTools: [[String: Any]] = []
            for rawTool in tools {
                guard let tool = rawTool as? [String: Any] else { continue }
                let type = (tool["type"] as? String) ?? ""
                if type == "function",
                   let function = tool["function"] as? [String: Any] {
                    var converted: [String: Any] = ["type": "function"]
                    if let name = function["name"] { converted["name"] = name }
                    if let description = function["description"] { converted["description"] = description }
                    if let parameters = function["parameters"] { converted["parameters"] = parameters }
                    if let strict = function["strict"] { converted["strict"] = strict }
                    convertedTools.append(converted)
                } else {
                    convertedTools.append(tool)
                }
            }
            if !convertedTools.isEmpty {
                payload["tools"] = convertedTools
            }
        }
        if let toolChoice = request["tool_choice"] ?? legacyFunctionCallAsToolChoice(request["function_call"]) {
            payload["tool_choice"] = toolChoice
        }

        if let responseFormat = payload.removeValue(forKey: "response_format") {
            mapResponseFormat(into: &payload, responseFormat: responseFormat)
        }
        if let text = request["text"] {
            mapTextSettings(into: &payload, text: text)
        }

        return (rawModel, payload, downstreamStream)
    }

    private func convertLegacyCompletionsRequestToResponses(
        _ request: [String: Any]
    ) throws -> (requestedModel: String, payload: [String: Any], downstreamStream: Bool) {
        guard request["prompt"] != nil else {
            throw AppError.invalidData("Completions request missing prompt.")
        }

        guard let rawModel = request["model"] as? String, !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidData(L10n.tr("error.proxy_runtime.missing_model"))
        }

        let downstreamStream = (request["stream"] as? Bool) ?? false
        var payload = request

        try validateLegacyCompletionsCompatibility(request)
        payload.removeValue(forKey: "echo")
        payload.removeValue(forKey: "logprobs")
        payload.removeValue(forKey: "logit_bias")
        if request["suffix"] != nil {
            throw AppError.invalidData("The suffix parameter is not supported for completions.")
        }
        if request["best_of"] != nil {
            throw AppError.invalidData("The best_of parameter is not supported for completions.")
        }

        if let requestedChoices = request["n"] {
            _ = try validatedSingleChoiceCount(requestedChoices, context: "completions")
            payload.removeValue(forKey: "n")
        }

        let promptText = try normalizeLegacyPrompt(request["prompt"])
        payload.removeValue(forKey: "prompt")
        payload["stream"] = downstreamStream
        payload["input"] = promptText
        ensureRequiredInstructions(in: &payload)

        return (rawModel, payload, downstreamStream)
    }

    private func validateLegacyCompletionsCompatibility(_ request: [String: Any]) throws {
        if let enabled = try strictJSONBooleanValue(request["echo"], parameterName: "echo") {
            if enabled {
                throw AppError.invalidData("The echo parameter is not supported for completions.")
            }
        }

        if let logprobs = request["logprobs"], !(logprobs is NSNull) {
            throw AppError.invalidData("The logprobs parameter is not supported for completions.")
        }

        if let logitBias = request["logit_bias"], !(logitBias is NSNull) {
            throw AppError.invalidData("The logit_bias parameter is not supported for completions.")
        }
    }

    private func enforceRequiredCodexUpstreamDefaults(in payload: inout [String: Any], upstreamModel: String?) {
        let routeFamily = upstreamModel.map(Self.resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        guard routeFamily == .codex else { return }
        payload["store"] = false
    }

    private func stripUnsupportedCodexUpstreamParameters(in payload: inout [String: Any], upstreamModel: String?) {
        let routeFamily = upstreamModel.map(Self.resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        guard routeFamily == .codex else { return }
        let removedParameters = removeUnsupportedCodexParameters(from: &payload)
        guard !removedParameters.isEmpty else {
            return
        }

        appendCompatibilityWarningLog(
            model: upstreamModel ?? "codex",
            message: L10n.tr(
                "proxy.log.codex_parameters_stripped_format",
                removedParameters.joined(separator: ", ")
            )
        )
    }

    private func removeUnsupportedCodexParameters(from payload: inout [String: Any]) -> [String] {
        let unsupportedKeys = [
            "stream_options",
            "max_tokens",
            "max_output_tokens",
            "max_completion_tokens"
        ]

        var removed: [String] = []
        for key in unsupportedKeys {
            if let value = payload[key], !(value is NSNull) {
                removed.append(key)
            }
            payload.removeValue(forKey: key)
        }
        return removed
    }

    private func appendCompatibilityWarningLog(model: String, message: String) {
        let now = dateProvider.unixSecondsNow()
        let signature = "\(model)|\(message)"
        if let lastLoggedAt = compatibilityWarningLastLoggedAt[signature],
           now - lastLoggedAt < ProxyLogDefaults.compatibilityWarningThrottleSeconds {
            return
        }
        compatibilityWarningLastLoggedAt[signature] = now
        logger.warning(
            category: .proxy,
            event: "compatibility_warning",
            message: message,
            metadata: ["model": model]
        )
    }

    private func canonicalizeCodexInputStructure(in payload: inout [String: Any], upstreamModel: String?) throws {
        let routeFamily = upstreamModel.map(Self.resolveUpstreamRouteFamily(forUpstreamModel:)) ?? .general
        guard routeFamily == .codex else { return }
        guard let rawInput = payload["input"] else { return }

        if let text = rawInput as? String {
            payload["input"] = [[
                "type": "message",
                "role": "user",
                "content": convertMessageContentToCodexParts(role: "user", content: text)
            ]]
            return
        }

        guard let items = rawInput as? [Any] else {
            throw AppError.invalidData("The input parameter must be a list for Codex routes.")
        }

        payload["input"] = try items.map { try canonicalizeCodexInputItem($0) }
    }

    private func canonicalizeCodexInputItem(_ raw: Any) throws -> [String: Any] {
        if let text = raw as? String {
            return [
                "type": "message",
                "role": "user",
                "content": convertMessageContentToCodexParts(role: "user", content: text)
            ]
        }

        guard let object = raw as? [String: Any] else {
            throw AppError.invalidData("Each input item must be an object for Codex routes.")
        }

        if let type = object["type"] as? String {
            if type == "message" {
                let role = normalizedCodexMessageRole(object["role"] as? String)
                var normalized = object
                normalized["type"] = "message"
                normalized["role"] = role
                normalized["content"] = convertMessageContentToCodexParts(role: role, content: object["content"])
                return normalized
            }
            return object
        }

        guard let rawRole = object["role"] as? String, !rawRole.isEmpty else {
            throw AppError.invalidData("Each input item must include a role for Codex routes.")
        }

        let role = normalizedCodexMessageRole(rawRole)
        return [
            "type": "message",
            "role": role,
            "content": convertMessageContentToCodexParts(role: role, content: object["content"])
        ]
    }

    private func normalizedCodexMessageRole(_ role: String?) -> String {
        switch role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system", "developer":
            return "developer"
        case "assistant":
            return "assistant"
        default:
            return "user"
        }
    }

    private func hoistReasoningAliases(into payload: inout [String: Any]) {
        let summaryAliases = ["reasoningSummary", "reasoning_summary"]
        let effortAliases = ["reasoningEffort", "reasoning_effort"]

        var reasoning = payload["reasoning"] as? [String: Any] ?? [:]
        var didUpdate = !reasoning.isEmpty

        if reasoning["summary"] == nil {
            for key in summaryAliases {
                if let value = payload.removeValue(forKey: key) as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reasoning["summary"] = value
                    didUpdate = true
                    break
                }
            }
        } else {
            for key in summaryAliases {
                payload.removeValue(forKey: key)
            }
        }

        if reasoning["effort"] == nil {
            for key in effortAliases {
                if let value = payload.removeValue(forKey: key) as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    reasoning["effort"] = value
                    didUpdate = true
                    break
                }
            }
        } else {
            for key in effortAliases {
                payload.removeValue(forKey: key)
            }
        }

        if didUpdate {
            payload["reasoning"] = reasoning
        }
    }

    private func hoistTextAliases(into payload: inout [String: Any]) {
        var target = payload["text"] as? [String: Any] ?? [:]
        var didUpdate = !target.isEmpty

        if target["verbosity"] == nil,
           let verbosity = payload.removeValue(forKey: "verbosity"),
           !(verbosity is NSNull) {
            target["verbosity"] = verbosity
            didUpdate = true
        } else {
            payload.removeValue(forKey: "verbosity")
        }

        if didUpdate {
            payload["text"] = target
        }
    }

    private func normalizeLegacyPrompt(_ value: Any?) throws -> String {
        let prompts = try normalizedLegacyPrompts(value)
        guard prompts.count <= 1 else {
            throw AppError.invalidData("Only a single prompt is supported for streaming completions.")
        }
        return prompts.first ?? ""
    }

    private func normalizedLegacyPrompts(_ value: Any?) throws -> [String] {
        guard let value else { return [] }

        if let text = value as? String {
            return [text]
        }

        if let items = value as? [Any] {
            if items.allSatisfy({ $0 is NSNumber }) {
                throw AppError.invalidData("Token array prompts are not supported for completions.")
            }
            if items.allSatisfy({ item in
                guard let nested = item as? [Any] else { return false }
                return nested.allSatisfy { $0 is NSNumber }
            }) {
                throw AppError.invalidData("Token array prompts are not supported for completions.")
            }

            let strings = items.compactMap { item -> String? in
                if let text = item as? String {
                    return text
                }
                return nil
            }
            guard strings.count == items.count else {
                throw AppError.invalidData("Only string prompt values are supported for completions.")
            }
            return strings
        }

        throw AppError.invalidData("Unsupported prompt type for completions.")
    }

    private func validatedSingleChoiceCount(_ value: Any, context: String) throws -> Int {
        guard let number = value as? NSNumber, !Self.isJSONBoolean(number) else {
            throw AppError.invalidData("The n parameter must be an integer.")
        }

        let doubleValue = number.doubleValue
        guard doubleValue.rounded(.towardZero) == doubleValue else {
            throw AppError.invalidData("The n parameter must be an integer.")
        }

        let intValue = number.intValue
        guard intValue == 1 else {
            throw AppError.invalidData("Only n=1 is supported for \(context).")
        }

        return intValue
    }

    private func strictJSONBooleanValue(_ value: Any?, parameterName: String) throws -> Bool? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        guard let number = value as? NSNumber, Self.isJSONBoolean(number) else {
            throw AppError.invalidData("The \(parameterName) parameter must be a boolean when provided.")
        }
        return number.boolValue
    }

    private static func isJSONBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private func ensureRequiredInstructions(in payload: inout [String: Any]) {
        if let normalized = normalizedInstructionsValue(from: payload["instructions"]) {
            payload["instructions"] = normalized
            return
        }

        payload["instructions"] = Self.defaultRequiredInstructions
    }

    private func inferredInstructions(from messages: [Any]) -> String? {
        let parts = messages.compactMap { raw -> String? in
            guard let message = raw as? [String: Any],
                  let role = message["role"] as? String,
                  role == "system" || role == "developer" else {
                return nil
            }
            return normalizedInstructionsValue(from: message["content"])
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    private func normalizedInstructionsValue(from value: Any?) -> String? {
        let text = stringifyMessageContent(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func legacyFunctionsAsTools(_ value: Any?) -> [Any]? {
        guard let functions = value as? [Any] else { return nil }
        return functions.compactMap { raw in
            guard let function = raw as? [String: Any] else { return nil }
            return [
                "type": "function",
                "function": function
            ]
        }
    }

    private func legacyFunctionCallAsToolChoice(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let text = value as? String {
            switch text {
            case "auto", "none", "required":
                return text
            default:
                return [
                    "type": "function",
                    "function": ["name": text]
                ]
            }
        }
        if let object = value as? [String: Any],
           let name = object["name"] {
            return [
                "type": "function",
                "function": ["name": name]
            ]
        }
        return nil
    }

    private func convertMessageContentToCodexParts(role: String, content: Any?) -> [[String: Any]] {
        let textType = role == "assistant" ? "output_text" : "input_text"

        guard let content else { return [] }

        if let text = content as? String {
            guard !text.isEmpty else { return [] }
            return [["type": textType, "text": text]]
        }

        guard let items = content as? [Any] else { return [] }
        var parts: [[String: Any]] = []

        for raw in items {
            guard let item = raw as? [String: Any],
                  let type = item["type"] as? String else { continue }

            if (type == "text" || type == "input_text" || type == "output_text"),
               let text = item["text"] as? String {
                parts.append(["type": textType, "text": text])
                continue
            }

            if type == "image_url",
               let image = item["image_url"] as? [String: Any],
               let url = image["url"] as? String,
               ["user", "developer", "system"].contains(role) {
                parts.append(["type": "input_image", "image_url": url])
                continue
            }

            if type == "input_image",
               let url = item["image_url"] as? String,
               ["user", "developer", "system"].contains(role) {
                parts.append(["type": "input_image", "image_url": url])
                continue
            }
        }

        return parts
    }

    private func stringifyContent(_ value: Any?) -> String {
        guard let value else { return "" }

        if let text = value as? String {
            return text
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }

    private func stringifyMessageContent(_ content: Any?) -> String {
        guard let content else { return "" }

        if let text = content as? String {
            return text
        }

        if let items = content as? [Any] {
            let texts = items.compactMap { item -> String? in
                guard let object = item as? [String: Any] else { return nil }
                return object["text"] as? String
            }
            return texts.joined(separator: "\n")
        }

        if let null = content as? NSNull, null == NSNull() {
            return ""
        }

        if JSONSerialization.isValidJSONObject(content),
           let data = try? JSONSerialization.data(withJSONObject: content),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return ""
    }

    private func stringifyJSONField(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String {
            return text
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }

    private func mapResponseFormat(into root: inout [String: Any], responseFormat: Any) {
        guard let formatObject = responseFormat as? [String: Any],
              let formatType = formatObject["type"] as? String else {
            return
        }

        var text = root["text"] as? [String: Any] ?? [:]
        var format = text["format"] as? [String: Any] ?? [:]

        switch formatType {
        case "text":
            format["type"] = "text"
        case "json_schema":
            format["type"] = "json_schema"
            if let schemaObject = formatObject["json_schema"] as? [String: Any] {
                if let name = schemaObject["name"] { format["name"] = name }
                if let strict = schemaObject["strict"] { format["strict"] = strict }
                if let schema = schemaObject["schema"] { format["schema"] = schema }
            }
        default:
            break
        }

        text["format"] = format
        root["text"] = text
    }

    private func mapTextSettings(into root: inout [String: Any], text value: Any) {
        guard let textObject = value as? [String: Any],
              let verbosity = textObject["verbosity"] else {
            return
        }

        var target = root["text"] as? [String: Any] ?? [:]
        target["verbosity"] = verbosity
        root["text"] = target
    }

    private func convertCompletedResponseToChatCompletion(_ response: [String: Any], fallbackModel: String) -> [String: Any] {
        let id = (response["id"] as? String) ?? "chatcmpl_\(UUID().uuidString)"
        let created = (response["created_at"] as? Int) ?? Int(dateProvider.unixSecondsNow())
        let model = normalizeModelForClient((response["model"] as? String) ?? fallbackModel)

        var message: [String: Any] = ["role": "assistant"]
        var reasoningContent: String?
        var textContent: String?
        var toolCalls: [[String: Any]] = []

        if let output = response["output"] as? [Any] {
            for rawItem in output {
                guard let item = rawItem as? [String: Any],
                      let type = item["type"] as? String else { continue }

                switch type {
                case "reasoning":
                    if let summary = item["summary"] as? [Any] {
                        for rawSummary in summary {
                            guard let summaryObject = rawSummary as? [String: Any] else { continue }
                            if (summaryObject["type"] as? String) == "summary_text",
                               let text = summaryObject["text"] as? String,
                               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                reasoningContent = text
                                break
                            }
                        }
                    }
                case "message":
                    if let content = item["content"] as? [Any] {
                        var chunks: [String] = []
                        for rawContent in content {
                            guard let contentObject = rawContent as? [String: Any] else { continue }
                            if (contentObject["type"] as? String) == "output_text",
                               let text = contentObject["text"] as? String,
                               !text.isEmpty {
                                chunks.append(text)
                            }
                        }
                        if !chunks.isEmpty {
                            textContent = chunks.joined()
                        }
                    }
                case "function_call":
                    let callID = (item["call_id"] as? String) ?? ""
                    let name = (item["name"] as? String) ?? ""
                    let arguments = (item["arguments"] as? String) ?? ""
                    toolCalls.append([
                        "id": callID,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": arguments
                        ]
                    ])
                default:
                    break
                }
            }
        }

        if textContent == nil {
            textContent = extractAssistantText(fromCompletedResponse: response)
        }

        message["content"] = textContent ?? NSNull()
        if let reasoningContent {
            message["reasoning_content"] = reasoningContent
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }

        let finishReason = openAIFinishReason(
            from: response,
            defaultReason: toolCalls.isEmpty ? "stop" : "tool_calls"
        )

        var root: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason,
                "native_finish_reason": finishReason
            ]]
        ]

        if let usage = response["usage"] as? [String: Any] {
            root["usage"] = buildOpenAIUsage(from: usage)
        }

        return root
    }

    private func convertCompletedResponseToLegacyCompletion(_ response: [String: Any], fallbackModel: String) -> [String: Any] {
        let id = (response["id"] as? String) ?? "cmpl_\(UUID().uuidString)"
        let created = (response["created_at"] as? Int) ?? Int(dateProvider.unixSecondsNow())
        let model = normalizeModelForClient((response["model"] as? String) ?? fallbackModel)
        let text = extractAssistantText(fromCompletedResponse: response)

        let finishReason = openAIFinishReason(from: response, defaultReason: "stop")
        var root: [String: Any] = [
            "id": id,
            "object": "text_completion",
            "created": created,
            "model": model,
            "choices": [[
                "text": text,
                "index": 0,
                "logprobs": NSNull(),
                "finish_reason": finishReason
            ]]
        ]

        if let usage = response["usage"] as? [String: Any] {
            root["usage"] = buildOpenAIUsage(from: usage)
        }

        return root
    }

    private func convertResponsesSSEToChatCompletionsSSE(_ sseData: Data, fallbackModel: String) throws -> Data {
        let events = parseSSEEvents(from: sseData)
        var state = ChatStreamState(
            responseID: "chatcmpl_\(UUID().uuidString)",
            createdAt: Int(dateProvider.unixSecondsNow()),
            model: normalizeModelForClient(fallbackModel),
            functionCallIndex: -1,
            hasReceivedArgumentsDelta: false,
            hasToolCallAnnounced: false
        )

        var lines = ""
        for event in events {
            let chunks = translateSSEEventToChatChunks(event, state: &state)
            for chunk in chunks {
                lines += "data: \(jsonString(chunk))\n\n"
            }
        }

        lines += "data: [DONE]\n\n"
        return Data(lines.utf8)
    }

    private func convertResponsesSSEToCompletionsSSE(_ sseData: Data, fallbackModel: String) throws -> Data {
        let events = parseSSEEvents(from: sseData)
        var state = CompletionStreamState(
            responseID: "cmpl_\(UUID().uuidString)",
            createdAt: Int(dateProvider.unixSecondsNow()),
            model: normalizeModelForClient(fallbackModel)
        )

        var lines = ""
        for event in events {
            let chunks = translateSSEEventToCompletionChunks(event, state: &state)
            for chunk in chunks {
                lines += "data: \(jsonString(chunk))\n\n"
            }
        }

        lines += "data: [DONE]\n\n"
        return Data(lines.utf8)
    }

    private func translateSSEEventToChatChunks(_ event: SSEEvent, state: inout ChatStreamState) -> [[String: Any]] {
        guard event.data != "[DONE]",
              let payloadData = event.data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let kind = parsed["type"] as? String else {
            return []
        }

        switch kind {
        case "response.created":
            if let response = parsed["response"] as? [String: Any] {
                state.responseID = (response["id"] as? String) ?? state.responseID
                state.createdAt = (response["created_at"] as? Int) ?? state.createdAt
                state.model = normalizeModelForClient((response["model"] as? String) ?? state.model)
            }
            return []

        case "response.reasoning_summary_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "reasoning_content": delta],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.reasoning_summary_text.done":
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "reasoning_content": "\n\n"],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildChatChunk(
                    state: state,
                    delta: ["role": "assistant", "content": delta],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_item.added":
            guard let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else {
                return []
            }
            state.functionCallIndex += 1
            state.hasReceivedArgumentsDelta = false
            state.hasToolCallAnnounced = true
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "role": "assistant",
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "id": (item["call_id"] as? String) ?? "",
                            "type": "function",
                            "function": [
                                "name": (item["name"] as? String) ?? "",
                                "arguments": ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.function_call_arguments.delta":
            state.hasReceivedArgumentsDelta = true
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "function": [
                                "arguments": (parsed["delta"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.function_call_arguments.done":
            if state.hasReceivedArgumentsDelta {
                return []
            }
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "function": [
                                "arguments": (parsed["arguments"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.output_item.done":
            guard let item = parsed["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else {
                return []
            }

            if state.hasToolCallAnnounced {
                state.hasToolCallAnnounced = false
                return []
            }

            state.functionCallIndex += 1
            return [
                buildChatChunk(
                    state: state,
                    delta: [
                        "role": "assistant",
                        "tool_calls": [[
                            "index": state.functionCallIndex,
                            "id": (item["call_id"] as? String) ?? "",
                            "type": "function",
                            "function": [
                                "name": (item["name"] as? String) ?? "",
                                "arguments": (item["arguments"] as? String) ?? ""
                            ]
                        ]]
                    ],
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.completed":
            let finishReason = openAIFinishReason(
                from: parsed["response"] as? [String: Any],
                defaultReason: state.functionCallIndex >= 0 ? "tool_calls" : "stop"
            )
            return [
                buildChatChunk(
                    state: state,
                    delta: [:],
                    finishReason: finishReason,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        default:
            return []
        }
    }

    private func buildChatChunk(
        state: ChatStreamState,
        delta: [String: Any],
        finishReason: String?,
        usage: [String: Any]?
    ) -> [String: Any] {
        let finishValue: Any = finishReason ?? NSNull()
        var chunk: [String: Any] = [
            "id": state.responseID,
            "object": "chat.completion.chunk",
            "created": max(0, state.createdAt),
            "model": state.model,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishValue,
                "native_finish_reason": finishValue
            ]]
        ]

        if let usage {
            chunk["usage"] = buildOpenAIUsage(from: usage)
        }

        return chunk
    }

    private func translateSSEEventToCompletionChunks(_ event: SSEEvent, state: inout CompletionStreamState) -> [[String: Any]] {
        guard event.data != "[DONE]",
              let payloadData = event.data.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let kind = parsed["type"] as? String else {
            return []
        }

        switch kind {
        case "response.created":
            if let response = parsed["response"] as? [String: Any] {
                state.responseID = (response["id"] as? String) ?? state.responseID
                state.createdAt = (response["created_at"] as? Int) ?? state.createdAt
                state.model = normalizeModelForClient((response["model"] as? String) ?? state.model)
            }
            return []

        case "response.output_text.delta":
            let delta = (parsed["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return [] }
            return [
                buildCompletionChunk(
                    state: state,
                    text: delta,
                    finishReason: nil,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        case "response.completed":
            let finishReason = openAIFinishReason(
                from: parsed["response"] as? [String: Any],
                defaultReason: "stop"
            )
            return [
                buildCompletionChunk(
                    state: state,
                    text: "",
                    finishReason: finishReason,
                    usage: ((parsed["response"] as? [String: Any])?["usage"] as? [String: Any])
                )
            ]

        default:
            return []
        }
    }

    private func buildCompletionChunk(
        state: CompletionStreamState,
        text: String,
        finishReason: String?,
        usage: [String: Any]?
    ) -> [String: Any] {
        let finishValue: Any = finishReason ?? NSNull()
        var chunk: [String: Any] = [
            "id": state.responseID,
            "object": "text_completion",
            "created": max(0, state.createdAt),
            "model": state.model,
            "choices": [[
                "text": text,
                "index": 0,
                "logprobs": NSNull(),
                "finish_reason": finishValue
            ]]
        ]

        if let usage {
            chunk["usage"] = buildOpenAIUsage(from: usage)
        }

        return chunk
    }

    private func aggregateOpenAIUsage(_ usages: [[String: Any]]) -> [String: Any]? {
        guard !usages.isEmpty else { return nil }

        var promptTokens = 0
        var completionTokens = 0
        var totalTokens = 0
        var cachedTokens = 0
        var reasoningTokens = 0
        var sawPrompt = false
        var sawCompletion = false
        var sawTotal = false
        var sawCached = false
        var sawReasoning = false

        for usage in usages {
            if let value = usage["prompt_tokens"] as? NSNumber {
                promptTokens += value.intValue
                sawPrompt = true
            }
            if let value = usage["completion_tokens"] as? NSNumber {
                completionTokens += value.intValue
                sawCompletion = true
            }
            if let value = usage["total_tokens"] as? NSNumber {
                totalTokens += value.intValue
                sawTotal = true
            }
            if let details = usage["prompt_tokens_details"] as? [String: Any],
               let value = details["cached_tokens"] as? NSNumber {
                cachedTokens += value.intValue
                sawCached = true
            }
            if let details = usage["completion_tokens_details"] as? [String: Any],
               let value = details["reasoning_tokens"] as? NSNumber {
                reasoningTokens += value.intValue
                sawReasoning = true
            }
        }

        var root: [String: Any] = [:]
        if sawPrompt { root["prompt_tokens"] = promptTokens }
        if sawCompletion { root["completion_tokens"] = completionTokens }
        if sawTotal { root["total_tokens"] = totalTokens }
        if sawCached { root["prompt_tokens_details"] = ["cached_tokens": cachedTokens] }
        if sawReasoning { root["completion_tokens_details"] = ["reasoning_tokens": reasoningTokens] }
        return root.isEmpty ? nil : root
    }

    private func openAIFinishReason(from response: [String: Any]?, defaultReason: String) -> String {
        guard let response else { return defaultReason }

        if let incompleteDetails = response["incomplete_details"] as? [String: Any],
           let reason = (incompleteDetails["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            switch reason {
            case "max_output_tokens", "max_tokens":
                return "length"
            case "content_filter":
                return "content_filter"
            default:
                break
            }
        }

        if let status = (response["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           status == "incomplete" {
            return "length"
        }

        return defaultReason
    }

    private func extractAssistantText(fromCompletedResponse response: [String: Any]) -> String {
        var segments: [String] = []

        if let outputs = response["output"] as? [Any] {
            for item in outputs {
                guard let object = item as? [String: Any] else { continue }

                if let type = object["type"] as? String, type == "output_text", let text = object["text"] as? String {
                    segments.append(text)
                    continue
                }

                if let messageType = object["type"] as? String, messageType == "message",
                   let content = object["content"] as? [Any] {
                    for part in content {
                        guard let partObj = part as? [String: Any] else { continue }
                        if let text = partObj["text"] as? String {
                            segments.append(text)
                        }
                    }
                }
            }
        }

        if segments.isEmpty, let text = response["output_text"] as? String {
            segments.append(text)
        }

        return segments.joined(separator: "")
    }

    private func buildOpenAIUsage(from usage: [String: Any]) -> [String: Any] {
        var root: [String: Any] = [:]
        if let inputTokens = usage["input_tokens"] {
            root["prompt_tokens"] = inputTokens
        }
        if let outputTokens = usage["output_tokens"] {
            root["completion_tokens"] = outputTokens
        }
        if let totalTokens = usage["total_tokens"] {
            root["total_tokens"] = totalTokens
        }
        if let inputDetails = usage["input_tokens_details"] as? [String: Any],
           let cached = inputDetails["cached_tokens"] {
            root["prompt_tokens_details"] = ["cached_tokens": cached]
        }
        if let outputDetails = usage["output_tokens_details"] as? [String: Any],
           let reasoning = outputDetails["reasoning_tokens"] {
            root["completion_tokens_details"] = ["reasoning_tokens": reasoning]
        }
        return root
    }

    private func completedResponseObject(from upstream: UpstreamResponse) throws -> [String: Any] {
        if isLikelySSEResponse(upstream) {
            return try extractCompletedResponse(fromSSE: upstream.body)
        }
        return try parseJSONObject(from: upstream.body)
    }

    private func extractCompletedResponse(fromSSE data: Data) throws -> [String: Any] {
        let events = parseSSEEvents(from: data)
        var lastJSON: [String: Any]?

        for event in events {
            guard event.data != "[DONE]" else { continue }
            guard let payloadData = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            lastJSON = object

            if (object["type"] as? String) == "response.completed",
               let response = object["response"] as? [String: Any] {
                return response
            }

            if object["id"] != nil, object["output"] != nil {
                return object
            }

            if (object["type"] as? String) == "response.error" {
                let message = (object["error"] as? [String: Any])?["message"] as? String ?? L10n.tr("error.proxy_runtime.upstream_response_error")
                throw AppError.network(message)
            }
        }

        if let lastJSON {
            return lastJSON
        }

        throw AppError.network(L10n.tr("error.proxy_runtime.sse_extract_completed_failed"))
    }

    private func parseSSEEvents(from data: Data) -> [SSEEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        return normalized
            .components(separatedBy: "\n\n")
            .compactMap { block in
                if block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }

                var eventName: String?
                var dataLines: [String] = []
                for line in block.components(separatedBy: "\n") {
                    if line.hasPrefix("event:") {
                        eventName = line.replacingOccurrences(of: "event:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces))
                    }
                }

                let joinedData = dataLines.joined(separator: "\n")
                return joinedData.isEmpty ? nil : SSEEvent(event: eventName, data: joinedData)
            }
    }

    private func mapClientModelToUpstream(_ model: String) throws -> String {
        let normalized = normalizedClientModelToken(model)
        if normalized == "gpt-5-4" || normalized == "gpt-5.4" || normalized == "gpt5.4" {
            return "gpt-5.4"
        }
        return normalizedNumericModelRevisionIfNeeded(normalized)
    }

    private func normalizeModelForClient(_ model: String) -> String {
        let normalized = model.lowercased()
        if normalized == "gpt5.4" || normalized == "gpt-5.4" {
            return "gpt-5-4"
        }
        return model
    }

    private func classifyRetryFailure(statusCode: Int, bodyText: String) -> RetryFailureInfo? {
        let signals = extractErrorSignals(rawText: bodyText)
        let status = statusCode

        if status == 402 || containsQuotaSignal(signals.normalized) {
            return RetryFailureInfo(category: .quotaExceeded, detail: L10n.tr("error.proxy_runtime.retry.quota_exceeded_format", signals.brief))
        }
        if containsModelRestrictionSignal(signals.normalized) {
            return RetryFailureInfo(category: .modelRestricted, detail: L10n.tr("error.proxy_runtime.retry.model_restricted_format", signals.brief))
        }
        if status == 429 || containsRateLimitSignal(signals.normalized) {
            return RetryFailureInfo(category: .rateLimited, detail: L10n.tr("error.proxy_runtime.retry.rate_limited_format", signals.brief))
        }
        if status == 401 || containsAuthSignal(signals.normalized) {
            return RetryFailureInfo(category: .authentication, detail: L10n.tr("error.proxy_runtime.retry.auth_failed_format", signals.brief))
        }
        if status == 403 || containsPermissionSignal(signals.normalized) {
            return RetryFailureInfo(category: .permission, detail: L10n.tr("error.proxy_runtime.retry.permission_denied_format", signals.brief))
        }
        return nil
    }

    private func extractErrorSignals(rawText: String) -> ErrorSignals {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []

        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            collectErrorParts(value, into: &parts)
        }

        if parts.isEmpty, !trimmed.isEmpty {
            parts.append(trimmed)
        }

        let deduped = parts.reduce(into: [String]()) { acc, item in
            guard !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !acc.contains(item) {
                acc.append(item)
            }
        }

        let joined = deduped.joined(separator: " | ")
        let brief = joined.isEmpty ? L10n.tr("error.proxy_runtime.no_error_detail") : truncateForError(joined, maxLength: 120)

        return ErrorSignals(
            normalized: "\(joined) \(trimmed)".lowercased(),
            brief: brief
        )
    }

    private func collectErrorParts(_ value: [String: Any], into parts: inout [String]) {
        if let error = value["error"] as? [String: Any] {
            if let message = error["message"] as? String { parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let code = error["code"] as? String { parts.append(code.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let type = error["type"] as? String { parts.append(type.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if let message = value["message"] as? String {
            parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func containsQuotaSignal(_ text: String) -> Bool {
        text.contains("insufficient_quota")
            || text.contains("quota exceeded")
            || text.contains("usage_limit")
            || text.contains("usage limit")
            || text.contains("credit balance")
            || text.contains("billing hard limit")
            || text.contains("exceeded your current quota")
            || text.contains("usage_limit_reached")
    }

    private func containsRateLimitSignal(_ text: String) -> Bool {
        text.contains("rate limit")
            || text.contains("rate_limit")
            || text.contains("too many requests")
            || text.contains("requests per min")
            || text.contains("tokens per min")
            || text.contains("retry after")
            || text.contains("requests too quickly")
    }

    private func containsModelRestrictionSignal(_ text: String) -> Bool {
        text.contains("model_not_found")
            || text.contains("does not have access to model")
            || text.contains("do not have access to model")
            || text.contains("access to model")
            || text.contains("unsupported model")
            || text.contains("model is not supported")
            || text.contains("not available on your account")
            || text.contains("model access")
    }

    private func containsAuthSignal(_ text: String) -> Bool {
        text.contains("invalid_api_key")
            || text.contains("invalid api key")
            || text.contains("authentication")
            || text.contains("unauthorized")
            || text.contains("token expired")
            || text.contains("account deactivated")
            || text.contains("invalid token")
    }

    private func containsPermissionSignal(_ text: String) -> Bool {
        text.contains("permission")
            || text.contains("forbidden")
            || text.contains("not allowed")
            || text.contains("organization")
            || text.contains("access denied")
    }

    private func buildRetriableFailureSummary(_ failures: [RetryFailureInfo]) -> String {
        var quota = 0
        var rate = 0
        var model = 0
        var auth = 0
        var permission = 0

        for failure in failures {
            switch failure.category {
            case .quotaExceeded:
                quota += 1
            case .rateLimited:
                rate += 1
            case .modelRestricted:
                model += 1
            case .authentication:
                auth += 1
            case .permission:
                permission += 1
            }
        }

        var parts: [String] = []
        if quota > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.quota_format", String(quota))) }
        if rate > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.rate_format", String(rate))) }
        if model > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.model_format", String(model))) }
        if auth > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.auth_format", String(auth))) }
        if permission > 0 { parts.append(L10n.tr("error.proxy_runtime.summary.permission_format", String(permission))) }

        return parts.joined(separator: "，")
    }

    private func truncateForError(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength { return value }
        let index = value.index(value.startIndex, offsetBy: maxLength)
        return "\(value[..<index])..."
    }

    private func jsonString(_ object: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private func jsonError(statusCode: Int, message: String) -> HTTPResponse {
        HTTPResponse.json(statusCode: statusCode, object: [
            "error": [
                "message": message,
                "type": statusCode == 400 ? "invalid_request_error" : "server_error"
            ]
        ])
    }

    private func upstreamEndpoint(
        forUpstreamModel model: String,
        endpointKind: UpstreamEndpointKind,
        queryItems: [URLQueryItem]
    ) -> URL {
        let routeFamily = Self.resolveUpstreamRouteFamily(forUpstreamModel: model)
        let base = resolveUpstreamBaseURL(routeFamily: routeFamily)
        let path: String
        switch endpointKind {
        case .responses:
            path = "\(base)/responses"
        case .responsesCompact:
            path = "\(base)/responses/compact"
        }
        guard var components = URLComponents(string: path) else {
            return URL(string: path)!
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url ?? URL(string: path)!
    }

    private func resolveUpstreamBaseURL(routeFamily: UpstreamRouteFamily) -> String {
        let defaultOrigin = "https://chatgpt.com"
        let configured = readChatGPTBaseURLFromConfig() ?? defaultOrigin
        return Self.resolveUpstreamBaseURL(configuredBaseURL: configured, routeFamily: routeFamily)
    }

    static func resolveUpstreamRouteFamily(forUpstreamModel model: String) -> UpstreamRouteFamily {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("codex")
            || normalized.hasPrefix("gpt-5")
            || normalized.hasPrefix("gpt-5.4")
            || normalized.hasPrefix("gpt5.4")
            || normalized.hasPrefix("gpt-5-4") {
            return .codex
        }
        return .general
    }

    static func resolveUpstreamBaseURL(configuredBaseURL: String, routeFamily: UpstreamRouteFamily) -> String {
        let normalized = normalizeConfiguredBaseURL(configuredBaseURL)
        let backendSuffix = "/backend-api"
        let codexSuffix = "/backend-api/codex"

        switch routeFamily {
        case .codex:
            if normalized.hasSuffix(codexSuffix) {
                return normalized
            }
            if normalized.hasSuffix(backendSuffix) {
                return "\(normalized)/codex"
            }
            return "\(normalized)\(codexSuffix)"
        case .general:
            if normalized.hasSuffix(codexSuffix) {
                return String(normalized.dropLast("/codex".count))
            }
            if normalized.hasSuffix(backendSuffix) {
                return normalized
            }
            return "\(normalized)\(backendSuffix)"
        }
    }

    static func normalizeConfiguredBaseURL(_ configuredBaseURL: String) -> String {
        var trimmed = configuredBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.hasSuffix("/backend-api/codex/responses") {
            trimmed = String(trimmed.dropLast("/responses".count))
        } else if trimmed.hasSuffix("/backend-api/responses") {
            trimmed = String(trimmed.dropLast("/responses".count))
        }

        return trimmed
    }

    private func readChatGPTBaseURLFromConfig() -> String? {
        guard let raw = try? String(contentsOf: paths.codexConfigPath, encoding: .utf8), !raw.isEmpty else {
            return nil
        }

        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("chatgpt_base_url") else { continue }
            guard let equalIndex = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equalIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func isAuthorized(_ headers: [String: String]) -> Bool {
        guard let expected = try? ensurePersistedAPIKey() else { return false }
        if let apiKeyHeader = headers["x-api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKeyHeader.isEmpty,
           apiKeyHeader == expected {
            return true
        }

        guard let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authorization.isEmpty else {
            return false
        }

        let lower = authorization.lowercased()
        if lower.hasPrefix("bearer ") {
            let provided = String(authorization.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return provided == expected
        }

        return authorization == expected
    }

    private func ensurePersistedAPIKey() throws -> String {
        if let key = try readPersistedAPIKey(), !key.isEmpty {
            return key
        }

        let generated = randomAPIKey()
        try persistAPIKey(generated)
        return generated
    }

    private func normalizedClientModelToken(_ model: String) -> String {
        model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedNumericModelRevisionIfNeeded(_ normalizedModel: String) -> String {
        guard normalizedModel.hasPrefix("gpt-5-") else {
            return normalizedModel
        }

        let suffix = String(normalizedModel.dropFirst("gpt-5-".count))
        guard let firstSegment = suffix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              !firstSegment.isEmpty,
              firstSegment.allSatisfy(\.isNumber) else {
            return normalizedModel
        }

        let afterRevision = String(suffix.dropFirst(firstSegment.count))
        return "gpt-5.\(firstSegment)\(afterRevision)"
    }

    private func readPersistedAPIKey() throws -> String? {
        guard FileManager.default.fileExists(atPath: paths.proxyDaemonKeyPath.path) else {
            return nil
        }

        let text = try String(contentsOf: paths.proxyDaemonKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func persistAPIKey(_ value: String) throws {
        try FileManager.default.createDirectory(at: paths.proxyDaemonDataDirectory, withIntermediateDirectories: true)
        try value.write(to: paths.proxyDaemonKeyPath, atomically: true, encoding: .utf8)
        #if canImport(Darwin)
        _ = chmod(paths.proxyDaemonKeyPath.path, S_IRUSR | S_IWUSR)
        #endif
    }

    private func randomAPIKey() -> String {
        "sk-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private func waitForHealth(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        let deadline = Date().addingTimeInterval(6)

        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return true
                }
            } catch {
                // retry until timeout
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        return false
    }

    private static func defaultLanBaseURLs(for port: Int) -> [String] {
        #if canImport(Darwin)
        var interfacesPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacesPointer) == 0, let firstInterface = interfacesPointer else {
            return []
        }
        defer { freeifaddrs(interfacesPointer) }

        var urls: [(name: String, value: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let isPointToPoint = (flags & IFF_POINTOPOINT) != 0
            guard isUp, isRunning, !isLoopback, !isPointToPoint else { continue }

            guard let addressPointer = interface.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let interfaceName = String(cString: interface.pointee.ifa_name)
            let host = ipv4AddressString(from: addressPointer)
            guard let host,
                  !host.isEmpty,
                  !host.hasPrefix("169.254.") else {
                continue
            }

            urls.append((name: interfaceName, value: "http://\(host):\(port)/v1"))
        }

        var seen = Set<String>()
        let uniqueURLs = urls.filter { seen.insert($0.value).inserted }

        return uniqueURLs
            .sorted { lhs, rhs in
                if interfaceRank(lhs.name) != interfaceRank(rhs.name) {
                    return interfaceRank(lhs.name) < interfaceRank(rhs.name)
                }
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                return lhs.value < rhs.value
            }
            .map(\.value)
        #else
        return []
        #endif
    }

    #if canImport(Darwin)
    private static func ipv4AddressString(from pointer: UnsafeMutablePointer<sockaddr>) -> String? {
        var address = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let conversion = inet_ntop(
            AF_INET,
            &address.sin_addr,
            &hostBuffer,
            socklen_t(INET_ADDRSTRLEN)
        )
        guard conversion != nil else { return nil }
        let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func interfaceRank(_ name: String) -> Int {
        if name.hasPrefix("en") { return 0 }
        if name.hasPrefix("bridge") { return 1 }
        return 2
    }
    #endif
}

private struct ProxyCandidate {
    var id: String
    var label: String
    var accountID: String
    var accessToken: String
    var authJSON: JSONValue
    var oneWeekUsed: Double?
    var fiveHourUsed: Double?

    var remainingScore: Double {
        let weekUsed = oneWeekUsed ?? 100
        let fiveUsed = fiveHourUsed ?? 100
        let weekRemaining = max(0, 100 - weekUsed)
        let fiveRemaining = max(0, 100 - fiveUsed)
        return weekRemaining * 0.7 + fiveRemaining * 0.3
    }
}

private enum ProxyCandidateRoutingMode {
    case targetedSelection
    case autoUniform
}

private struct ProxyCandidatePlan {
    var routingMode: ProxyCandidateRoutingMode
    var candidates: [ProxyCandidate]
}

private struct UpstreamResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

private struct UpstreamStreamingResponse {
    var statusCode: Int
    var headers: [String: String]
    var body: AsyncThrowingStream<Data, Error>
}

private enum UpstreamStreamingResult {
    case buffered(UpstreamResponse)
    case streaming(UpstreamStreamingResponse)
}

private struct SSEEvent {
    var event: String?
    var data: String
}

private enum RetryFailureCategory {
    case quotaExceeded
    case rateLimited
    case modelRestricted
    case authentication
    case permission
}

private struct RetryFailureInfo {
    var category: RetryFailureCategory
    var detail: String
}

private struct ErrorSignals {
    var normalized: String
    var brief: String
}

private struct NormalizedUsageCounts {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

private final class StreamingUsageAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private var latestUsage: [String: Any]?

    func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        processCompleteEvents()
    }

    func finalUsage() -> [String: Any]? {
        processCompleteEvents(flushRemainder: true)
        return latestUsage
    }

    private func processCompleteEvents(flushRemainder: Bool = false) {
        while let range = nextEventDelimiterRange(in: buffer) {
            let eventBlock = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            processEventBlock(eventBlock)
        }

        if flushRemainder, !buffer.isEmpty {
            processEventBlock(buffer)
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private func nextEventDelimiterRange(in data: Data) -> Range<Data.Index>? {
        let unixRange = data.range(of: Data("\n\n".utf8))
        let windowsRange = data.range(of: Data("\r\n\r\n".utf8))

        switch (unixRange, windowsRange) {
        case let (lhs?, rhs?):
            return lhs.lowerBound < rhs.lowerBound ? lhs : rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func processEventBlock(_ block: Data) {
        guard !block.isEmpty else { return }

        var normalizedBlock = block
        normalizedBlock.append(Data("\n\n".utf8))

        guard let text = String(data: normalizedBlock, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let dataLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
        }
        let payloadText = dataLines.joined(separator: "\n")
        guard payloadText != "[DONE]",
              let payloadData = payloadText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return
        }

        if let usage = parsed["usage"] as? [String: Any] {
            latestUsage = usage
            return
        }

        if let response = parsed["response"] as? [String: Any],
           let usage = response["usage"] as? [String: Any] {
            latestUsage = usage
        }
    }
}

private struct ChatStreamState {
    var responseID: String
    var createdAt: Int
    var model: String
    var functionCallIndex: Int
    var hasReceivedArgumentsDelta: Bool
    var hasToolCallAnnounced: Bool
}

private struct CompletionStreamState {
    var responseID: String
    var createdAt: Int
    var model: String
}
