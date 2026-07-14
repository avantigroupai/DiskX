import Foundation

public enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    public static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }

    public static func count(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// "3 years ago", "2 months ago", "today" from a Unix timestamp (0 → "—").
    public static func age(unixTime: TimeInterval) -> String {
        guard unixTime > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: unixTime)
        let days = -date.timeIntervalSinceNow / 86_400
        switch days {
        case ..<1: return "today"
        case ..<2: return "yesterday"
        case ..<31:
            return "\(Int(days)) days ago"
        case ..<365:
            let months = max(1, Int(days / 30.44))
            return months == 1 ? "1 month ago" : "\(months) months ago"
        default:
            let years = days / 365.25
            return years < 2 ? "1 year ago" : "\(Int(years)) years ago"
        }
    }

    /// Age in days from a Unix timestamp; 0 when unknown.
    public static func ageDays(unixTime: TimeInterval) -> Double {
        guard unixTime > 0 else { return 0 }
        return max(0, (Date().timeIntervalSince1970 - unixTime) / 86_400)
    }
}
