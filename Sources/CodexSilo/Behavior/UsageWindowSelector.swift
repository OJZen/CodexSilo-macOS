import Foundation

enum UsageWindowSelector {
    static func pickNearestWindow(_ windows: [UsageWindowRaw], targetSeconds: Int64) -> UsageWindowRaw? {
        windows.min { lhs, rhs in
            abs(lhs.limitWindowSeconds - targetSeconds) < abs(rhs.limitWindowSeconds - targetSeconds)
        }
    }
}
