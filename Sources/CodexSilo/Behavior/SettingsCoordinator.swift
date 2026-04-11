import Foundation
import CryptoKit

struct AccountsDataTransferCodec {
    struct Configuration: Sendable {
        var pbkdf2Iterations: Int
        var keyLength: Int
        var saltLength: Int

        static let defaultValue = Configuration(
            pbkdf2Iterations: 250_000,
            keyLength: 32,
            saltLength: 16
        )
    }

    static let archiveFileExtension = "codexsiloexport"

    private static let archiveFormat = "codexsilo.accounts.export"
    private static let archiveVersion = 1
    private static let kdfAlgorithm = "PBKDF2-HMAC-SHA256"
    private static let cipherAlgorithm = "AES-256-GCM"

    private struct ArchiveEnvelope: Codable {
        var format: String
        var version: Int
        var createdAt: Int64
        var kdf: KDFMetadata
        var cipher: CipherMetadata
        var ciphertextBase64: String
        var tagBase64: String
    }

    private struct KDFMetadata: Codable {
        var algorithm: String
        var saltBase64: String
        var iterations: Int
        var keyLength: Int
    }

    private struct CipherMetadata: Codable {
        var algorithm: String
        var nonceBase64: String
    }

    private let dateProvider: DateProviding
    private let fileManager: FileManager
    private let configuration: Configuration

    init(
        dateProvider: DateProviding = SystemDateProvider(),
        fileManager: FileManager = .default,
        configuration: Configuration = .defaultValue
    ) {
        self.dateProvider = dateProvider
        self.fileManager = fileManager
        self.configuration = configuration
    }

    func export(store: AccountsStore, to url: URL, password: String) throws {
        guard !password.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.transfer.password_required"))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let storeData: Data
        do {
            storeData = try encoder.encode(store)
        } catch {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_payload_format", error.localizedDescription))
        }

        let salt = randomData(length: configuration.saltLength)
        let key = try deriveKey(
            password: password,
            salt: salt,
            iterations: configuration.pbkdf2Iterations,
            keyLength: configuration.keyLength
        )
        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(storeData, using: key, nonce: nonce)
        } catch {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_payload_format", error.localizedDescription))
        }

        let envelope = ArchiveEnvelope(
            format: Self.archiveFormat,
            version: Self.archiveVersion,
            createdAt: dateProvider.unixSecondsNow(),
            kdf: KDFMetadata(
                algorithm: Self.kdfAlgorithm,
                saltBase64: salt.base64EncodedString(),
                iterations: configuration.pbkdf2Iterations,
                keyLength: configuration.keyLength
            ),
            cipher: CipherMetadata(
                algorithm: Self.cipherAlgorithm,
                nonceBase64: data(from: nonce).base64EncodedString()
            ),
            ciphertextBase64: sealedBox.ciphertext.base64EncodedString(),
            tagBase64: sealedBox.tag.base64EncodedString()
        )

        let archiveData: Data
        do {
            archiveData = try encoder.encode(envelope)
        } catch {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_archive"))
        }

        try writeFile(archiveData, to: url)
    }

    func importStore(from url: URL, password: String) throws -> AccountsStore {
        guard !password.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.transfer.password_required"))
        }

        let archiveData = try readFile(from: url)

        let decoder = JSONDecoder()
        let envelope: ArchiveEnvelope
        do {
            envelope = try decoder.decode(ArchiveEnvelope.self, from: archiveData)
        } catch {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_archive"))
        }

        guard envelope.format == Self.archiveFormat else {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_archive"))
        }
        guard envelope.version == Self.archiveVersion else {
            throw AppError.invalidData(
                L10n.tr("error.transfer.unsupported_version_format", String(envelope.version))
            )
        }
        guard envelope.kdf.algorithm == Self.kdfAlgorithm else {
            throw AppError.invalidData(
                L10n.tr("error.transfer.unsupported_kdf_format", envelope.kdf.algorithm)
            )
        }
        guard envelope.cipher.algorithm == Self.cipherAlgorithm else {
            throw AppError.invalidData(
                L10n.tr("error.transfer.unsupported_cipher_format", envelope.cipher.algorithm)
            )
        }
        guard envelope.kdf.iterations > 0, envelope.kdf.keyLength > 0 else {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_archive"))
        }
        guard
            let salt = Data(base64Encoded: envelope.kdf.saltBase64),
            let nonceData = Data(base64Encoded: envelope.cipher.nonceBase64),
            let ciphertext = Data(base64Encoded: envelope.ciphertextBase64),
            let tag = Data(base64Encoded: envelope.tagBase64)
        else {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_archive"))
        }

        let key = try deriveKey(
            password: password,
            salt: salt,
            iterations: envelope.kdf.iterations,
            keyLength: envelope.kdf.keyLength
        )

        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw AppError.unauthorized(L10n.tr("error.transfer.decrypt_failed"))
        }

        do {
            return try decoder.decode(AccountsStore.self, from: plaintext)
        } catch {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_payload_format", error.localizedDescription))
        }
    }

    private func readFile(from url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AppError.io(L10n.tr("error.transfer.read_failed_format", error.localizedDescription))
        }
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw AppError.io(L10n.tr("error.transfer.write_failed_format", error.localizedDescription))
        }
    }

    private func deriveKey(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> SymmetricKey {
        let derived = try pbkdf2(
            password: Data(password.utf8),
            salt: salt,
            iterations: iterations,
            keyLength: keyLength
        )
        return SymmetricKey(data: derived)
    }

    private func pbkdf2(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        guard !password.isEmpty else {
            throw AppError.invalidData(L10n.tr("error.transfer.password_required"))
        }
        guard iterations > 0, keyLength > 0 else {
            throw AppError.invalidData(L10n.tr("error.transfer.invalid_archive"))
        }

        let blocks = Int(ceil(Double(keyLength) / Double(SHA256.Digest.byteCount)))
        var derivedKey = Data()
        derivedKey.reserveCapacity(blocks * SHA256.Digest.byteCount)

        for blockIndex in 1...blocks {
            var saltBlock = salt
            var counter = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &counter) { saltBlock.append(contentsOf: $0) }

            var accumulator = hmacSHA256(key: password, data: saltBlock)
            var previous = accumulator

            if iterations > 1 {
                for _ in 2...iterations {
                    previous = hmacSHA256(key: password, data: previous)
                    accumulator = xor(accumulator, with: previous)
                }
            }

            derivedKey.append(accumulator)
        }

        return derivedKey.prefix(keyLength)
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let digest = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(digest)
    }

    private func xor(_ left: Data, with right: Data) -> Data {
        var result = left
        for index in result.indices {
            result[index] ^= right[index]
        }
        return result
    }

    private func data(from nonce: AES.GCM.Nonce) -> Data {
        nonce.withUnsafeBytes { Data($0) }
    }

    private func randomData(length: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<length).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes)
    }
}

actor SettingsCoordinator {
    private let storeRepository: AccountsStoreRepository
    private let authRepository: AuthRepository?
    private let launchAtStartupService: LaunchAtStartupServiceProtocol
    private let dataTransferCodec: AccountsDataTransferCodec
    private let logger: AppLogger

    init(
        storeRepository: AccountsStoreRepository,
        authRepository: AuthRepository? = nil,
        launchAtStartupService: LaunchAtStartupServiceProtocol,
        dataTransferCodec: AccountsDataTransferCodec = AccountsDataTransferCodec(),
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.storeRepository = storeRepository
        self.authRepository = authRepository
        self.launchAtStartupService = launchAtStartupService
        self.dataTransferCodec = dataTransferCodec
        self.logger = logger
    }

    func currentSettings() throws -> AppSettings {
        try storeRepository.loadStore().settings
    }

    func proxyLiveTestLogs() throws -> [ProxyLiveTestLogEntry] {
        try storeRepository.loadStore().proxyLiveTestLogs
    }

    func updateSettings(_ patch: AppSettingsPatch) throws -> AppSettings {
        let launchAtStartupPatch = patch.launchAtStartup
        logger.info(
            category: .settings,
            event: "update_started",
            message: "Updating application settings.",
            metadata: [
                "launch_at_startup": patch.launchAtStartup.map { $0 ? "true" : "false" } ?? "",
                "auto_refresh_accounts": patch.autoRefreshAccounts.map { $0 ? "true" : "false" } ?? "",
                "auto_smart_switch": patch.autoSmartSwitch.map { $0 ? "true" : "false" } ?? "",
                "auto_start_api_proxy": patch.autoStartApiProxy.map { $0 ? "true" : "false" } ?? "",
                "allow_lan_proxy_access": patch.allowLanProxyAccess.map { $0 ? "true" : "false" } ?? "",
                "locale": patch.locale ?? ""
            ]
        )

        var store = try storeRepository.loadStore()
        var settings = store.settings

        if let value = patch.launchAtStartup { settings.launchAtStartup = value }
        if let value = patch.autoRefreshAccounts { settings.autoRefreshAccounts = value }
        if let value = patch.autoSmartSwitch { settings.autoSmartSwitch = value }
        if let value = patch.autoStartApiProxy { settings.autoStartApiProxy = value }
        if let value = patch.allowLanProxyAccess { settings.allowLanProxyAccess = value }
        if let value = patch.locale { settings.locale = AppLocale.resolve(value).identifier }

        store.settings = settings
        try storeRepository.saveStore(store)

        if let launchAtStartupPatch {
            try launchAtStartupService.setEnabled(launchAtStartupPatch)
        }

        logger.info(
            category: .settings,
            event: "update_succeeded",
            message: "Application settings updated successfully."
        )

        return settings
    }

    func clearProxyLiveTestLogs() throws {
        var store = try storeRepository.loadStore()
        store.proxyLiveTestLogs = []
        try storeRepository.saveStore(store)
    }

    func syncLaunchAtStartupFromStore() throws {
        let settings = try storeRepository.loadStore().settings
        logger.debug(
            category: .settings,
            event: "sync_launch_at_startup_from_store",
            message: "Synchronizing launch-at-startup state from persisted settings.",
            metadata: ["enabled": settings.launchAtStartup ? "true" : "false"]
        )
        try launchAtStartupService.syncWithStoreValue(settings.launchAtStartup)
    }

    func exportAccountData(to url: URL, password: String) throws {
        let operationID = UUID().uuidString
        let store = try storeRepository.loadStore()
        logger.info(
            category: .settings,
            event: "export_started",
            message: "Starting encrypted account data export.",
            metadata: [
                "file": url.lastPathComponent,
                "accounts": String(store.accounts.count)
            ],
            operationID: operationID
        )
        try dataTransferCodec.export(store: store, to: url, password: password)
        logger.info(
            category: .settings,
            event: "export_succeeded",
            message: "Encrypted account data export completed.",
            metadata: ["file": url.lastPathComponent],
            operationID: operationID
        )
    }

    func importAccountData(from url: URL, password: String) throws -> AccountsStore {
        let operationID = UUID().uuidString
        logger.info(
            category: .settings,
            event: "import_started",
            message: "Starting encrypted account data import.",
            metadata: ["file": url.lastPathComponent],
            operationID: operationID
        )
        let store = try dataTransferCodec.importStore(from: url, password: password)
        try storeRepository.saveStore(store)
        if let authRepository,
           let currentSelection = store.currentSelection,
           let selectedAccount = store.accounts.first(where: {
               $0.matchesSelection(
                   accountKey: currentSelection.resolvedAccountKey,
                   variantKey: currentSelection.resolvedVariantKey
               )
           }) {
            try authRepository.writeCurrentAuth(selectedAccount.authJSON)
        }
        try launchAtStartupService.syncWithStoreValue(store.settings.launchAtStartup)
        logger.info(
            category: .settings,
            event: "import_succeeded",
            message: "Encrypted account data import completed.",
            metadata: [
                "file": url.lastPathComponent,
                "accounts": String(store.accounts.count)
            ],
            operationID: operationID
        )
        return store
    }
}
