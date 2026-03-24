import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case accounts
    case proxy
    case settings

    var id: String { rawValue }
}

struct AccountsStore: Codable, Equatable {
    var version: Int = 1
    var accounts: [StoredAccount] = []
    var currentSelection: CurrentAccountSelection?
    var accountsOverviewCollapsed: Bool = false
    var settings: AppSettings = .defaultValue

    enum CodingKeys: String, CodingKey {
        case version
        case accounts
        case currentSelection
        case accountsOverviewCollapsed
        case settings
    }

    init(
        version: Int = 1,
        accounts: [StoredAccount] = [],
        currentSelection: CurrentAccountSelection? = nil,
        accountsOverviewCollapsed: Bool = false,
        settings: AppSettings = .defaultValue
    ) {
        self.version = version
        self.accounts = accounts
        self.currentSelection = currentSelection
        self.accountsOverviewCollapsed = accountsOverviewCollapsed
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try container.decodeIfPresent([StoredAccount].self, forKey: .accounts) ?? []
        currentSelection = try container.decodeIfPresent(CurrentAccountSelection.self, forKey: .currentSelection)
        accountsOverviewCollapsed = try container.decodeIfPresent(Bool.self, forKey: .accountsOverviewCollapsed) ?? false
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? .defaultValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(accounts, forKey: .accounts)
        try container.encodeIfPresent(currentSelection, forKey: .currentSelection)
        try container.encode(accountsOverviewCollapsed, forKey: .accountsOverviewCollapsed)
        try container.encode(settings, forKey: .settings)
    }
}

struct CurrentAccountSelection: Codable, Equatable {
    var accountID: String
    var accountKey: String?
    var variantKey: String?
    var selectedAt: Int64
    var sourceDeviceID: String

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case accountKey
        case variantKey
        case selectedAt
        case sourceDeviceID
    }

    init(
        accountID: String,
        accountKey: String? = nil,
        variantKey: String? = nil,
        selectedAt: Int64,
        sourceDeviceID: String
    ) {
        self.accountID = accountID
        self.accountKey = accountKey
        self.variantKey = variantKey
        self.selectedAt = selectedAt
        self.sourceDeviceID = sourceDeviceID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
        variantKey = try container.decodeIfPresent(String.self, forKey: .variantKey)
        selectedAt = try container.decode(Int64.self, forKey: .selectedAt)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encodeIfPresent(accountKey, forKey: .accountKey)
        try container.encodeIfPresent(variantKey, forKey: .variantKey)
        try container.encode(selectedAt, forKey: .selectedAt)
        try container.encode(sourceDeviceID, forKey: .sourceDeviceID)
    }

    var resolvedAccountKey: String {
        AccountIdentity.selectionIdentifier(accountKey: accountKey, accountID: accountID)
    }

    var resolvedVariantKey: String? {
        AccountIdentity.variantIdentifier(variantKey: variantKey)
    }
}

struct CurrentAccountSelectionPullResult: Equatable, Sendable {
    var didUpdateSelection: Bool
    var changedCurrentAccount: Bool
    var accountID: String?
    var accountKey: String?
    var variantKey: String?

    static let noChange = CurrentAccountSelectionPullResult(
        didUpdateSelection: false,
        changedCurrentAccount: false,
        accountID: nil,
        accountKey: nil,
        variantKey: nil
    )
}

struct AccountsCloudSyncPullResult: Equatable, Sendable {
    var didUpdateAccounts: Bool
    var remoteSyncedAt: Int64?

    static let noChange = AccountsCloudSyncPullResult(
        didUpdateAccounts: false,
        remoteSyncedAt: nil
    )
}

struct StoredAccount: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var principalID: String? = nil
    var email: String?
    var accountID: String
    var planType: String?
    var teamName: String?
    var teamAlias: String?
    var authJSON: JSONValue
    var addedAt: Int64
    var updatedAt: Int64
    var usage: UsageSnapshot?
    var usageError: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case principalID = "principalId"
        case email
        case accountID = "accountId"
        case planType
        case teamName
        case teamAlias
        case authJSON = "authJson"
        case addedAt
        case updatedAt
        case usage
        case usageError
    }

    fileprivate var resolvedIdentity: StoredAccountIdentity {
        StoredAccountIdentity(account: self)
    }

    var accountKey: String { resolvedIdentity.accountKey }

    var resolvedPlanType: String? {
        usage?.planType
            ?? planType
            ?? ((try? ExtractedAuth.fromStoredAuth(authJSON))?.planType)
    }

    var variantKey: String { resolvedIdentity.variantKey }

    func matchesSelectionIdentifier(_ identifier: String?) -> Bool {
        resolvedIdentity.matchesSelection(accountKey: identifier, variantKey: nil)
    }

    func matchesSelection(
        accountKey: String?,
        variantKey: String?
    ) -> Bool {
        resolvedIdentity.matchesSelection(accountKey: accountKey, variantKey: variantKey)
    }
}

private struct StoredAccountIdentity {
    let accountKey: String
    let variantKey: String
    private let normalizedAccountID: String

    init(account: StoredAccount) {
        let resolvedPrincipalID = account.principalID ?? AccountIdentity.principalID(
            from: account.authJSON,
            email: account.email,
            fallbackAccountID: account.accountID
        )
        let accountKey = AccountIdentity.accountKey(
            principalID: resolvedPrincipalID,
            email: account.email,
            accountID: account.accountID
        )
        let resolvedPlanType = account.usage?.planType
            ?? account.planType
            ?? ((try? ExtractedAuth.fromStoredAuth(account.authJSON))?.planType)

        self.accountKey = accountKey
        self.variantKey = "\(accountKey)|\(AccountIdentity.normalizePlanTypeKey(resolvedPlanType))"
        normalizedAccountID = AccountIdentity.normalizedAccountID(account.accountID) ?? account.accountID
    }

    func matchesSelection(accountKey: String?, variantKey: String?) -> Bool {
        if let variantKey,
           let normalizedVariantKey = AccountIdentity.variantIdentifier(variantKey: variantKey) {
            return normalizedVariantKey == self.variantKey
        }
        guard let accountKey,
              let normalizedIdentifier = AccountIdentity.normalizedAccountID(accountKey) else {
            return false
        }
        return normalizedIdentifier == self.accountKey || normalizedIdentifier == normalizedAccountID
    }
}

struct AccountSummary: Equatable, Identifiable {
    var id: String
    var label: String
    var accountKey: String = ""
    var variantKey: String = ""
    var email: String?
    var accountID: String
    var planType: String?
    var teamName: String?
    var teamAlias: String?
    var addedAt: Int64
    var updatedAt: Int64
    var usage: UsageSnapshot?
    var usageError: String?
    var isCurrent: Bool

    var normalizedPlanLabel: String {
        let normalized = (planType ?? usage?.planType ?? "team")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "free":
            return "FREE"
        case "plus":
            return "PLUS"
        case "pro":
            return "PRO"
        case "enterprise":
            return "ENTERPRISE"
        case "business":
            return "BUSINESS"
        default:
            return "TEAM"
        }
    }

    var displayTeamName: String? {
        if let alias = teamAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        if let teamName = teamName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !teamName.isEmpty {
            return teamName
        }
        return nil
    }

    var shouldDisplayWorkspaceTag: Bool {
        switch normalizedPlanLabel {
        case "TEAM", "BUSINESS", "ENTERPRISE":
            return displayTeamName != nil
        default:
            return false
        }
    }
}

struct AccountConfigurationDraft: Equatable, Identifiable {
    var id: String = UUID().uuidString
    var storedAccountID: String?
    var label: String = ""
    var teamAlias: String = ""
    var setAsCurrent: Bool = false
    var authJSONString: String = ""

    var isEditingExistingAccount: Bool {
        storedAccountID != nil
    }

    var navigationTitle: String {
        isEditingExistingAccount ? "编辑账户配置" : "自定义导入账户"
    }

    static func customImportTemplate() -> AccountConfigurationDraft {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let template = JSONValue.object([
            "OPENAI_API_KEY": .null,
            "auth_mode": .string("chatgpt"),
            "last_refresh": .string(formatter.string(from: Date())),
            "tokens": .object([
                "access_token": .string(""),
                "account_id": .string(""),
                "id_token": .string(""),
                "refresh_token": .string("")
            ])
        ])

        return AccountConfigurationDraft(
            authJSONString: (try? template.prettyPrintedJSONString()) ?? """
            {
              "OPENAI_API_KEY": null,
              "auth_mode": "chatgpt",
              "last_refresh": "",
              "tokens": {
                "access_token": "",
                "account_id": "",
                "id_token": "",
                "refresh_token": ""
              }
            }
            """
        )
    }
}

extension AccountsStore {
    func accountSummaries(
        currentAccountKey: String?,
        currentVariantKey: String? = nil
    ) -> [AccountSummary] {
        let preparedAccounts = accounts.map {
            PreparedAccountSummary(account: $0, identity: $0.resolvedIdentity)
        }
        let resolvedSelection = resolvedCurrentSelectionIdentifiers(
            preparedAccounts: preparedAccounts,
            fallbackAuthAccountKey: currentAccountKey,
            fallbackAuthVariantKey: currentVariantKey
        )

        return preparedAccounts.map { prepared in
            let account = prepared.account
            return AccountSummary(
                id: account.id,
                label: account.label,
                accountKey: prepared.identity.accountKey,
                variantKey: prepared.identity.variantKey,
                email: account.email,
                accountID: account.accountID,
                planType: account.planType,
                teamName: account.teamName,
                teamAlias: account.teamAlias,
                addedAt: account.addedAt,
                updatedAt: account.updatedAt,
                usage: account.usage,
                usageError: account.usageError,
                isCurrent: prepared.identity.matchesSelection(
                    accountKey: resolvedSelection.accountKey,
                    variantKey: resolvedSelection.variantKey
                )
            )
        }
    }

    func accountSummaries(currentAccountID: String?) -> [AccountSummary] {
        accountSummaries(currentAccountKey: currentAccountID)
    }

    private func resolvedCurrentSelectionIdentifiers(
        preparedAccounts: [PreparedAccountSummary],
        fallbackAuthAccountKey: String?,
        fallbackAuthVariantKey: String?
    ) -> (accountKey: String?, variantKey: String?) {
        if let selection = currentSelection,
           preparedAccounts.contains(where: {
               $0.identity.matchesSelection(
                   accountKey: selection.resolvedAccountKey,
                   variantKey: selection.resolvedVariantKey
               )
           }) {
            return (selection.resolvedAccountKey, selection.resolvedVariantKey)
        }
        return (fallbackAuthAccountKey, fallbackAuthVariantKey)
    }
}

private struct PreparedAccountSummary {
    let account: StoredAccount
    let identity: StoredAccountIdentity
}

struct UsageSnapshot: Codable, Equatable {
    var fetchedAt: Int64
    var planType: String?
    var fiveHour: UsageWindow?
    var oneWeek: UsageWindow?
    var credits: CreditSnapshot?
}

struct UsageWindow: Codable, Equatable {
    var usedPercent: Double
    var windowSeconds: Int64
    var resetAt: Int64?
}

struct CreditSnapshot: Codable, Equatable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct ExtractedAuth: Equatable {
    var principalID: String? = nil
    var accountID: String
    var accessToken: String
    var email: String?
    var planType: String?
    var teamName: String?

    var accountKey: String {
        AccountIdentity.accountKey(
            principalID: principalID,
            email: email,
            accountID: accountID
        )
    }

    var variantKey: String {
        AccountIdentity.variantKey(
            principalID: principalID,
            email: email,
            accountID: accountID,
            planType: planType
        )
    }

    static func fromStoredAuth(_ auth: JSONValue) throws -> ExtractedAuth {
        let mode = auth["auth_mode"]?.stringValue?.lowercased() ?? ""
        let tokens: [String: JSONValue]
        if let object = auth["tokens"]?.objectValue {
            tokens = object
        } else if let object = auth.objectValue,
                  object["access_token"]?.stringValue != nil,
                  object["id_token"]?.stringValue != nil {
            tokens = object
        } else {
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
        if let claims = try? AccountIdentityJWT.decode(idToken) {
            email = claims["email"]?.stringValue
            if accountID == nil {
                accountID = claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue
            }
            planType = claims["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.stringValue
        }

        guard let finalAccountID = accountID, !finalAccountID.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.auth.missing_chatgpt_account_id"))
        }

        return ExtractedAuth(
            principalID: AccountIdentity.principalID(
                from: auth,
                email: email,
                fallbackAccountID: finalAccountID
            ),
            accountID: finalAccountID,
            accessToken: accessToken,
            email: email,
            planType: planType,
            teamName: nil
        )
    }
}

enum AccountIdentityJWT {
    static func decode(_ token: String) throws -> JSONValue {
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

struct WorkspaceMetadata: Equatable, Sendable {
    var accountID: String
    var workspaceName: String?
    var structure: String?
}

struct ChatGPTOAuthTokens: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var apiKey: String?
}

struct AppSettings: Codable, Equatable {
    var launchAtStartup: Bool
    var autoRefreshAccounts: Bool
    var autoSmartSwitch: Bool
    var autoStartApiProxy: Bool
    var locale: String

    enum CodingKeys: String, CodingKey {
        case launchAtStartup
        case autoRefreshAccounts
        case autoSmartSwitch
        case autoStartApiProxy
        case locale
    }

    init(
        launchAtStartup: Bool,
        autoRefreshAccounts: Bool,
        autoSmartSwitch: Bool,
        autoStartApiProxy: Bool,
        locale: String
    ) {
        self.launchAtStartup = launchAtStartup
        self.autoRefreshAccounts = autoRefreshAccounts
        self.autoSmartSwitch = autoSmartSwitch
        self.autoStartApiProxy = autoStartApiProxy
        self.locale = AppLocale.resolve(locale).identifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.defaultValue

        launchAtStartup = try container.decodeIfPresent(Bool.self, forKey: .launchAtStartup) ?? fallback.launchAtStartup
        autoRefreshAccounts = try container.decodeIfPresent(Bool.self, forKey: .autoRefreshAccounts) ?? fallback.autoRefreshAccounts
        autoSmartSwitch = try container.decodeIfPresent(Bool.self, forKey: .autoSmartSwitch) ?? fallback.autoSmartSwitch
        autoStartApiProxy = try container.decodeIfPresent(Bool.self, forKey: .autoStartApiProxy) ?? fallback.autoStartApiProxy

        let rawLocale = try container.decodeIfPresent(String.self, forKey: .locale) ?? fallback.locale
        locale = AppLocale.resolve(rawLocale).identifier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtStartup, forKey: .launchAtStartup)
        try container.encode(autoRefreshAccounts, forKey: .autoRefreshAccounts)
        try container.encode(autoSmartSwitch, forKey: .autoSmartSwitch)
        try container.encode(autoStartApiProxy, forKey: .autoStartApiProxy)
        try container.encode(locale, forKey: .locale)
    }

    static var defaultValue: AppSettings {
        AppSettings(
            launchAtStartup: false,
            autoRefreshAccounts: true,
            autoSmartSwitch: false,
            autoStartApiProxy: false,
            locale: AppLocale.automatic.identifier
        )
    }
}

struct AppSettingsPatch {
    var launchAtStartup: Bool? = nil
    var autoRefreshAccounts: Bool? = nil
    var autoSmartSwitch: Bool? = nil
    var autoStartApiProxy: Bool? = nil
    var locale: String? = nil
}

struct ApiProxyStatus: Codable, Equatable {
    var running: Bool
    var port: Int?
    var apiKey: String?
    var baseURL: String?
    var availableAccounts: Int
    var activeAccountID: String?
    var activeAccountLabel: String?
    var lastError: String?

    static let idle = ApiProxyStatus(
        running: false,
        port: nil,
        apiKey: nil,
        baseURL: nil,
        availableAccounts: 0,
        activeAccountID: nil,
        activeAccountLabel: nil,
        lastError: nil
    )
}

struct PendingUpdateInfo: Equatable {
    var currentVersion: String
    var latestVersion: String
    var releaseURL: String
    var notes: String?
    var publishedAt: String?
}
