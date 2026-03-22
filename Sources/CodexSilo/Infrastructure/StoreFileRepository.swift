import Foundation

final class StoreFileRepository: AccountsStoreRepository, @unchecked Sendable {
    private let paths: FileSystemPaths
    private let fileManager: FileManager
    private let dateProvider: DateProviding

    init(paths: FileSystemPaths, fileManager: FileManager = .default, dateProvider: DateProviding = SystemDateProvider()) {
        self.paths = paths
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    func loadStore() throws -> AccountsStore {
        let path = paths.accountStorePath
        guard fileManager.fileExists(atPath: path.path) else {
            return AccountsStore()
        }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw AppError.io(L10n.tr("error.store.read_failed_format", error.localizedDescription))
        }

        do {
            return try decodeStore(from: data)
        } catch {
            if let recoveredData = Self.extractFirstJSONObjectData(from: data),
               let recoveredStore = try? decodeStore(from: recoveredData) {
                try saveStore(recoveredStore)
                return recoveredStore
            }

            try backupCorruptedStore(raw: data)
            let emptyStore = AccountsStore()
            try saveStore(emptyStore)
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
            throw AppError.invalidData(L10n.tr("error.store.serialize_failed_format", error.localizedDescription))
        }

        try writeAtomically(data: data, to: paths.accountStorePath)
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
