import Foundation

/// The orderings offered by the `1`–`6` keys and the Sort controls.
///
/// `reclaim` is the default and the product's whole argument — see `ReclaimAnalyzer`.
/// `untouched` orders files purely by how long they have been untouched (fresher of modified/accessed).
public enum SortMode: Int, CaseIterable, Identifiable, Sendable {
    case reclaim = 1, size, untouched, forgotten, count, name

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .reclaim: return "Reclaim"
        case .size: return "Size"
        case .untouched: return "Untouched"
        case .forgotten: return "Forgotten"
        case .count: return "Files"
        case .name: return "Name"
        }
    }

    public var symbolName: String {
        switch self {
        case .reclaim: return "sparkles"
        case .size: return "arrow.down.right.and.arrow.up.left"
        case .untouched: return "clock"
        case .forgotten: return "hourglass"
        case .count: return "number"
        case .name: return "textformat"
        }
    }
}
