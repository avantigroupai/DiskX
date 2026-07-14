import Foundation

/// Moves files to the Trash — never hard-deletes. Returns per-item results so the
/// UI can update the tree and report partial failures honestly.
public enum TrashEngine {
    public struct ItemResult: Sendable {
        public let path: String
        public let trashedTo: String?
        public let error: String?
        public var succeeded: Bool { error == nil }
    }

    public struct Outcome: Sendable {
        public let results: [ItemResult]
        public let bytesFreed: Int64
        public var failures: [ItemResult] { results.filter { !$0.succeeded } }
        public var successCount: Int { results.filter(\.succeeded).count }
    }

    /// Trashes the given nodes. Skips nodes whose ancestor is also in the set
    /// (trashing the ancestor covers them). Runs synchronously; call off-main.
    public static func trash(nodes: [FileNode]) -> Outcome {
        let minimal = minimalCover(of: nodes)
        var results: [ItemResult] = []
        var freed: Int64 = 0
        let fm = FileManager.default

        for node in minimal {
            let path = node.path
            var resultingURL: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
                results.append(ItemResult(path: path, trashedTo: resultingURL?.path, error: nil))
                freed += node.allocatedSize
            } catch {
                results.append(ItemResult(path: path, trashedTo: nil, error: error.localizedDescription))
            }
        }
        return Outcome(results: results, bytesFreed: freed)
    }

    /// Removes nodes that are descendants of other nodes in the set.
    public static func minimalCover(of nodes: [FileNode]) -> [FileNode] {
        let ids = Set(nodes.map(\.id))
        return nodes.filter { node in
            var ancestor = node.parent
            while let a = ancestor {
                if ids.contains(a.id) { return false }
                ancestor = a.parent
            }
            return true
        }
    }
}
