import Foundation

enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        if let short, !short.isEmpty {
            return short
        }
        if let build, !build.isEmpty {
            return build
        }
        return "0.0.0"
    }
}
