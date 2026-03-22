import Foundation

final class GitHubUpdateService: UpdateCheckingService, @unchecked Sendable {
    private let session: URLSession
    private let endpoint = URL(string: "https://api.github.com/repos/170-carry/codex-tools/releases/latest")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkForUpdates(currentVersion: String) async throws -> PendingUpdateInfo? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codex-tools-swift/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.network(L10n.tr("error.update.github_api_invalid_response"))
        }

        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let latestVersion = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))

        guard VersionComparator.isNewer(latest: latestVersion, current: currentVersion) else {
            return nil
        }

        return PendingUpdateInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseURL: payload.htmlURL,
            notes: payload.body,
            publishedAt: payload.publishedAt
        )
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var htmlURL: String
    var body: String?
    var publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
    }
}

enum VersionComparator {
    static func isNewer(latest: String, current: String) -> Bool {
        let l = normalize(latest)
        let c = normalize(current)
        for index in 0..<max(l.count, c.count) {
            let lv = index < l.count ? l[index] : 0
            let cv = index < c.count ? c[index] : 0
            if lv > cv { return true }
            if lv < cv { return false }
        }
        return false
    }

    private static func normalize(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .map { part in
                let digits = part.filter(\.isNumber)
                return Int(digits) ?? 0
            }
    }
}
