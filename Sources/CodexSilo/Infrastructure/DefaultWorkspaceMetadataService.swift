import Foundation

final class DefaultWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private enum RequestPolicy {
        static let timeout: TimeInterval = 18
        static let scope = "workspace-metadata"
    }

    private let session: URLSession
    private let configPath: URL
    private let endpointCoordinator: EndpointRequestCoordinator
    private let logger: AppLogger

    init(
        session: URLSession = .shared,
        configPath: URL,
        endpointPreferenceStore: EndpointPreferenceStore = .shared,
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.session = session
        self.configPath = configPath
        self.logger = logger
        self.endpointCoordinator = EndpointRequestCoordinator(
            session: session,
            preferenceStore: endpointPreferenceStore
        )
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
        let operationID = UUID().uuidString
        let startedAt = Date()
        let candidateCount = resolveAccountURLs().count
        logger.debug(
            category: .workspace,
            event: "fetch_started",
            message: "Starting workspace metadata fetch.",
            metadata: ["candidate_count": String(candidateCount)],
            operationID: operationID
        )
        #if DEBUG
        debugLog("starting workspace metadata fetch with \(resolveAccountURLs().count) candidate endpoints")
        #endif
        do {
            let result = try await endpointCoordinator.fetchFirstSuccessful(
                scope: RequestPolicy.scope,
                candidateURLs: resolveAccountURLs()
            ) { endpoint in
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = RequestPolicy.timeout
                request.httpMethod = "GET"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("codex-tools-swift/0.1", forHTTPHeaderField: "User-Agent")
                return request
            }
            let payload = try JSONDecoder().decode(WorkspaceAccountsResponse.self, from: result.data)
            let metadata = payload.items.map {
                WorkspaceMetadata(
                    accountID: $0.id,
                    workspaceName: $0.name,
                    structure: $0.structure
                )
            }
            logger.info(
                category: .workspace,
                event: "fetch_succeeded",
                message: "Workspace metadata fetch completed.",
                metadata: [
                    "endpoint": result.endpoint,
                    "items": String(metadata.count),
                    "duration_ms": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ],
                operationID: operationID
            )
            #if DEBUG
            let preview = metadata.prefix(3).map {
                "\($0.accountID):\($0.workspaceName ?? "<nil>"):\($0.structure ?? "<nil>")"
            }.joined(separator: ", ")
            debugLog(
                "workspace metadata fetch succeeded via \(result.endpoint); items=\(metadata.count); preview=[\(preview)]"
            )
            #endif
            return metadata
        } catch EndpointRequestError.allRequestsFailed(let errors) {
            #if DEBUG
            debugLog("workspace metadata fetch failed across all endpoints: \(errors.joined(separator: " | "))")
            #endif
            let preview = errors.prefix(2).joined(separator: " | ")
            logger.error(
                category: .workspace,
                event: "fetch_failed",
                message: "Workspace metadata fetch failed across all endpoints.",
                metadata: [
                    "failure_preview": preview,
                    "duration_ms": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ],
                operationID: operationID
            )
            if errors.count > 2 {
                throw AppError.network(L10n.tr("error.usage.request_failed_with_more_format", preview, String(errors.count - 2)))
            }
            throw AppError.network(L10n.tr("error.usage.request_failed_format", preview))
        }
    }

    #if DEBUG
    private func debugLog(_ message: String) {
        _ = message
        // print("WorkspaceMetadataService:", message)
    }
    #endif

    private func resolveAccountURLs() -> [String] {
        let baseOrigin = ChatGPTBaseOriginResolver.resolve(configPath: configPath)
        let backendPrefix = "/backend-api"

        var candidates: [String] = []
        if let originWithoutBackend = baseOrigin.removingSuffix(backendPrefix) {
            candidates.append("\(baseOrigin)/accounts")
            candidates.append("\(originWithoutBackend)\(backendPrefix)/accounts")
        } else {
            candidates.append("\(baseOrigin)\(backendPrefix)/accounts")
            candidates.append("\(baseOrigin)/accounts")
        }

        candidates.append("https://chatgpt.com/backend-api/accounts")

        var deduped: [String] = []
        for candidate in candidates where !deduped.contains(candidate) {
            deduped.append(candidate)
        }
        return deduped
    }
}

private struct WorkspaceAccountsResponse: Decodable {
    var items: [WorkspaceAccountItem]
}

private struct WorkspaceAccountItem: Decodable {
    var id: String
    var name: String?
    var structure: String?
}

private extension String {
    func removingSuffix(_ suffix: String) -> String? {
        guard hasSuffix(suffix) else { return nil }
        return String(dropLast(suffix.count))
    }
}
