import Foundation

final class ProxyCoordinator: @unchecked Sendable {
    private enum LiveTestDefaults {
        static let model = "gpt-5.4"
        static let prompt = "Reply with OK only."
        static let previewMaxLength = 80
        static let maxStoredLogs = 50
    }

    private enum LiveTestEndpoint {
        case responses
        case responsesCompact

        var pathSuffix: String {
            switch self {
            case .responses:
                return "/responses"
            case .responsesCompact:
                return "/responses/compact"
            }
        }

        var attemptDescription: String {
            pathSuffix
        }
    }

    private let proxyService: ProxyRuntimeService
    private let storeRepository: AccountsStoreRepository
    private let session: URLSession
    private let dateProvider: DateProviding
    private let logger: AppLogger

    init(
        proxyService: ProxyRuntimeService,
        storeRepository: AccountsStoreRepository,
        session: URLSession = .shared,
        dateProvider: DateProviding = SystemDateProvider(),
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.proxyService = proxyService
        self.storeRepository = storeRepository
        self.session = session
        self.dateProvider = dateProvider
        self.logger = logger
    }

    func loadStatus() async -> ApiProxyStatus {
        let status = await proxyService.status()
        logger.debug(
            category: .proxy,
            event: "status_loaded",
            message: "Loaded proxy status.",
            metadata: [
                "running": status.running ? "true" : "false",
                "port": status.port.map(String.init) ?? ""
            ]
        )
        return status
    }

    func startProxy(preferredPort: Int?) async throws -> ApiProxyStatus {
        logger.info(
            category: .proxy,
            event: "start_requested",
            message: "Starting API proxy.",
            metadata: ["preferred_port": preferredPort.map(String.init) ?? ""]
        )
        try await proxyService.syncAccountsStore()
        let status = try await proxyService.start(preferredPort: preferredPort)
        logger.info(
            category: .proxy,
            event: "start_succeeded",
            message: "API proxy started.",
            metadata: [
                "port": status.port.map(String.init) ?? "",
                "running": status.running ? "true" : "false"
            ]
        )
        return status
    }

    func stopProxy() async -> ApiProxyStatus {
        let status = await proxyService.stop()
        logger.info(
            category: .proxy,
            event: "stop_succeeded",
            message: "API proxy stopped."
        )
        return status
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        let status = try await proxyService.refreshAPIKey()
        logger.info(
            category: .proxy,
            event: "refresh_api_key_succeeded",
            message: "Proxy API key refreshed."
        )
        return status
    }

    func resetMetrics() async throws -> ApiProxyStatus {
        let status = try await proxyService.resetMetrics()
        logger.info(
            category: .proxy,
            event: "reset_metrics_succeeded",
            message: "Proxy metrics reset."
        )
        return status
    }

    func loadProxyAccountSelectionSnapshot() throws -> ProxyAccountSelectionSnapshot {
        let store = try storeRepository.loadStore()
        let currentOptionID = resolvedStoreAccountID(
            in: store.accounts,
            accountKey: store.currentSelection?.resolvedAccountKey,
            variantKey: store.currentSelection?.resolvedVariantKey
        )
        let selectedOptionID = resolvedStoreAccountID(
            in: store.accounts,
            accountKey: manualSelectionAccountKey(for: store.proxySelection),
            variantKey: manualSelectionVariantKey(for: store.proxySelection)
        )
        let selectedMode: ProxyAccountRoutingMode?
        if store.proxySelection?.mode == .autoUniform {
            selectedMode = .autoUniform
        } else if selectedOptionID != nil {
            selectedMode = .fixedAccount
        } else {
            selectedMode = nil
        }

        let options = store.accounts
            .map { account in
                ProxyAccountOption(
                    id: account.id,
                    label: account.label,
                    detail: optionDetail(for: account),
                    accountID: account.accountID,
                    isCurrent: account.id == currentOptionID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent {
                    return lhs.isCurrent
                }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

        return ProxyAccountSelectionSnapshot(
            options: options,
            mode: selectedMode,
            selectedOptionID: selectedOptionID,
            currentOptionID: currentOptionID
        )
    }

    func updateProxyAccountSelection(
        mode: ProxyAccountRoutingMode?,
        optionID: String?
    ) async throws -> ProxyAccountSelectionSnapshot {
        var store = try storeRepository.loadStore()

        switch mode {
        case .fixedAccount:
            guard let optionID else {
                throw AppError.invalidData(L10n.tr("error.proxy.account_not_found_for_selection"))
            }
            guard let account = store.accounts.first(where: { $0.id == optionID }) else {
                throw AppError.invalidData(L10n.tr("error.proxy.account_not_found_for_selection"))
            }
            store.proxySelection = ProxyAccountSelection(account: account)
        case .autoUniform:
            if let existingSelection = store.proxySelection,
               existingSelection.mode == .fixedAccount {
                store.proxySelection = ProxyAccountSelection(
                    mode: .autoUniform,
                    accountID: existingSelection.accountID,
                    accountKey: existingSelection.accountKey,
                    variantKey: existingSelection.variantKey
                )
            } else {
                store.proxySelection = .autoUniform
            }
        case nil:
            if let existingSelection = store.proxySelection,
               existingSelection.mode == .autoUniform,
               let restoredAccountID = resolvedStoreAccountID(
                   in: store.accounts,
                   accountKey: manualSelectionAccountKey(for: existingSelection),
                   variantKey: manualSelectionVariantKey(for: existingSelection)
               ),
               let restoredAccount = store.accounts.first(where: { $0.id == restoredAccountID }) {
                store.proxySelection = ProxyAccountSelection(account: restoredAccount)
            } else {
                store.proxySelection = nil
            }
        }

        try storeRepository.saveStore(store)
        try await proxyService.syncAccountsStore()

        logger.info(
            category: .proxy,
            event: "selection_updated",
            message: "Updated proxy account selection.",
            metadata: [
                "mode": mode?.rawValue ?? "followCurrent",
                "option_id": optionID ?? ""
            ]
        )

        return try loadProxyAccountSelectionSnapshot()
    }

    func loadLiveTestLogs() throws -> [ProxyLiveTestLogEntry] {
        try storeRepository.loadStore().proxyLiveTestLogs
    }

    func clearLiveTestLogs() throws {
        var store = try storeRepository.loadStore()
        store.proxyLiveTestLogs = []
        try storeRepository.saveStore(store)
        logger.info(
            category: .proxy,
            event: "clear_live_test_logs",
            message: "Cleared proxy live test logs."
        )
    }

    func testLiveRequest(using status: ApiProxyStatus) async throws -> ProxyLiveTestResult {
        let operationID = UUID().uuidString
        logger.info(
            category: .proxy,
            event: "live_test_started",
            message: "Starting proxy live test request.",
            metadata: [
                "running": status.running ? "true" : "false",
                "base_url": status.baseURL ?? "",
                "model": LiveTestDefaults.model
            ],
            operationID: operationID
        )
        guard status.running else {
            let error = AppError.invalidData(L10n.tr("proxy.notice.test_request_requires_running_proxy"))
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "live_test_failed_not_running",
                message: "Proxy live test aborted because the proxy is not running.",
                operationID: operationID
            )
            throw error
        }

        guard
            let baseURL = status.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !baseURL.isEmpty,
            let apiKey = status.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            let error = AppError.invalidData(L10n.tr("proxy.notice.test_request_missing_credentials"))
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "live_test_missing_credentials",
                message: "Proxy live test aborted because credentials are missing.",
                operationID: operationID
            )
            throw error
        }

        guard let url = Self.liveTestURL(from: baseURL, endpoint: .responses) else {
            let error = AppError.invalidData(L10n.tr("proxy.notice.test_request_missing_credentials"))
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "live_test_invalid_url",
                message: "Proxy live test failed because the computed URL was invalid.",
                metadata: ["base_url": baseURL],
                operationID: operationID
            )
            throw error
        }

        do {
            let request = try Self.liveTestRequest(
                url: url,
                apiKey: apiKey,
                payload: Self.liveTestPayload(model: LiveTestDefaults.model)
            )
            let result = try await performLiveTestRequest(request, fallbackModel: LiveTestDefaults.model)
            appendLiveTestLog(model: result.model, status: .success, message: result.outputPreview)
            logger.info(
                category: .proxy,
                event: "live_test_succeeded",
                message: "Proxy live test completed successfully.",
                metadata: [
                    "model": result.model,
                    "preview": result.outputPreview
                ],
                operationID: operationID
            )
            return result
        } catch let error as AppError {
            if Self.shouldFallbackToCompact(for: error),
               let compactURL = Self.liveTestURL(from: baseURL, endpoint: .responsesCompact) {
                logger.warning(
                    category: .proxy,
                    event: "live_test_fallback_to_compact",
                    message: "Proxy live test is retrying via compact responses endpoint.",
                    metadata: ["error": error.localizedDescription],
                    operationID: operationID
                )
                do {
                    let compactRequest = try Self.liveTestRequest(
                        url: compactURL,
                        apiKey: apiKey,
                        payload: Self.liveTestCompactPayload(model: LiveTestDefaults.model)
                    )
                    let result = try await performLiveTestRequest(compactRequest, fallbackModel: LiveTestDefaults.model)
                    appendLiveTestLog(model: result.model, status: .success, message: result.outputPreview)
                    logger.info(
                        category: .proxy,
                        event: "live_test_compact_succeeded",
                        message: "Proxy live test succeeded via compact fallback endpoint.",
                        metadata: [
                            "model": result.model,
                            "preview": result.outputPreview
                        ],
                        operationID: operationID
                    )
                    return result
                } catch let compactError as AppError {
                    let decorated = Self.decorateLiveTestError(
                        compactError,
                        attemptedModels: [LiveTestDefaults.model],
                        attemptedEndpoints: [
                            LiveTestEndpoint.responses.attemptDescription,
                            LiveTestEndpoint.responsesCompact.attemptDescription
                        ]
                    )
                    appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: decorated.localizedDescription)
                    logger.error(
                        category: .proxy,
                        event: "live_test_compact_failed",
                        message: "Proxy live test failed after compact fallback.",
                        metadata: ["error": decorated.localizedDescription],
                        operationID: operationID
                    )
                    throw decorated
                } catch {
                    appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
                    logger.error(
                        category: .proxy,
                        event: "live_test_failed",
                        message: "Proxy live test failed.",
                        metadata: ["error": error.localizedDescription],
                        operationID: operationID
                    )
                    throw error
                }
            }

            let decorated = Self.decorateLiveTestError(error, attemptedModels: [LiveTestDefaults.model])
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: decorated.localizedDescription)
            logger.error(
                category: .proxy,
                event: "live_test_failed",
                message: "Proxy live test failed.",
                metadata: ["error": decorated.localizedDescription],
                operationID: operationID
            )
            throw decorated
        } catch {
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
            logger.error(
                category: .proxy,
                event: "live_test_failed",
                message: "Proxy live test failed.",
                metadata: ["error": error.localizedDescription],
                operationID: operationID
            )
            throw error
        }
    }

    private func performLiveTestRequest(
        _ request: URLRequest,
        fallbackModel: String
    ) async throws -> ProxyLiveTestResult {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.network("Unexpected proxy test response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.network(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AppError.invalidData("Unexpected proxy test response.")
        }

        let model = ((object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackModel
        let preview = Self.extractPreview(from: object)

        return ProxyLiveTestResult(model: model, outputPreview: preview)
    }

    private static func liveTestPayload(model: String) -> [String: Any] {
        [
            "model": model,
            "store": false,
            "input": liveTestInputItems()
        ]
    }

    private func resolvedStoreAccountID(
        in accounts: [StoredAccount],
        accountKey: String?,
        variantKey: String?
    ) -> String? {
        accounts.first(where: {
            $0.matchesSelection(accountKey: accountKey, variantKey: variantKey)
        })?.id
    }

    private func manualSelectionAccountKey(for selection: ProxyAccountSelection?) -> String? {
        guard let selection, let accountID = selection.accountID else {
            return nil
        }
        return AccountIdentity.selectionIdentifier(
            accountKey: selection.accountKey,
            accountID: accountID
        )
    }

    private func manualSelectionVariantKey(for selection: ProxyAccountSelection?) -> String? {
        guard let selection else {
            return nil
        }
        return AccountIdentity.variantIdentifier(variantKey: selection.variantKey)
    }

    private func optionDetail(for account: StoredAccount) -> String? {
        let trimmedEmail = normalizedDetailText(account.email)
        let trimmedTeamName = normalizedDetailText(account.teamAlias) ?? normalizedDetailText(account.teamName)

        if let trimmedTeamName, !trimmedTeamName.isEmpty,
           let trimmedEmail, !trimmedEmail.isEmpty {
            return "\(trimmedTeamName) · \(trimmedEmail)"
        }

        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }

        if let trimmedTeamName, !trimmedTeamName.isEmpty {
            return trimmedTeamName
        }

        return nil
    }

    private func normalizedDetailText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func liveTestCompactPayload(model: String) -> [String: Any] {
        [
            "model": model,
            "store": false,
            "input": liveTestInputItems()
        ]
    }

    private static func liveTestInputItems() -> [[String: Any]] {
        [
            [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": LiveTestDefaults.prompt
                    ]
                ]
            ]
        ]
    }

    private static func liveTestRequest(
        url: URL,
        apiKey: String,
        payload: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private static func liveTestURL(from baseURL: String, endpoint: LiveTestEndpoint) -> URL? {
        let trimmedBaseURL = baseURL.hasSuffix("/")
            ? String(baseURL.dropLast())
            : baseURL
        let path = trimmedBaseURL.hasSuffix("/v1")
            ? "\(trimmedBaseURL)\(endpoint.pathSuffix)"
            : "\(trimmedBaseURL)/v1\(endpoint.pathSuffix)"
        return URL(string: path)
    }

    private static func extractPreview(from response: [String: Any]) -> String {
        if let outputText = response["output_text"] as? String {
            let sanitized = sanitizePreview(outputText)
            if !sanitized.isEmpty {
                return sanitized
            }
        }

        if let text = response["text"] as? String {
            let sanitized = sanitizePreview(text)
            if !sanitized.isEmpty {
                return sanitized
            }
        }

        if let output = response["output"] as? [Any] {
            for item in output {
                guard let itemObject = item as? [String: Any],
                      let content = itemObject["content"] as? [Any] else {
                    continue
                }

                for entry in content {
                    guard let entryObject = entry as? [String: Any],
                          let text = entryObject["text"] as? String else {
                        continue
                    }
                    let sanitized = sanitizePreview(text)
                    if !sanitized.isEmpty {
                        return sanitized
                    }
                }
            }
        }

        if let status = response["status"] as? String {
            let sanitized = sanitizePreview(status)
            if !sanitized.isEmpty {
                return sanitized
            }
        }

        return "OK"
    }

    private static func sanitizePreview(_ raw: String) -> String {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }

        if collapsed.count <= LiveTestDefaults.previewMaxLength {
            return collapsed
        }

        let end = collapsed.index(collapsed.startIndex, offsetBy: LiveTestDefaults.previewMaxLength)
        return "\(collapsed[..<end])..."
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "HTTP \(statusCode): \(message)"
        }

        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "HTTP \(statusCode): \(message)"
        }

        if
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty {
            return "HTTP \(statusCode): \(text)"
        }

        return "HTTP \(statusCode)"
    }

    private static func shouldFallbackToCompact(for error: AppError) -> Bool {
        guard case .network(let message) = error else { return false }
        let normalized = message.lowercased()
        return normalized.contains("http 404")
            && (normalized.contains("not_found") || normalized.contains("not found"))
    }

    private static func decorateLiveTestError(
        _ error: AppError,
        attemptedModels: [String],
        attemptedEndpoints: [String] = []
    ) -> AppError {
        guard !attemptedModels.isEmpty else { return error }
        let prefix: String
        if attemptedEndpoints.isEmpty {
            prefix = "Live test tried \(attemptedModels.joined(separator: ", "))."
        } else {
            prefix = "Live test tried \(attemptedModels.joined(separator: ", ")) via \(attemptedEndpoints.joined(separator: " and "))."
        }
        return switch error {
        case .fileNotFound(let message):
            .fileNotFound("\(prefix) \(message)")
        case .invalidData(let message):
            .invalidData("\(prefix) \(message)")
        case .io(let message):
            .io("\(prefix) \(message)")
        case .network(let message):
            .network("\(prefix) \(message)")
        case .unauthorized(let message):
            .unauthorized("\(prefix) \(message)")
        }
    }

    private func appendLiveTestLog(
        model: String,
        status: ProxyLiveTestLogEntry.Status,
        message: String
    ) {
        do {
            var store = try storeRepository.loadStore()
            store.proxyLiveTestLogs.insert(
                ProxyLiveTestLogEntry(
                    id: UUID().uuidString,
                    createdAt: dateProvider.unixSecondsNow(),
                    model: model,
                    status: status,
                    message: message
                ),
                at: 0
            )
            if store.proxyLiveTestLogs.count > LiveTestDefaults.maxStoredLogs {
                store.proxyLiveTestLogs = Array(store.proxyLiveTestLogs.prefix(LiveTestDefaults.maxStoredLogs))
            }
            try storeRepository.saveStore(store)
        } catch {
            // Keep the live request result authoritative even if log persistence fails.
        }
    }
}
