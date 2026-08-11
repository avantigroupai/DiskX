import Foundation
import os

/// A node in the scanned file tree.
///
/// Thread-safety model: nodes are mutated concurrently by scanner workers.
/// - `children` appends and `size` accumulation are guarded by `lock`.
/// - After the scan finishes the tree is immutable and may be read freely.
/// - During the scan the UI reads snapshots via the same lock (cheap, low contention).
public final class FileNode: Identifiable, @unchecked Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let directory   = Flags(rawValue: 1 << 0)
        public static let symlink     = Flags(rawValue: 1 << 1)
        public static let inaccessible = Flags(rawValue: 1 << 2)   // permission denied while descending
        public static let package     = Flags(rawValue: 1 << 3)   // .app / bundle directory
        public static let hardlinkDup = Flags(rawValue: 1 << 4)   // size not counted (hard-link duplicate)
        public static let cloudDataless = Flags(rawValue: 1 << 5) // placeholder; content lives in the cloud
    }

    public let id: UInt64                 // unique per scan (monotonic counter)
    public let name: String
    public let flags: Flags
    /// Unix timestamp (seconds since 1970); 0 when unknown.
    public let modified: TimeInterval
    /// Last access Unix timestamp; 0 when unknown.
    public let accessed: TimeInterval
    public unowned let parent: FileNode?

    private let lock = OSAllocatedUnfairLock()
    private var _children: [FileNode] = []
    private var _allocatedSize: Int64 = 0
    private var _logicalSize: Int64 = 0
    private var _fileCount: Int64 = 0
    private var _scanComplete: Bool = false

    public init(id: UInt64,
                name: String,
                flags: Flags,
                modified: TimeInterval = 0,
                accessed: TimeInterval = 0,
                parent: FileNode?,
                allocatedSize: Int64 = 0,
                logicalSize: Int64 = 0) {
        self.id = id
        self.name = name
        self.flags = flags
        self.modified = modified
        self.accessed = accessed
        self.parent = parent
        self._allocatedSize = allocatedSize
        self._logicalSize = logicalSize
        self._fileCount = flags.contains(.directory) ? 0 : 1
    }

    public var isDirectory: Bool { flags.contains(.directory) }
    public var isPackage: Bool { flags.contains(.package) }
    public var isInaccessible: Bool { flags.contains(.inaccessible) }

    /// Allocated (on-disk) size in bytes, aggregated for directories.
    public var allocatedSize: Int64 { lock.withLock { _allocatedSize } }
    /// Logical size in bytes, aggregated for directories.
    public var logicalSize: Int64 { lock.withLock { _logicalSize } }
    /// Number of regular files beneath (1 for a file).
    public var fileCount: Int64 { lock.withLock { _fileCount } }
    /// Directory finished enumerating all descendants.
    public var scanComplete: Bool { lock.withLock { _scanComplete } }

    public var children: [FileNode] { lock.withLock { _children } }

    // MARK: - Scanner-side mutation

    public func appendChild(_ node: FileNode) {
        lock.withLock { _children.append(node) }
    }

    func markScanComplete() {
        lock.withLock { _scanComplete = true }
    }

    /// Adds sizes to this node and every ancestor (called once per scanned batch, not per file).
    ///
    /// Saturating, never trapping: filesystem-reported sizes are untrusted input
    /// (sparse files, hostile network mounts) and a plain `+=` crashed the process
    /// with SIGTRAP once the running totals exceeded Int64.max.
    public func propagateSizes(allocated: Int64, logical: Int64, files: Int64) {
        var node: FileNode? = self
        while let n = node {
            n.lock.withLock {
                n._allocatedSize = SaturatingMath.add(n._allocatedSize, allocated)
                n._logicalSize = SaturatingMath.add(n._logicalSize, logical)
                n._fileCount = SaturatingMath.add(n._fileCount, files)
            }
            node = n.parent
        }
    }

    /// Sorts children by allocated size descending, recursively. Call once after scan completes.
    func sortBySizeRecursively() {
        let kids = lock.withLock { _children }
        let sorted = kids.sorted { $0.allocatedSize > $1.allocatedSize }
        lock.withLock { _children = sorted }
        for child in sorted where child.isDirectory {
            child.sortBySizeRecursively()
        }
    }

    /// Detaches this node after it was trashed: removes it from its parent and
    /// subtracts its aggregate sizes from every ancestor.
    public func detachFromTree() {
        guard let parent else { return }
        let (alloc, logical, files) = lock.withLock { (_allocatedSize, _logicalSize, _fileCount) }
        parent.lock.withLock {
            parent._children.removeAll { $0.id == self.id }
        }
        // Negation must saturate too: -Int64.min traps.
        parent.propagateSizes(allocated: SaturatingMath.negate(alloc),
                              logical: SaturatingMath.negate(logical),
                              files: SaturatingMath.negate(files))
    }

    // MARK: - Paths

    /// Reconstructs the absolute path by walking parents.
    public var path: String {
        var parts: [String] = []
        var node: FileNode? = self
        while let n = node {
            parts.append(n.name)
            node = n.parent
        }
        let joined = parts.reversed().joined(separator: "/")
        return joined.hasPrefix("//") ? String(joined.dropFirst()) : joined
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Path components from the scan root down to this node (inclusive).
    public var ancestryFromRoot: [FileNode] {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let n = node {
            chain.append(n)
            node = n.parent
        }
        return chain.reversed()
    }

    /// Depth-first search for the biggest files under this node.
    /// Bounded selection (size-keyed min-heap of `limit`), O(F log limit) — never
    /// materializes or sorts the full file list.
    public func largestFiles(limit: Int) -> [FileNode] {
        guard limit > 0 else { return [] }
        var heap = MinHeap(capacity: limit)
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else {
                heap.offer(node, key: node.allocatedSize)
            }
        }
        return heap.sortedDescending()
    }
}

/// Fixed-capacity min-heap keyed by size, used for top-N file selection.
private struct MinHeap {
    private var nodes: [(key: Int64, node: FileNode)] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        nodes.reserveCapacity(capacity + 1)
    }

    mutating func offer(_ node: FileNode, key: Int64) {
        if nodes.count < capacity {
            nodes.append((key, node))
            siftUp(nodes.count - 1)
        } else if key > nodes[0].key {
            nodes[0] = (key, node)
            siftDown(0)
        }
    }

    func sortedDescending() -> [FileNode] {
        nodes.sorted { $0.key > $1.key }.map(\.node)
    }

    private mutating func siftUp(_ i: Int) {
        var child = i
        while child > 0 {
            let parent = (child - 1) / 2
            guard nodes[child].key < nodes[parent].key else { break }
            nodes.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ i: Int) {
        var parent = i
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < nodes.count && nodes[left].key < nodes[smallest].key { smallest = left }
            if right < nodes.count && nodes[right].key < nodes[smallest].key { smallest = right }
            guard smallest != parent else { break }
            nodes.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

/// Identity is the scan-local id, not the path: two nodes from different scans are
/// never equal, and a node stays itself even as its aggregate sizes change under it.
extension FileNode: Hashable {
    public static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
