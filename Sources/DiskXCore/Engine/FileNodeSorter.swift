import Foundation

/// Pure sorting engine for FileNodes.
///
/// Kept allocation-free and deterministic: sorts never mutate the nodes or tree.
public enum FileNodeSorter {
    /// Sorts an array of nodes by the given SortMode and direction.
    ///
    /// - Parameters:
    ///   - nodes: The nodes to sort.
    ///   - mode: The desired sort ordering.
    ///   - reversed: True to invert the sort order (ascending vs descending).
    ///   - infos: Precomputed reclaim intelligence keyed by node ID (for `.reclaim`).
    ///   - now: Reference time for staleness calculations (defaults to current time).
    /// - Returns: A freshly ordered array of nodes.
    public static func sort(
        _ nodes: [FileNode],
        by mode: SortMode,
        reversed: Bool = false,
        infos: [UInt64: ReclaimInfo] = [:],
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [FileNode] {
        switch mode {
        case .reclaim:
            let sorted: [FileNode]
            if !infos.isEmpty {
                sorted = nodes.sorted { a, b in
                    let sA = infos[a.id]?.score ?? 0
                    let sB = infos[b.id]?.score ?? 0
                    if sA != sB { return sA > sB }
                    if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            } else {
                sorted = nodes.sorted { a, b in
                    if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            return reversed ? sorted.reversed() : sorted

        case .size:
            let sorted = nodes.sorted { a, b in
                if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return reversed ? sorted.reversed() : sorted

        case .untouched:
            // "how long they've been untouched": duration = now - lastTouched.
            // When reversed == false (Descending untouched duration):
            //   longest untouched first (oldest lastTouched timestamp first).
            // When reversed == true (Ascending untouched duration):
            //   shortest untouched first (newest lastTouched timestamp first).
            // Files with unknown timestamps (<= 0) always sink to the bottom.
            let known = nodes.filter { $0.lastTouched > 0 }
            let unknown = nodes.filter { $0.lastTouched <= 0 }

            let sortedKnown: [FileNode]
            if !reversed {
                sortedKnown = known.sorted { a, b in
                    let tA = a.lastTouched
                    let tB = b.lastTouched
                    if tA != tB { return tA < tB }
                    if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            } else {
                sortedKnown = known.sorted { a, b in
                    let tA = a.lastTouched
                    let tB = b.lastTouched
                    if tA != tB { return tA > tB }
                    if a.allocatedSize != b.allocatedSize { return a.allocatedSize < b.allocatedSize }
                    return a.name.localizedStandardCompare(b.name) == .orderedDescending
                }
            }

            let sortedUnknown: [FileNode]
            if !reversed {
                sortedUnknown = unknown.sorted { a, b in
                    if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            } else {
                sortedUnknown = unknown.sorted { a, b in
                    if a.allocatedSize != b.allocatedSize { return a.allocatedSize < b.allocatedSize }
                    return a.name.localizedStandardCompare(b.name) == .orderedDescending
                }
            }

            return sortedKnown + sortedUnknown

        case .forgotten:
            func forgottenWeight(_ node: FileNode) -> Double {
                let staleness = ReclaimAnalyzer.staleness(now: now, modified: node.modified, accessed: node.accessed)
                return Double(node.allocatedSize) * staleness
            }
            let sorted = nodes.sorted { a, b in
                let wA = forgottenWeight(a)
                let wB = forgottenWeight(b)
                if wA != wB { return wA > wB }
                if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return reversed ? sorted.reversed() : sorted

        case .count:
            let sorted = nodes.sorted { a, b in
                if a.fileCount != b.fileCount { return a.fileCount > b.fileCount }
                if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return reversed ? sorted.reversed() : sorted

        case .name:
            let sorted = nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return reversed ? sorted.reversed() : sorted
        }
    }
}
