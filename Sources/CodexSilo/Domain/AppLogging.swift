import Foundation

enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case warning
    case error

    var label: String {
        rawValue.uppercased()
    }
}

enum LogCategory: String, CaseIterable, Codable, Sendable {
    case app
    case store
    case auth
    case accounts
    case usage
    case workspace
    case proxy
    case settings
    case tray
    case update
}

struct AppLogEntry: Equatable, Identifiable, Sendable {
    var id: String
    var timestamp: Date
    var level: LogLevel
    var scope: String
    var message: String
    var metadataSummary: String?
    var rawLine: String

    static func parse(line: String, id: String) -> AppLogEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard components.count >= 4 else { return nil }

        let timestampText = String(components[0])
        let levelToken = String(components[1])
        let scopeToken = String(components[2])
        let remainder = String(components[3])

        guard levelToken.hasPrefix("["),
              levelToken.hasSuffix("]"),
              scopeToken.hasPrefix("["),
              scopeToken.hasSuffix("]"),
              let level = LogLevel(rawValue: String(levelToken.dropFirst().dropLast()).lowercased()),
              let timestamp = LogTimestampFormatter.date(from: timestampText) else {
            return nil
        }

        let bodyParts = remainder.components(separatedBy: " | ")
        let message = bodyParts.first ?? ""
        let metadataSummary = bodyParts.count > 1 ? bodyParts.dropFirst().joined(separator: " | ") : nil

        return AppLogEntry(
            id: id,
            timestamp: timestamp,
            level: level,
            scope: String(scopeToken.dropFirst().dropLast()),
            message: message,
            metadataSummary: metadataSummary,
            rawLine: trimmed
        )
    }
}

protocol AppLogger: Sendable {
    func log(
        _ level: LogLevel,
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String],
        operationID: String?
    )

    func loadEntries(limit: Int) async throws -> [AppLogEntry]
    func loadCombinedText(limit: Int) async throws -> String
    func clearLogs() async throws
    func logsDirectoryURL() -> URL
}

extension AppLogger {
    func debug(
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String] = [:],
        operationID: String? = nil
    ) {
        log(.debug, category: category, event: event, message: message, metadata: metadata, operationID: operationID)
    }

    func info(
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String] = [:],
        operationID: String? = nil
    ) {
        log(.info, category: category, event: event, message: message, metadata: metadata, operationID: operationID)
    }

    func warning(
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String] = [:],
        operationID: String? = nil
    ) {
        log(.warning, category: category, event: event, message: message, metadata: metadata, operationID: operationID)
    }

    func error(
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String] = [:],
        operationID: String? = nil
    ) {
        log(.error, category: category, event: event, message: message, metadata: metadata, operationID: operationID)
    }
}

enum LogRedactor {
    private static let secretKeyFragments = [
        "authorization",
        "token",
        "password",
        "secret",
        "authjson",
        "auth_json",
        "apikey",
        "api_key"
    ]

    static func sanitizeMessage(_ value: String, maxLength: Int = 240) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var sanitized = trimmed
        sanitized = redactSensitiveAssignments(in: sanitized)
        sanitized = replacingMatches(
            pattern: #"Bearer\s+[A-Za-z0-9\._\-]+"#,
            in: sanitized,
            transform: { _ in "Bearer <redacted>" }
        )
        sanitized = replacingMatches(
            pattern: #"sk-[A-Za-z0-9]+"#,
            in: sanitized,
            transform: { _ in "sk-<redacted>" }
        )
        sanitized = replacingMatches(
            pattern: #"[A-Za-z0-9_\-]+=eyJ[A-Za-z0-9_\-\.]+"#,
            in: sanitized,
            transform: { _ in "<redacted-jwt>" }
        )
        sanitized = replacingMatches(
            pattern: #"eyJ[A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+){1,2}"#,
            in: sanitized,
            transform: { _ in "<redacted-jwt>" }
        )
        sanitized = replacingMatches(
            pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            in: sanitized,
            options: [.caseInsensitive]
        ) { match in
            maskEmail(match)
        }

        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength)) + "..."
        }
        return sanitized
    }

    static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for key in metadata.keys.sorted() {
            guard let value = metadata[key] else { continue }
            sanitized[key] = sanitizeMetadataValue(key: key, value: value)
        }
        return sanitized
    }

    static func maskEmail(_ value: String) -> String {
        let parts = value.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else {
            return maskIdentifier(value)
        }

        let localPart = String(parts[0])
        let domain = String(parts[1])
        let visiblePrefix = String(localPart.prefix(min(2, localPart.count)))
        return "\(visiblePrefix)***@\(domain)"
    }

    static func maskIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > 6 else {
            return "\(trimmed.prefix(1))***\(trimmed.suffix(1))"
        }
        return "\(trimmed.prefix(4))***\(trimmed.suffix(4))"
    }

    static func preview(_ value: String, maxLength: Int = 120) -> String {
        sanitizeMessage(value, maxLength: maxLength)
    }

    private static func sanitizeMetadataValue(key: String, value: String) -> String {
        let normalizedKey = key.lowercased()

        if secretKeyFragments.contains(where: { normalizedKey.contains($0) }) {
            return "<redacted>"
        }

        if normalizedKey.contains("url"),
           let sanitizedURL = sanitizeURL(value) {
            return sanitizedURL
        }

        if normalizedKey.contains("email") {
            return maskEmail(value)
        }

        if normalizedKey.contains("account")
            || normalizedKey.contains("workspace")
            || normalizedKey.hasSuffix("id")
            || normalizedKey.contains("_id")
            || normalizedKey.contains("selection") {
            return maskIdentifier(value)
        }

        return preview(value)
    }

    private static func sanitizeURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        return components.string ?? preview(value)
    }

    private static func redactSensitiveAssignments(in value: String) -> String {
        var sanitized = value
        let patterns = [
            #"(\"?(?:access_token|refresh_token|id_token|subject_token|api_key|x-api-key|x_api_key|accessToken|refreshToken|idToken|subjectToken|apiKey|authorization|password)\"?\s*:\s*\")([^\"]+)(\")"#,
            #"(\"?(?:access_token|refresh_token|id_token|subject_token|api_key|x-api-key|x_api_key|accessToken|refreshToken|idToken|subjectToken|apiKey|authorization|password)\"?\s*[:=]\s*)([^\s,&}]+)"#
        ]

        for pattern in patterns {
            sanitized = replacingMatches(
                pattern: pattern,
                in: sanitized,
                options: [.caseInsensitive]
            ) { match in
                redactAssignmentMatch(match)
            }
        }

        return sanitized
    }

    private static func redactAssignmentMatch(_ match: String) -> String {
        guard let separatorIndex = match.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
            return "<redacted>"
        }

        let prefixEnd = match.index(after: separatorIndex)
        var prefix = String(match[..<prefixEnd])
        let remainder = match[prefixEnd...]
        let whitespacePrefix = remainder.prefix(while: \.isWhitespace)
        prefix += String(whitespacePrefix)

        var suffixStart = remainder.index(remainder.startIndex, offsetBy: whitespacePrefix.count)
        if suffixStart < remainder.endIndex,
           remainder[suffixStart] == "\"" || remainder[suffixStart] == "'" {
            prefix.append(remainder[suffixStart])
            suffixStart = remainder.index(after: suffixStart)
        }

        var suffix = ""
        if suffixStart < remainder.endIndex,
           let last = remainder.last,
           last == "\"" || last == "'" {
            suffix = String(last)
        }

        return "\(prefix)<redacted>\(suffix)"
    }

    private static func replacingMatches(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }

        var result = value
        let matches = expression.matches(
            in: value,
            options: [],
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        )

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let replacement = transform(String(result[range]))
            result.replaceSubrange(range, with: replacement)
        }

        return result
    }
}

final class NoopAppLogger: AppLogger, @unchecked Sendable {
    static let shared = NoopAppLogger()

    private init() {}

    func log(
        _ level: LogLevel,
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String],
        operationID: String?
    ) {
        _ = level
        _ = category
        _ = event
        _ = message
        _ = metadata
        _ = operationID
    }

    func loadEntries(limit: Int) async throws -> [AppLogEntry] {
        _ = limit
        return []
    }

    func loadCombinedText(limit: Int) async throws -> String {
        _ = limit
        return ""
    }

    func clearLogs() async throws {
    }

    func logsDirectoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}

enum LogTimestampFormatter {
    private static let shared = LockedISO8601LogFormatter()

    static func string(from date: Date) -> String {
        shared.string(from: date)
    }

    static func date(from value: String) -> Date? {
        shared.date(from: value)
    }
}

private final class LockedISO8601LogFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: value)
    }
}
