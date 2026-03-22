import Foundation

final class DefaultWorkspaceMetadataService: WorkspaceMetadataService, @unchecked Sendable {
    private enum RequestPolicy {
        static let timeout: TimeInterval = 5
        static let scope = "workspace-metadata"
    }

    private let session: URLSession
    private let configPath: URL
    private let endpointCoordinator: EndpointRequestCoordinator

    init(
        session: URLSession = .shared,
        configPath: URL,
        endpointPreferenceStore: EndpointPreferenceStore = .shared
    ) {
        self.session = session
        self.configPath = configPath
        self.endpointCoordinator = EndpointRequestCoordinator(
            session: session,
            preferenceStore: endpointPreferenceStore
        )
    }

    func fetchWorkspaceMetadata(accessToken: String) async throws -> [WorkspaceMetadata] {
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
