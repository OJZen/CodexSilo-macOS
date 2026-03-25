import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class AuthFileRepository: AuthRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager

    init(paths: FileSystemPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func readCurrentAuth() throws -> JSONValue {
        guard fileManager.fileExists(atPath: paths.codexAuthPath.path) else {
            throw AppError.fileNotFound(L10n.tr("error.auth.auth_file_not_found"))
        }
        return try readJSONValue(from: paths.codexAuthPath)
    }

    func readCurrentAuthOptional() throws -> JSONValue? {
        guard fileManager.fileExists(atPath: paths.codexAuthPath.path) else {
            return nil
        }
        return try readJSONValue(from: paths.codexAuthPath)
    }

    func readAuth(from url: URL) throws -> JSONValue {
        try readJSONValue(from: url)
    }

    func writeCurrentAuth(_ auth: JSONValue) throws {
        let normalizedAuth = try CodexCurrentAuthNormalizer.normalize(
            auth,
            fallbackLastRefresh: Self.makeLastRefreshTimestamp
        )
        let parentDirectory = paths.codexAuthPath.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let object = normalizedAuth.toAny()
        guard JSONSerialization.isValidJSONObject(object) else {
            throw AppError.invalidData(L10n.tr("error.auth.auth_json_invalid_structure"))
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: paths.codexAuthPath, options: .atomic)
        #if canImport(Darwin)
        _ = chmod(paths.codexAuthPath.path, S_IRUSR | S_IWUSR)
        #endif
    }

    func removeCurrentAuth() throws {
        guard fileManager.fileExists(atPath: paths.codexAuthPath.path) else {
            return
        }
        try fileManager.removeItem(at: paths.codexAuthPath)
    }

    func makeChatGPTAuth(from tokens: ChatGPTOAuthTokens) throws -> JSONValue {
        let claims = try decodeJWTPayload(tokens.idToken)
        let accountID = claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue

        var tokenObject: [String: JSONValue] = [
            "access_token": .string(tokens.accessToken),
            "refresh_token": .string(tokens.refreshToken),
            "id_token": .string(tokens.idToken)
        ]

        if let accountID, !accountID.isEmpty {
            tokenObject["account_id"] = .string(accountID)
        }

        var root: [String: JSONValue] = [
            "auth_mode": .string("chatgpt"),
            "last_refresh": .string(Self.makeLastRefreshTimestamp()),
            "tokens": .object(tokenObject)
        ]

        if let apiKey = tokens.apiKey, !apiKey.isEmpty {
            root["OPENAI_API_KEY"] = .string(apiKey)
        }

        return .object(root)
    }

    func extractAuth(from auth: JSONValue) throws -> ExtractedAuth {
        let mode = auth["auth_mode"]?.stringValue?.lowercased() ?? ""
        guard let tokens = authTokenObject(from: auth) else {
            if !mode.isEmpty && mode != "chatgpt" && mode != "chatgpt_auth_tokens" {
                throw AppError.unauthorized(L10n.tr("error.auth.not_chatgpt_mode"))
            }
            throw AppError.unauthorized(L10n.tr("error.auth.no_chatgpt_token"))
        }

        guard let accessToken = tokens["access_token"]?.stringValue else {
            throw AppError.invalidData(L10n.tr("error.auth.missing_access_token"))
        }
        guard let idToken = tokens["id_token"]?.stringValue else {
            throw AppError.invalidData(L10n.tr("error.auth.missing_id_token"))
        }

        var accountID = tokens["account_id"]?.stringValue
        var email: String?
        var planType: String?
        var teamName: String?
        var principalID: String?

        if let claims = try? decodeJWTPayload(idToken) {
            email = claims["email"]?.stringValue
            if accountID == nil {
                accountID = claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue
            }
            planType = claims["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.stringValue
            principalID = AccountIdentity.principalID(fromClaims: claims, email: email)
            teamName = extractTeamName(from: auth, claims: claims, accountIDHint: accountID)
        } else {
            teamName = extractTeamName(from: auth, claims: nil, accountIDHint: accountID)
        }

        guard let finalAccountID = accountID, !finalAccountID.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.auth.missing_chatgpt_account_id"))
        }

        return ExtractedAuth(
            principalID: principalID ?? AccountIdentity.principalID(
                from: auth,
                email: email,
                fallbackAccountID: finalAccountID
            ),
            accountID: finalAccountID,
            accessToken: accessToken,
            email: email,
            planType: planType,
            teamName: teamName
        )
    }

    func currentAuthAccountID() -> String? {
        guard let auth = try? readCurrentAuth() else { return nil }
        return try? extractAuth(from: auth).accountID
    }

    private func readJSONValue(from path: URL) throws -> JSONValue {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw AppError.io(L10n.tr("error.auth.read_auth_json_failed_format", error.localizedDescription))
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.invalidData(L10n.tr("error.auth.auth_json_invalid"))
        }

        return try JSONValue.from(any: object)
    }

    private func authTokenObject(from auth: JSONValue) -> [String: JSONValue]? {
        if let tokens = auth["tokens"]?.objectValue {
            return tokens
        }

        if let object = auth.objectValue,
           object["access_token"]?.stringValue != nil,
           object["id_token"]?.stringValue != nil {
            return object
        }

        return nil
    }

    private func decodeJWTPayload(_ token: String) throws -> JSONValue {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1 else {
            throw AppError.invalidData(L10n.tr("error.auth.id_token_invalid_format"))
        }

        let payload = String(segments[1])
        let data = try decodeBase64URL(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONValue.from(any: object)
    }

    private func decodeBase64URL(_ value: String) throws -> Data {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw AppError.invalidData(L10n.tr("error.auth.decode_id_token_failed"))
        }
        return data
    }

    private func extractTeamName(from auth: JSONValue, claims: JSONValue?, accountIDHint: String?) -> String? {
        let preferredIDs = preferredWorkspaceIDs(from: auth, claims: claims, accountIDHint: accountIDHint)

        if let fromContainers = extractNameFromContainers(
            in: claims,
            preferredIDs: preferredIDs,
            allowPersonalFallback: false
        ) ?? extractNameFromContainers(
            in: auth,
            preferredIDs: preferredIDs,
            allowPersonalFallback: false
        ) {
            return fromContainers
        }

        let claimPaths: [[String]] = [
            ["https://api.openai.com/auth", "chatgpt_team_name"],
            ["https://api.openai.com/auth", "chatgpt_workspace_slug"],
            ["https://api.openai.com/auth", "workspace_slug"],
            ["https://api.openai.com/auth", "team_slug"],
            ["https://api.openai.com/auth", "organization_slug"],
            ["https://api.openai.com/auth", "chatgpt_org_name"],
            ["https://api.openai.com/auth", "organization_name"],
            ["https://api.openai.com/auth", "org_name"],
            ["https://api.openai.com/auth", "team_name"],
            ["organization", "name"],
            ["org", "name"],
            ["team", "name"],
            ["workspace", "name"]
        ]

        for path in claimPaths {
            if let value = normalizedTeamName(string(atPath: path, in: claims), allowPersonal: false) {
                return value
            }
        }

        let authPaths: [[String]] = [
            ["tokens", "workspace_slug"],
            ["tokens", "team_slug"],
            ["tokens", "organization_slug"],
            ["organization", "name"],
            ["org", "name"],
            ["team", "name"],
            ["workspace", "name"],
            ["tokens", "organization_name"],
            ["tokens", "org_name"],
            ["tokens", "team_name"]
        ]

        for path in authPaths {
            if let value = normalizedTeamName(string(atPath: path, in: auth), allowPersonal: false) {
                return value
            }
        }

        let keyCandidates: Set<String> = [
            "teamname",
            "organizationname",
            "orgname",
            "workspacename",
            "tenantname",
            "displayname"
        ]

        return findFirstString(in: claims, candidateKeys: keyCandidates, allowPersonal: false)
            ?? findFirstString(in: auth, candidateKeys: keyCandidates, allowPersonal: false)
    }

    private static func makeLastRefreshTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func string(atPath path: [String], in root: JSONValue?) -> String? {
        guard let root else { return nil }
        var current = root
        for key in path {
            guard let next = current[key] else { return nil }
            current = next
        }
        return current.stringValue
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedTeamName(_ value: String?, allowPersonal: Bool) -> String? {
        guard let normalized = normalizedString(value) else { return nil }
        if !allowPersonal, isPersonalName(normalized) {
            return nil
        }
        return normalized
    }

    private func isPersonalName(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        return normalized == "personal"
            || normalized == "personalworkspace"
            || normalized == "myworkspace"
            || normalized == "个人"
            || normalized == "个人空间"
    }

    private func normalizedKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func findFirstString(in value: JSONValue?, candidateKeys: Set<String>, allowPersonal: Bool) -> String? {
        guard let value else { return nil }
        switch value {
        case .object(let object):
            for (key, item) in object {
                if candidateKeys.contains(normalizedKey(key)),
                   let match = normalizedTeamName(item.stringValue, allowPersonal: allowPersonal) {
                    return match
                }
            }
            for item in object.values {
                if let nested = findFirstString(in: item, candidateKeys: candidateKeys, allowPersonal: allowPersonal) {
                    return nested
                }
            }
            return nil
        case .array(let items):
            for item in items {
                if let nested = findFirstString(in: item, candidateKeys: candidateKeys, allowPersonal: allowPersonal) {
                    return nested
                }
            }
            return nil
        default:
            return nil
        }
    }

    private struct WorkspaceCandidate {
        let id: String?
        let displayName: String?
        let isDefault: Bool
        let isCurrent: Bool
        let isActive: Bool
    }

    private func extractNameFromContainers(
        in root: JSONValue?,
        preferredIDs: Set<String>,
        allowPersonalFallback: Bool
    ) -> String? {
        guard let root else { return nil }
        let candidates = collectWorkspaceCandidates(in: root)
        guard !candidates.isEmpty else { return nil }

        if let matchedByID = candidates.first(where: {
            guard let id = $0.id?.lowercased() else { return false }
            return preferredIDs.contains(id)
        }), let display = normalizedTeamName(matchedByID.displayName, allowPersonal: allowPersonalFallback) {
            return display
        }

        let prioritized = candidates
            .sorted { lhs, rhs in
                score(candidate: lhs, preferredIDs: preferredIDs) > score(candidate: rhs, preferredIDs: preferredIDs)
            }

        for candidate in prioritized {
            if let display = normalizedTeamName(candidate.displayName, allowPersonal: false) {
                return display
            }
        }

        guard allowPersonalFallback else { return nil }
        return prioritized.compactMap { normalizedTeamName($0.displayName, allowPersonal: true) }.first
    }

    private func score(candidate: WorkspaceCandidate, preferredIDs: Set<String>) -> Int {
        var total = 0
        if let id = candidate.id?.lowercased(), preferredIDs.contains(id) {
            total += 100
        }
        if candidate.isCurrent { total += 30 }
        if candidate.isActive { total += 20 }
        if candidate.isDefault { total += 5 }
        if let display = candidate.displayName, !isPersonalName(display) { total += 10 }
        return total
    }

    private func collectWorkspaceCandidates(in value: JSONValue?) -> [WorkspaceCandidate] {
        guard let value else { return [] }
        switch value {
        case .object(let object):
            let containerKeys = ["organizations", "orgs", "teams", "workspaces", "groups"]
            var candidates: [WorkspaceCandidate] = []

            for key in containerKeys {
                guard let items = object[key]?.arrayValue else { continue }
                for item in items {
                    guard case .object(let obj) = item else { continue }
                    candidates.append(
                        WorkspaceCandidate(
                            id: extractString(from: obj, keys: ["id", "organization_id", "org_id", "workspace_id", "group_id"]),
                            displayName: extractString(
                                from: obj,
                                keys: ["slug", "workspace_slug", "team_slug", "organization_slug", "name", "display_name", "displayName", "title", "label"]
                            ),
                            isDefault: extractBool(from: obj, keys: ["is_default", "default"]),
                            isCurrent: extractBool(from: obj, keys: ["is_current", "current", "selected"]),
                            isActive: extractBool(from: obj, keys: ["is_active", "active"])
                        )
                    )
                }
            }

            for nested in object.values {
                candidates.append(contentsOf: collectWorkspaceCandidates(in: nested))
            }
            return candidates
        case .array(let items):
            return items.flatMap { collectWorkspaceCandidates(in: $0) }
        default:
            return []
        }
    }

    private func extractString(from object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = normalizedString(object[key]?.stringValue) {
                return value
            }
        }
        return nil
    }

    private func extractBool(from object: [String: JSONValue], keys: [String]) -> Bool {
        keys.contains { key in object[key]?.boolValue == true }
    }

    private func preferredWorkspaceIDs(from auth: JSONValue, claims: JSONValue?, accountIDHint: String?) -> Set<String> {
        let hintPaths: [[String]] = [
            ["https://api.openai.com/auth", "chatgpt_org_id"],
            ["https://api.openai.com/auth", "chatgpt_organization_id"],
            ["https://api.openai.com/auth", "organization_id"],
            ["https://api.openai.com/auth", "org_id"],
            ["https://api.openai.com/auth", "active_organization_id"],
            ["https://api.openai.com/auth", "active_org_id"],
            ["https://api.openai.com/auth", "current_organization_id"],
            ["https://api.openai.com/auth", "default_organization_id"],
            ["tokens", "organization_id"],
            ["tokens", "org_id"],
            ["tokens", "active_organization_id"],
            ["tokens", "active_org_id"]
        ]

        var ids: Set<String> = []
        if let accountIDHint = normalizedString(accountIDHint)?.lowercased() {
            ids.insert(accountIDHint)
        }

        for path in hintPaths {
            if let value = normalizedString(string(atPath: path, in: claims))?.lowercased() {
                ids.insert(value)
            }
            if let value = normalizedString(string(atPath: path, in: auth))?.lowercased() {
                ids.insert(value)
            }
        }
        return ids
    }

}

final class LocalFileMonitorService: LocalFileMonitorServiceProtocol, @unchecked Sendable {
    private struct AuthFileFingerprint: Equatable {
        let fileID: UInt64?
        let size: UInt64
        let modificationDate: Date

        static let missing = AuthFileFingerprint(
            fileID: nil,
            size: 0,
            modificationDate: .distantPast
        )
    }

    private let fileManager: FileManager
    private let monitoredFilePath: URL
    private let monitoredDirectoryPath: URL
    private let eventQueue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var directoryDescriptor: CInt = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var lastFingerprint = AuthFileFingerprint.missing
    private var onChange: (@Sendable () -> Void)?

    init(
        monitoredFilePath: URL,
        fileManager: FileManager = .default,
        eventQueue: DispatchQueue = DispatchQueue(label: "codexsilo.auth-file-monitor"),
        callbackQueue: DispatchQueue = .main
    ) {
        self.fileManager = fileManager
        self.monitoredFilePath = monitoredFilePath
        self.monitoredDirectoryPath = monitoredFilePath.deletingLastPathComponent()
        self.eventQueue = eventQueue
        self.callbackQueue = callbackQueue
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard directorySource == nil else { return }

        try? fileManager.createDirectory(at: monitoredDirectoryPath, withIntermediateDirectories: true)
        lastFingerprint = fileFingerprint(at: monitoredFilePath)

        #if canImport(Darwin)
        let descriptor = open(monitoredDirectoryPath.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        directoryDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: eventQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.directoryDescriptor >= 0 {
                close(self.directoryDescriptor)
                self.directoryDescriptor = -1
            }
        }
        directorySource = source
        source.resume()
        #endif
    }

    func stop() {
        onChange = nil
        directorySource?.cancel()
        directorySource = nil
        #if canImport(Darwin)
        if directoryDescriptor >= 0 {
            close(directoryDescriptor)
            directoryDescriptor = -1
        }
        #endif
    }

    deinit {
        stop()
    }

    private func handleDirectoryEvent() {
        let latestFingerprint = fileFingerprint(at: monitoredFilePath)
        guard latestFingerprint != lastFingerprint else { return }

        lastFingerprint = latestFingerprint
        guard let onChange else { return }
        callbackQueue.async {
            onChange()
        }
    }

    private func fileFingerprint(at path: URL) -> AuthFileFingerprint {
        guard fileManager.fileExists(atPath: path.path) else {
            return .missing
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path) else {
            return .missing
        }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        return AuthFileFingerprint(
            fileID: fileID,
            size: size,
            modificationDate: modificationDate
        )
    }
}

private enum CodexCurrentAuthNormalizer {
    private static let topLevelTokenKeys = [
        "access_token",
        "refresh_token",
        "id_token",
        "account_id"
    ]

    static func normalize(
        _ auth: JSONValue,
        fallbackLastRefresh: () -> String
    ) throws -> JSONValue {
        guard var root = auth.objectValue else {
            throw AppError.invalidData(L10n.tr("error.auth.auth_json_invalid_structure"))
        }

        let tokens = try normalizedTokens(from: root)
        root["auth_mode"] = .string(normalizedAuthMode(root["auth_mode"]))
        root["tokens"] = .object(tokens)

        for key in topLevelTokenKeys {
            root.removeValue(forKey: key)
        }

        root["last_refresh"] = .string(
            normalizedLastRefresh(root["last_refresh"], fallback: fallbackLastRefresh)
        )
        return .object(root)
    }

    private static func normalizedTokens(from root: [String: JSONValue]) throws -> [String: JSONValue] {
        var tokens = root["tokens"]?.objectValue ?? [:]

        if tokens.isEmpty {
            for key in topLevelTokenKeys {
                if let value = root[key] {
                    tokens[key] = value
                }
            }
        } else {
            for key in topLevelTokenKeys where tokens[key] == nil {
                if let value = root[key] {
                    tokens[key] = value
                }
            }
        }

        guard tokens["access_token"]?.stringValue != nil else {
            throw AppError.invalidData(L10n.tr("error.auth.missing_access_token"))
        }
        guard tokens["id_token"]?.stringValue != nil else {
            throw AppError.invalidData(L10n.tr("error.auth.missing_id_token"))
        }
        return tokens
    }

    private static func normalizedAuthMode(_ value: JSONValue?) -> String {
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "chatgpt" : trimmed
    }

    private static func normalizedLastRefresh(_ value: JSONValue?, fallback: () -> String) -> String {
        guard let rawValue = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return fallback()
        }

        if let parsed = parseTimestamp(rawValue) {
            return makeTimestamp(from: parsed)
        }
        return fallback()
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        for candidate in timestampCandidates(for: value) {
            if let parsed = parseRFC3339(candidate) {
                return parsed
            }
        }
        return nil
    }

    private static func timestampCandidates(for value: String) -> [String] {
        var candidates = [value]
        if !hasExplicitTimezone(value) {
            candidates.append("\(value)Z")
        }
        return candidates
    }

    private static func hasExplicitTimezone(_ value: String) -> Bool {
        value.range(
            of: #"(Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) != nil
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractionalFormatter.date(from: value) {
            return parsed
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func makeTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
