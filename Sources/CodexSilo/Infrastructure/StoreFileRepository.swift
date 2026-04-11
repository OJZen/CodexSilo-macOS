import Foundation

final class StoreFileRepository: AccountsStoreRepository, @unchecked Sendable {
    private struct StoreFileFingerprint: Equatable {
        let fileID: UInt64?
        let size: UInt64
        let modificationDate: Date

        static let missing = StoreFileFingerprint(
            fileID: nil,
            size: 0,
            modificationDate: .distantPast
        )
    }

    private struct CachedStoreSnapshot {
        let fingerprint: StoreFileFingerprint
        let store: AccountsStore
    }

    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let dateProvider: DateProviding
    private let logger: AppLogger
    private let cacheLock = NSLock()
    private var cachedStoreSnapshot: CachedStoreSnapshot?

    init(
        paths: FileSystemPaths,
        fileManager: FileManager = .default,
        dateProvider: DateProviding = SystemDateProvider(),
        logger: AppLogger = NoopAppLogger.shared
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.logger = logger
    }

    func loadStore() throws -> AccountsStore {
        let path = paths.accountStorePath
        let fingerprint = try fileFingerprint(at: path)

        if let cached = cachedStore(matching: fingerprint) {
            return cached
        }

        guard fingerprint != .missing else {
            let emptyStore = AccountsStore()
            cache(store: emptyStore, fingerprint: .missing)
            logger.info(
                category: .store,
                event: "load_missing",
                message: "Accounts store missing; returning empty store.",
                metadata: ["path": paths.accountStorePath.lastPathComponent]
            )
            return emptyStore
        }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            logger.error(
                category: .store,
                event: "read_failed",
                message: "Failed to read accounts store.",
                metadata: [
                    "path": path.lastPathComponent,
                    "error": error.localizedDescription
                ]
            )
            throw AppError.io(L10n.tr("error.store.read_failed_format", error.localizedDescription))
        }

        do {
            let store = try decodeStore(from: data)
            cache(store: store, fingerprint: fingerprint)
            logger.debug(
                category: .store,
                event: "load_succeeded",
                message: "Accounts store loaded.",
                metadata: [
                    "accounts": String(store.accounts.count),
                    "path": path.lastPathComponent
                ]
            )
            return store
        } catch {
            if let recoveredData = Self.extractFirstJSONObjectData(from: data),
               let recoveredStore = try? decodeStore(from: recoveredData) {
                try saveStore(recoveredStore)
                logger.warning(
                    category: .store,
                    event: "recovered_partial_json",
                    message: "Recovered accounts store from partial JSON payload.",
                    metadata: [
                        "accounts": String(recoveredStore.accounts.count),
                        "path": path.lastPathComponent
                    ]
                )
                return recoveredStore
            }

            try backupCorruptedStore(raw: data)
            let emptyStore = AccountsStore()
            try saveStore(emptyStore)
            logger.error(
                category: .store,
                event: "corrupted_reset",
                message: "Accounts store was corrupted and has been reset to an empty store.",
                metadata: ["path": path.lastPathComponent]
            )
            return emptyStore
        }
    }

    func saveStore(_ store: AccountsStore) throws {
        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(store)
        } catch {
            logger.error(
                category: .store,
                event: "serialize_failed",
                message: "Failed to serialize accounts store.",
                metadata: [
                    "accounts": String(store.accounts.count),
                    "error": error.localizedDescription
                ]
            )
            throw AppError.invalidData(L10n.tr("error.store.serialize_failed_format", error.localizedDescription))
        }

        try writeAtomically(data: data, to: paths.accountStorePath)
        let fingerprint = try fileFingerprint(at: paths.accountStorePath)
        cache(store: store, fingerprint: fingerprint)
        logger.debug(
            category: .store,
            event: "save_succeeded",
            message: "Accounts store saved.",
            metadata: [
                "accounts": String(store.accounts.count),
                "path": paths.accountStorePath.lastPathComponent
            ]
        )
    }

    private func decodeStore(from data: Data) throws -> AccountsStore {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(AccountsStore.self, from: data)
        } catch {
            throw AppError.invalidData(L10n.tr("error.store.invalid_format_format", error.localizedDescription))
        }
    }

    private func backupCorruptedStore(raw: Data) throws {
        let filename = "accounts.corrupt-\(dateProvider.unixSecondsNow()).json"
        let backupPath = paths.applicationSupportDirectory.appendingPathComponent(filename, isDirectory: false)

        try fileManager.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        try raw.write(to: backupPath, options: .atomic)
        Self.setPrivatePermissions(at: backupPath)
        logger.warning(
            category: .store,
            event: "backup_corrupted_store",
            message: "Backed up corrupted accounts store payload.",
            metadata: [
                "backup_file": filename,
                "bytes": String(raw.count)
            ]
        )
    }

    private func writeAtomically(data: Data, to destination: URL) throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)

        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            Self.setPrivatePermissions(at: tempURL)
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
            Self.setPrivatePermissions(at: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            if !fileManager.fileExists(atPath: destination.path) {
                do {
                    try data.write(to: destination, options: .atomic)
                    Self.setPrivatePermissions(at: destination)
                    return
                } catch {
                    throw AppError.io(L10n.tr("error.store.write_failed_format", error.localizedDescription))
                }
            }
            throw AppError.io(L10n.tr("error.store.atomic_write_failed_format", error.localizedDescription))
        }
    }

    private func fileFingerprint(at path: URL) throws -> StoreFileFingerprint {
        guard fileManager.fileExists(atPath: path.path) else {
            return .missing
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: path.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
            return StoreFileFingerprint(
                fileID: fileID,
                size: size,
                modificationDate: modificationDate
            )
        } catch {
            if !fileManager.fileExists(atPath: path.path) {
                return .missing
            }
            throw AppError.io(L10n.tr("error.store.read_failed_format", error.localizedDescription))
        }
    }

    private func cachedStore(matching fingerprint: StoreFileFingerprint) -> AccountsStore? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedStoreSnapshot?.fingerprint == fingerprint else {
            return nil
        }
        return cachedStoreSnapshot?.store
    }

    private func cache(store: AccountsStore, fingerprint: StoreFileFingerprint) {
        cacheLock.lock()
        cachedStoreSnapshot = CachedStoreSnapshot(fingerprint: fingerprint, store: store)
        cacheLock.unlock()
    }

    static func extractFirstJSONObjectData(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var started = false
        var depth = 0
        var inString = false
        var isEscaping = false
        var startIndex: String.Index?

        for index in text.indices {
            let char = text[index]

            if !started {
                if char == "{" {
                    started = true
                    depth = 1
                    startIndex = index
                }
                continue
            }

            if inString {
                if isEscaping {
                    isEscaping = false
                    continue
                }
                if char == "\\" {
                    isEscaping = true
                    continue
                }
                if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
                continue
            }

            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start = startIndex {
                    let slice = text[start...index]
                    return slice.data(using: .utf8)
                }
            }
        }

        return nil
    }

    private static func setPrivatePermissions(at url: URL) {
        #if canImport(Darwin)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        #endif
    }
}
