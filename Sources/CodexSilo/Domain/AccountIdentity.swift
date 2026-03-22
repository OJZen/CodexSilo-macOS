import Foundation

enum AccountIdentity {
    static func accountKey(principalID: String?, email: String?, accountID: String) -> String {
        let resolvedPrincipal = resolvedPrincipalID(
            principalID: principalID,
            email: email,
            fallbackAccountID: accountID
        )
        let resolvedAccountID = normalizedAccountID(accountID) ?? accountID
        return "\(resolvedPrincipal)|\(resolvedAccountID)"
    }

    static func variantKey(
        principalID: String?,
        email: String?,
        accountID: String,
        planType: String?
    ) -> String {
        "\(accountKey(principalID: principalID, email: email, accountID: accountID))|\(normalizePlanTypeKey(planType))"
    }

    static func resolvedPrincipalID(
        principalID: String?,
        email: String?,
        fallbackAccountID: String
    ) -> String {
        normalizePrincipalKey(principalID)
            ?? normalizePrincipalKey(email)
            ?? normalizedAccountID(fallbackAccountID)
            ?? fallbackAccountID
    }

    static func principalID(
        from auth: JSONValue,
        email: String?,
        fallbackAccountID: String
    ) -> String {
        if let explicit = normalizePrincipalKey(
            auth["principal_id"]?.stringValue
            ?? auth["principalId"]?.stringValue
        ) {
            return explicit
        }

        if let idToken = authTokenObject(from: auth)?["id_token"]?.stringValue,
           let claims = try? decodeJWTPayload(idToken),
           let extracted = principalID(fromClaims: claims, email: email) {
            return extracted
        }

        return resolvedPrincipalID(
            principalID: nil,
            email: email,
            fallbackAccountID: fallbackAccountID
        )
    }

    static func principalID(fromClaims claims: JSONValue?, email: String?) -> String? {
        normalizePrincipalKey(email)
            ?? normalizePrincipalKey(
                claims?["https://api.openai.com/auth"]?["chatgpt_user_id"]?.stringValue
                ?? claims?["https://api.openai.com/auth"]?["user_id"]?.stringValue
                ?? claims?["sub"]?.stringValue
            )
    }

    static func normalizePrincipalKey(_ value: String?) -> String? {
        guard let trimmed = normalizedTrimmedString(value) else {
            return nil
        }
        if trimmed.contains("@") {
            return trimmed.lowercased()
        }
        return trimmed
    }

    static func normalizedAccountID(_ value: String?) -> String? {
        normalizedTrimmedString(value)
    }

    static func normalizePlanTypeKey(_ value: String?) -> String {
        let normalized = normalizedTrimmedString(value)?.lowercased()
        return normalized?.isEmpty == false ? normalized! : "unknown"
    }

    static func isCompositeAccountKey(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.contains("|")
    }

    static func selectionIdentifier(accountKey: String?, accountID: String) -> String {
        if let normalizedKey = normalizedTrimmedString(accountKey) {
            return normalizedKey
        }
        return normalizedAccountID(accountID) ?? accountID
    }

    static func variantIdentifier(variantKey: String?) -> String? {
        normalizedTrimmedString(variantKey)
    }

    private static func normalizedTrimmedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func authTokenObject(from auth: JSONValue) -> [String: JSONValue]? {
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

    private static func decodeJWTPayload(_ token: String) throws -> JSONValue {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1 else {
            throw AppError.invalidData(L10n.tr("error.auth.id_token_invalid_format"))
        }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload) else {
            throw AppError.invalidData(L10n.tr("error.auth.decode_id_token_failed"))
        }

        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONValue.from(any: object)
    }
}
