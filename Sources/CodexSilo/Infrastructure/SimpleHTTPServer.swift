import Foundation
import Network

struct HTTPRequest {
    var method: String
    var target: String
    var path: String
    var queryItems: [URLQueryItem]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    enum Body {
        case data(Data)
        case stream(AsyncThrowingStream<Data, Error>)
    }

    var statusCode: Int
    var headers: [String: String]
    var body: Body

    init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = .data(body)
    }

    init(statusCode: Int, headers: [String: String], stream: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = .stream(stream)
    }

    static func json(statusCode: Int, object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func text(statusCode: Int, text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func stream(
        statusCode: Int,
        headers: [String: String],
        body: AsyncThrowingStream<Data, Error>
    ) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: headers, stream: body)
    }
}

final class SimpleHTTPServer: @unchecked Sendable {
    enum BindScope: Sendable, Equatable {
        case loopbackOnly
        case allInterfaces
    }

    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: RequestHandler

    init(
        port: UInt16,
        bindScope: BindScope = .loopbackOnly,
        handler: @escaping RequestHandler
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AppError.invalidData(L10n.tr("error.http_server.invalid_port_format", String(port)))
        }
        self.listener = try Self.makeListener(port: nwPort, bindScope: bindScope)
        self.queue = DispatchQueue(label: "codex.tools.swift.proxy.listener", qos: .userInitiated)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private static func makeListener(
        port: NWEndpoint.Port,
        bindScope: BindScope
    ) throws -> NWListener {
        switch bindScope {
        case .allInterfaces:
            return try NWListener(using: .tcp, on: port)
        case .loopbackOnly:
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: port
            )
            return try NWListener(using: parameters)
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                // NSLog("SimpleHTTPServer receive error: \(error.localizedDescription)")
                return
            }

            var working = buffer
            if let data, !data.isEmpty {
                working.append(data)
            }

            if Self.isPayloadOversized(buffer: working) {
                let response = HTTPResponse.text(
                    statusCode: 413,
                    text: L10n.tr(
                        "error.http_server.request_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxInboundRequestBytes)
                    )
                )
                self.send(response: response, on: connection)
                return
            }

            if let request = Self.parseRequest(from: working) {
                Task {
                    let response = await self.handler(request)
                    self.send(response: response, on: connection)
                }
                return
            }

            if isComplete {
                let response = HTTPResponse.text(statusCode: 400, text: "Bad Request")
                send(response: response, on: connection)
                return
            }

            self.readRequest(on: connection, buffer: working)
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        Task {
            do {
                try await self.sendAsync(response: response, on: connection)
            } catch {
                connection.cancel()
            }
        }
    }

    private func sendAsync(response: HTTPResponse, on connection: NWConnection) async throws {
        switch response.body {
        case .data(let body):
            let payload = Self.encode(statusCode: response.statusCode, headers: response.headers, body: body)
            try await send(content: payload, on: connection)
            connection.cancel()

        case .stream(let bodyStream):
            let headerPayload = Self.encodeHeaders(
                statusCode: response.statusCode,
                headers: response.headers,
                contentLength: nil,
                chunked: true
            )
            try await send(content: headerPayload, on: connection)

            do {
                for try await chunk in bodyStream {
                    guard !chunk.isEmpty else { continue }
                    try await send(content: Self.encodeChunk(chunk), on: connection)
                }
                try await send(content: Data("0\r\n\r\n".utf8), on: connection)
            } catch {
                connection.cancel()
                throw error
            }

            connection.cancel()
        }
    }

    private func send(content: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: content, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private static func parseRequest(from data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return nil
        }

        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let components = URLComponents(string: target)
        let path = components?.path.isEmpty == false ? (components?.path ?? "/") : (target.split(separator: "?").first.map(String.init) ?? "/")
        let queryItems = components?.queryItems ?? []

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let name = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let expectedEnd = bodyStart + contentLength
        guard data.count >= expectedEnd else {
            return nil
        }

        let body = contentLength == 0 ? Data() : data.subdata(in: bodyStart..<expectedEnd)
        return HTTPRequest(
            method: method,
            target: target,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }

    static func isPayloadOversized(buffer: Data) -> Bool {
        if buffer.count > ProxyRuntimeLimits.maxInboundRequestBytes {
            return true
        }
        if let contentLength = extractContentLength(from: buffer),
           contentLength > ProxyRuntimeLimits.maxInboundRequestBytes {
            return true
        }
        return false
    }

    private static func extractContentLength(from data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        for line in headerText.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let name = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "content-length" else { continue }
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }

        return nil
    }

    private static func encode(statusCode: Int, headers: [String: String], body: Data) -> Data {
        var output = encodeHeaders(
            statusCode: statusCode,
            headers: headers,
            contentLength: body.count,
            chunked: false
        )
        output.append(body)
        return output
    }

    private static func encodeHeaders(
        statusCode: Int,
        headers: [String: String],
        contentLength: Int?,
        chunked: Bool
    ) -> Data {
        precondition(!(chunked && contentLength != nil))

        let reason = reasonPhrase(for: statusCode)
        var headerLines: [String] = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Connection: close"
        ]

        if let contentLength {
            headerLines.append("Content-Length: \(contentLength)")
        } else if chunked {
            headerLines.append("Transfer-Encoding: chunked")
        }

        for (key, value) in headers {
            headerLines.append("\(key): \(value)")
        }
        headerLines.append("\r\n")

        return Data(headerLines.joined(separator: "\r\n").utf8)
    }

    private static func encodeChunk(_ chunk: Data) -> Data {
        var output = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
        output.append(chunk)
        output.append(Data("\r\n".utf8))
        return output
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 413: return "Payload Too Large"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "HTTP"
        }
    }
}
