import Foundation

actor EndpointPreferenceStore {
    static let shared = EndpointPreferenceStore()

    private var preferredEndpointByScope: [String: String] = [:]

    func prioritizedCandidates(scope: String, candidates: [String]) -> [String] {
        guard let preferred = preferredEndpointByScope[scope],
              candidates.contains(preferred) else {
            return candidates
        }

        return [preferred] + candidates.filter { $0 != preferred }
    }

    func recordSuccess(scope: String, endpoint: String) {
        preferredEndpointByScope[scope] = endpoint
    }
}

struct EndpointFetchResult: Sendable {
    let data: Data
    let response: HTTPURLResponse
    let endpoint: String
}

enum EndpointRequestError: Error {
    case allRequestsFailed([String])
}

final class EndpointRequestCoordinator: @unchecked Sendable {
    private let session: URLSession
    private let preferenceStore: EndpointPreferenceStore

    init(
        session: URLSession,
        preferenceStore: EndpointPreferenceStore = .shared
    ) {
        self.session = session
        self.preferenceStore = preferenceStore
    }

    func fetchFirstSuccessful(
        scope: String,
        candidateURLs: [String],
        makeRequest: @escaping @Sendable (URL) -> URLRequest
    ) async throws -> EndpointFetchResult {
        let orderedCandidates = await preferenceStore.prioritizedCandidates(
            scope: scope,
            candidates: candidateURLs
        )
        guard let firstCandidate = orderedCandidates.first else {
            throw EndpointRequestError.allRequestsFailed([])
        }

        var failures: [String] = []

        switch await attemptRequest(
            endpointString: firstCandidate,
            makeRequest: makeRequest
        ) {
        case .success(let result):
            await preferenceStore.recordSuccess(scope: scope, endpoint: result.endpoint)
            return result
        case .failure(let message):
            failures.append(message)
        }

        let remainingCandidates = Array(orderedCandidates.dropFirst())
        guard !remainingCandidates.isEmpty else {
            throw EndpointRequestError.allRequestsFailed(failures)
        }

        let result = await withTaskGroup(
            of: AttemptResult.self,
            returning: EndpointFetchResult?.self
        ) { group in
            for endpointString in remainingCandidates {
                group.addTask { [session] in
                    await Self.attemptRequest(
                        session: session,
                        endpointString: endpointString,
                        makeRequest: makeRequest
                    )
                }
            }

            for await outcome in group {
                switch outcome {
                case .success(let value):
                    group.cancelAll()
                    return value
                case .failure(let message):
                    failures.append(message)
                }
            }

            return nil
        }

        guard let result else {
            throw EndpointRequestError.allRequestsFailed(failures)
        }

        await preferenceStore.recordSuccess(scope: scope, endpoint: result.endpoint)
        return result
    }

    private func attemptRequest(
        endpointString: String,
        makeRequest: @escaping @Sendable (URL) -> URLRequest
    ) async -> AttemptResult {
        await Self.attemptRequest(
            session: session,
            endpointString: endpointString,
            makeRequest: makeRequest
        )
    }

    private static func attemptRequest(
        session: URLSession,
        endpointString: String,
        makeRequest: @escaping @Sendable (URL) -> URLRequest
    ) async -> AttemptResult {
        guard let endpoint = URL(string: endpointString) else {
            return .failure("\(endpointString) -> invalid URL")
        }

        do {
            let (data, response) = try await session.data(for: makeRequest(endpoint))
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("\(endpointString) -> invalid response")
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let snippet = String(body.prefix(140))
                return .failure("\(endpointString) -> \(httpResponse.statusCode): \(snippet)")
            }

            return .success(
                EndpointFetchResult(
                    data: data,
                    response: httpResponse,
                    endpoint: endpointString
                )
            )
        } catch {
            return .failure("\(endpointString) -> \(error.localizedDescription)")
        }
    }

    private enum AttemptResult: Sendable {
        case success(EndpointFetchResult)
        case failure(String)
    }
}
