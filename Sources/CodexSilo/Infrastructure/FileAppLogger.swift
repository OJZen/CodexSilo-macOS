import Foundation
#if canImport(Darwin)
import Darwin
#endif

final class FileAppLogger: AppLogger, @unchecked Sendable {
    struct Configuration: Sendable {
        var maxFileSizeBytes: Int
        var retentionDays: Int

        static let defaultValue = Configuration(
            maxFileSizeBytes: 512 * 1_024,
            retentionDays: 7
        )
    }

    fileprivate struct PendingLogPayload: Sendable {
        var timestamp: Date
        var level: LogLevel
        var scope: String
        var message: String
        var metadataSummary: String?
    }

    private let logsDirectory: URL
    private let writer: FileLogWriter

    init(
        paths: FileSystemPaths,
        fileManager: FileManager = .default,
        configuration: Configuration = .defaultValue
    ) {
        _ = fileManager
        self.logsDirectory = paths.logsDirectory
        self.writer = FileLogWriter(
            logsDirectory: paths.logsDirectory,
            configuration: configuration
        )
    }

    func log(
        _ level: LogLevel,
        category: LogCategory,
        event: String,
        message: String,
        metadata: [String: String],
        operationID: String?
    ) {
        let scope = "\(category.rawValue).\(event)"
        var sanitizedMetadata = LogRedactor.sanitizeMetadata(metadata)
        if let operationID, !operationID.isEmpty {
            sanitizedMetadata["operation_id"] = LogRedactor.maskIdentifier(operationID)
        }

        let metadataSummary = sanitizedMetadata.isEmpty
            ? nil
            : sanitizedMetadata
                .map { key, value in "\(key)=\(value)" }
                .sorted()
                .joined(separator: " ")
        let payload = PendingLogPayload(
            timestamp: Date(),
            level: level,
            scope: scope,
            message: LogRedactor.sanitizeMessage(message),
            metadataSummary: metadataSummary
        )

        Task {
            await writer.write(payload)
        }
    }

    func loadEntries(limit: Int) async throws -> [AppLogEntry] {
        try await writer.loadEntries(limit: limit)
    }

    func loadCombinedText(limit: Int) async throws -> String {
        try await writer.loadCombinedText(limit: limit)
    }

    func clearLogs() async throws {
        try await writer.clearLogs()
    }

    func logsDirectoryURL() -> URL {
        logsDirectory
    }
}

private actor FileLogWriter {
    private let logsDirectory: URL
    private let fileManager = FileManager.default
    private let configuration: FileAppLogger.Configuration
    private let currentLogURL: URL
    private let archiveTimestampFormatter: DateFormatter

    init(
        logsDirectory: URL,
        configuration: FileAppLogger.Configuration
    ) {
        self.logsDirectory = logsDirectory
        self.configuration = configuration
        self.currentLogURL = logsDirectory.appendingPathComponent("app.log", isDirectory: false)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        self.archiveTimestampFormatter = formatter
    }

    func write(_ payload: FileAppLogger.PendingLogPayload) async {
        do {
            try ensureLogsDirectory()
            try rotateIfNeeded(now: payload.timestamp)
            try pruneExpiredLogs(now: payload.timestamp)
            try append(line: formattedLine(for: payload))
        } catch {
            #if DEBUG
            let message = "FileAppLogger write failed: \(error.localizedDescription)\n"
            if let data = message.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            #endif
        }
    }

    func loadEntries(limit: Int) throws -> [AppLogEntry] {
        guard limit > 0 else { return [] }
        let lines = try loadRecentLines(limit: limit)
        return lines.enumerated().compactMap { index, line in
            AppLogEntry.parse(line: line, id: "\(index)-\(line)")
        }
    }

    func loadCombinedText(limit: Int) throws -> String {
        guard limit > 0 else { return "" }
        return try loadRecentLines(limit: limit).joined(separator: "\n")
    }

    func clearLogs() throws {
        guard fileManager.fileExists(atPath: logsDirectory.path) else { return }
        let fileURLs = try fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for fileURL in fileURLs where fileURL.pathExtension == "log" {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func formattedLine(for payload: FileAppLogger.PendingLogPayload) -> String {
        var line = "\(LogTimestampFormatter.string(from: payload.timestamp)) [\(payload.level.label)] [\(payload.scope)] \(payload.message)"
        if let metadataSummary = payload.metadataSummary,
           !metadataSummary.isEmpty {
            line += " | \(metadataSummary)"
        }
        return line
    }

    private func ensureLogsDirectory() throws {
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        }
        Self.setPrivatePermissions(at: logsDirectory, isDirectory: true)
    }

    private func rotateIfNeeded(now: Date) throws {
        guard fileManager.fileExists(atPath: currentLogURL.path) else { return }

        let attributes = try fileManager.attributesOfItem(atPath: currentLogURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? now
        let shouldRotateForSize = size >= configuration.maxFileSizeBytes
        let shouldRotateForDay = !Calendar(identifier: .gregorian).isDate(modifiedAt, inSameDayAs: now)
        guard shouldRotateForSize || shouldRotateForDay else { return }

        var archiveURL = logsDirectory.appendingPathComponent(
            "app-\(archiveTimestampFormatter.string(from: modifiedAt)).log",
            isDirectory: false
        )
        if fileManager.fileExists(atPath: archiveURL.path) {
            archiveURL = logsDirectory.appendingPathComponent(
                "app-\(archiveTimestampFormatter.string(from: modifiedAt))-\(UUID().uuidString.prefix(8)).log",
                isDirectory: false
            )
        }

        try fileManager.moveItem(at: currentLogURL, to: archiveURL)
        Self.setPrivatePermissions(at: archiveURL, isDirectory: false)
    }

    private func pruneExpiredLogs(now: Date) throws {
        guard configuration.retentionDays > 0,
              fileManager.fileExists(atPath: logsDirectory.path) else {
            return
        }

        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -configuration.retentionDays,
            to: now
        ) ?? now
        let fileURLs = try fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for fileURL in fileURLs where fileURL.pathExtension == "log" {
            guard fileURL.lastPathComponent != currentLogURL.lastPathComponent else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            if modifiedAt < cutoff {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func append(line: String) throws {
        let lineData = Data((line + "\n").utf8)
        if !fileManager.fileExists(atPath: currentLogURL.path) {
            fileManager.createFile(atPath: currentLogURL.path, contents: lineData)
            Self.setPrivatePermissions(at: currentLogURL, isDirectory: false)
            return
        }

        let handle = try FileHandle(forWritingTo: currentLogURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: lineData)
        Self.setPrivatePermissions(at: currentLogURL, isDirectory: false)
    }

    private func loadRecentLines(limit: Int) throws -> [String] {
        guard fileManager.fileExists(atPath: logsDirectory.path) else { return [] }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "log" }
        .sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        var collected: [String] = []
        for fileURL in fileURLs {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lines = content
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .reversed()

            for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(line)
                if collected.count == limit {
                    return collected
                }
            }
        }

        return collected
    }

    private static func setPrivatePermissions(at url: URL, isDirectory: Bool) {
        #if canImport(Darwin)
        let mode: mode_t = isDirectory
            ? (S_IRUSR | S_IWUSR | S_IXUSR)
            : (S_IRUSR | S_IWUSR)
        _ = chmod(url.path, mode)
        #endif
    }
}
