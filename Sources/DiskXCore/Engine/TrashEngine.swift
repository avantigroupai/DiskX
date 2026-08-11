import Foundation
import Darwin

/// Identity of a file on disk at a point in time.
///
/// A path is not a stable handle: between the moment DiskX shows a confirmation
/// sheet and the moment the user approves it, the path can be replaced by a
/// different file, a symlink, or a directory. Comparing (device, inode, type)
/// makes "delete exactly the thing I showed you" enforceable.
public struct FileIdentity: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let mode: UInt16

    public init(device: Int32, inode: UInt64, mode: UInt16) {
        self.device = device
        self.inode = inode
        self.mode = mode
    }

    /// Captures identity without following symlinks. Returns nil if the path is gone.
    public static func capture(path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: st.st_dev, inode: st.st_ino, mode: st.st_mode & S_IFMT)
    }
}

/// Moves files to the Trash — never hard-deletes. Returns per-item results so the
/// UI can update the tree and report partial failures honestly.
public enum TrashEngine {
    public struct ItemResult: Sendable {
        public let nodeID: UInt64
        public let path: String
        public let trashedTo: String?
        public let error: String?
        public let bytesFreed: Int64
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
    ///
    /// `expecting` maps node id → the identity captured when the plan was built.
    /// Any item whose on-disk identity no longer matches is refused rather than
    /// deleted, closing the window between "user sees the sheet" and "user confirms".
    public static func trash(nodes: [FileNode],
                             expecting: [UInt64: FileIdentity] = [:]) -> Outcome {
        let minimal = minimalCover(of: nodes)
        var results: [ItemResult] = []
        var freed: Int64 = 0
        let fm = FileManager.default

        for node in minimal {
            let path = node.path
            let size = node.allocatedSize

            // 1. Re-verify identity immediately before acting (TOCTOU guard).
            let current = FileIdentity.capture(path: path)
            guard let current else {
                results.append(ItemResult(nodeID: node.id, path: path, trashedTo: nil,
                                          error: "No longer exists", bytesFreed: 0))
                continue
            }
            if let expected = expecting[node.id], expected != current {
                results.append(ItemResult(nodeID: node.id, path: path, trashedTo: nil,
                                          error: "Changed on disk since it was listed — not deleted",
                                          bytesFreed: 0))
                continue
            }

            // 2. Move to Trash.
            var resultingURL: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
            } catch {
                results.append(ItemResult(nodeID: node.id, path: path, trashedTo: nil,
                                          error: error.localizedDescription, bytesFreed: 0))
                continue
            }

            // 3. Verify it actually moved. trashItem reports success for an item
            //    that already lives in the Trash, which would otherwise be booked
            //    as reclaimed bytes that never come back.
            let stillThere = FileIdentity.capture(path: path)
            let movedAway = stillThere == nil || stillThere != current
            let landedElsewhere = resultingURL?.path.map { $0 != path } ?? false
            guard movedAway && landedElsewhere else {
                results.append(ItemResult(nodeID: node.id, path: path,
                                          trashedTo: resultingURL?.path,
                                          error: "Already in the Trash — nothing to reclaim",
                                          bytesFreed: 0))
                continue
            }

            results.append(ItemResult(nodeID: node.id, path: path,
                                      trashedTo: resultingURL?.path, error: nil,
                                      bytesFreed: size))
            freed = SaturatingMath.add(freed, size)
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
