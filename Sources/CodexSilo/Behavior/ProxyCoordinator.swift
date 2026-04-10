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

    init(
        proxyService: ProxyRuntimeService,
        storeRepository: AccountsStoreRepository,
        session: URLSession = .shared,
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.proxyService = proxyService
        self.storeRepository = storeRepository
        self.session = session
        self.dateProvider = dateProvider
    }

    func loadStatus() async -> ApiProxyStatus {
        await proxyService.status()
    }

    func startProxy(preferredPort: Int?) async throws -> ApiProxyStatus {
        try await proxyService.syncAccountsStore()
        return try await proxyService.start(preferredPort: preferredPort)
    }

    func stopProxy() async -> ApiProxyStatus {
        await proxyService.stop()
    }

    func refreshAPIKey() async throws -> ApiProxyStatus {
        try await proxyService.refreshAPIKey()
    }

    func resetMetrics() async throws -> ApiProxyStatus {
        try await proxyService.resetMetrics()
    }

    func loadLiveTestLogs() throws -> [ProxyLiveTestLogEntry] {
        try storeRepository.loadStore().proxyLiveTestLogs
    }

    func clearLiveTestLogs() throws {
        var store = try storeRepository.loadStore()
        store.proxyLiveTestLogs = []
        try storeRepository.saveStore(store)
    }

    func testLiveRequest(using status: ApiProxyStatus) async throws -> ProxyLiveTestResult {
        guard status.running else {
            let error = AppError.invalidData(L10n.tr("proxy.notice.test_request_requires_running_proxy"))
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
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
            throw error
        }

        guard let url = Self.liveTestURL(from: baseURL, endpoint: .responses) else {
            let error = AppError.invalidData(L10n.tr("proxy.notice.test_request_missing_credentials"))
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
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
            return result
        } catch let error as AppError {
            if Self.shouldFallbackToCompact(for: error),
               let compactURL = Self.liveTestURL(from: baseURL, endpoint: .responsesCompact) {
                do {
                    let compactRequest = try Self.liveTestRequest(
                        url: compactURL,
                        apiKey: apiKey,
                        payload: Self.liveTestCompactPayload(model: LiveTestDefaults.model)
                    )
                    let result = try await performLiveTestRequest(compactRequest, fallbackModel: LiveTestDefaults.model)
                    appendLiveTestLog(model: result.model, status: .success, message: result.outputPreview)
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
                    throw decorated
                } catch {
                    appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
                    throw error
                }
            }

            let decorated = Self.decorateLiveTestError(error, attemptedModels: [LiveTestDefaults.model])
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: decorated.localizedDescription)
            throw decorated
        } catch {
            appendLiveTestLog(model: LiveTestDefaults.model, status: .error, message: error.localizedDescription)
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
