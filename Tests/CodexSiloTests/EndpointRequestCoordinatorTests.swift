import XCTest
@testable import CodexSilo

final class EndpointRequestCoordinatorTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        let resetExpectation = expectation(description: "reset mock url protocol")
        Task {
            await MockURLProtocol.store.reset()
            resetExpectation.fulfill()
        }
        wait(for: [resetExpectation], timeout: 1)
    }

    func testFetchFirstSuccessfulRecordsPreferredEndpointForNextRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let preferenceStore = EndpointPreferenceStore()
        let coordinator = EndpointRequestCoordinator(
            session: session,
            preferenceStore: preferenceStore
        )

        let primary = "https://primary.example.com/value"
        let fallback = "https://fallback.example.com/value"
        let tertiary = "https://tertiary.example.com/value"

        await MockURLProtocol.store.setHandler { request in
            let url = try XCTUnwrap(request.url?.absoluteString)

            switch url {
            case primary:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data("primary failed".utf8)
                )
            case fallback:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"ok":true}"#.utf8)
                )
            default:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }

        _ = try await coordinator.fetchFirstSuccessful(
            scope: "usage",
            candidateURLs: [primary, fallback, tertiary]
        ) { URLRequest(url: $0) }

        await MockURLProtocol.store.resetRequestedURLs()

        let result = try await coordinator.fetchFirstSuccessful(
            scope: "usage",
            candidateURLs: [primary, fallback, tertiary]
        ) { URLRequest(url: $0) }

        let requestedURLs = await MockURLProtocol.store.requestedURLs()
        XCTAssertEqual(result.endpoint, fallback)
        XCTAssertEqual(requestedURLs, [fallback])
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = MockURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            do {
                await Self.store.record(request: request)
                guard let handler = await Self.store.handler() else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }

                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private actor MockURLProtocolStore {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private var currentHandler: Handler?
    private var requestedURLValues: [String] = []

    func setHandler(_ handler: @escaping Handler) {
        currentHandler = handler
    }

    func handler() -> Handler? {
        currentHandler
    }

    func record(request: URLRequest) {
        if let url = request.url?.absoluteString {
            requestedURLValues.append(url)
        }
    }

    func requestedURLs() -> [String] {
        requestedURLValues
    }

    func resetRequestedURLs() {
        requestedURLValues = []
    }

    func reset() {
        currentHandler = nil
        requestedURLValues = []
    }
}
