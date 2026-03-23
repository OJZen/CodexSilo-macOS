import Foundation

final class LocalizedDateFormatterCache: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let localeIdentifier: String
        let dateStyle: Int
        let timeStyle: Int
    }

    static let shared = LocalizedDateFormatterCache()

    private let lock = NSLock()
    private var formatters: [CacheKey: DateFormatter] = [:]

    private init() {}

    func string(
        from date: Date,
        locale: Locale,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> String {
        let key = CacheKey(
            localeIdentifier: locale.identifier,
            dateStyle: Int(dateStyle.rawValue),
            timeStyle: Int(timeStyle.rawValue)
        )

        lock.lock()
        defer { lock.unlock() }

        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = locale
            created.calendar = .autoupdatingCurrent
            created.timeZone = .autoupdatingCurrent
            created.dateStyle = dateStyle
            created.timeStyle = timeStyle
            formatters[key] = created
            formatter = created
        }

        return formatter.string(from: date)
    }
}
