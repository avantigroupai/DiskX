import Foundation

/// Safety tier of an item — how safe deleting it is. Deterministic, inspectable, never AI.
public enum SafetyTier: Int, Comparable, Sendable {
    case protected = 0      // system/SIP — visible but never deletable through DiskX
    case application = 1    // app bundles
    case coldPersonal = 2   // user's own files, just old
    case review = 3         // app data, project dirs — yours, look first
    case reobtainable = 4   // installers/archives you can download again
    case regenerates = 5    // caches & build artifacts — apps rebuild these

    public static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool { lhs.rawValue < rhs.rawValue }

    public var weight: Double {
        switch self {
        case .regenerates: return 1.0
        case .reobtainable: return 0.8
        case .review: return 0.5
        case .coldPersonal: return 0.35
        case .application: return 0.15
        case .protected: return 0.02
        }
    }

    public var label: String {
        switch self {
        case .regenerates: return "Regenerates"
        case .reobtainable: return "Re-obtainable"
        case .review: return "Yours — review"
        case .coldPersonal: return "Yours, just old"
        case .application: return "Application"
        case .protected: return "Protected"
        }
    }

    /// Monochrome SF Symbol badge.
    public var symbolName: String {
        switch self {
        case .regenerates: return "arrow.triangle.2.circlepath"
        case .reobtainable: return "arrow.down.circle"
        case .review: return "exclamationmark.triangle"
        case .coldPersonal: return "person"
        case .application: return "shippingbox"
        case .protected: return "lock"
        }
    }

    /// Counts toward "Reclaimable now: ~X safe".
    public var isSafeReclaim: Bool { self >= .reobtainable }
}

/// Per-node analysis attached after (or during) a scan.
public struct ReclaimInfo: Sendable {
    public var category: FileCategory = .other
    public var tier: SafetyTier = .review
    public var stalenessMultiplier: Double = 1.0
    /// size × safety × staleness — orders rows, never displayed as bytes.
    public var score: Double = 0
    /// Aggregate allocated bytes in safe tiers (regenerates/re-obtainable) beneath this node.
    public var safeReclaimBytes: Int64 = 0
}

/// A deep node worth hoisting as a ghost row.
public struct Hotspot: Sendable {
    public let node: FileNode
    public let depth: Int
    public let score: Double
}

/// Walks a scanned tree and computes reclaim intelligence: category, safety tier,
/// staleness, reclaim score, safe-reclaim aggregates, and global hotspots.
public final class ReclaimAnalyzer: @unchecked Sendable {
    public private(set) var infos: [UInt64: ReclaimInfo] = [:]
    public private(set) var hotspots: [Hotspot] = []
    public private(set) var totalSafeReclaim: Int64 = 0

    private let now = Date().timeIntervalSince1970
    private let homePath = NSHomeDirectory()

    public init() {}

    /// Staleness from the fresher of modified/accessed. Spec §4.1.
    public static func staleness(now: TimeInterval, modified: TimeInterval, accessed: TimeInterval) -> Double {
        let last = max(modified, accessed)
        guard last > 0 else { return 1.0 }
        let days = (now - last) / 86_400
        switch days {
        case ..<30: return 0.5
        case ..<180: return 0.8
        case ..<365: return 1.0
        case ..<(3 * 365): return 1.5
        default: return 2.0
        }
    }

    func tier(for category: FileCategory, path: String, isDirectory: Bool, ageDays: Double) -> SafetyTier {
        switch category {
        case .cache, .buildArtifact, .trash, .log:
            return .regenerates
        case .installer:
            return .reobtainable
        case .system:
            return .protected
        case .application:
            return .application
        case .backup:
            return .review
        case .media, .document, .code:
            return ageDays > 365 ? .coldPersonal : .review
        case .other:
            let lower = path.lowercased()
            if lower.hasPrefix("/system") || lower.hasPrefix("/usr") || lower.hasPrefix("/bin")
                || lower.hasPrefix("/sbin") || lower.hasPrefix("/private/var/db") {
                return .protected
            }
            return ageDays > 365 ? .coldPersonal : .review
        }
    }

    /// Full analysis pass. Call off-main; results are immutable afterwards.
    public func analyze(root: FileNode) {
        var infoMap: [UInt64: ReclaimInfo] = [:]
        infoMap.reserveCapacity(4096)
        var spots: [Hotspot] = []

        // Shallow nodes (few hundred) get the full path-based classification so
        // system prefixes and path markers are honored; everything deeper runs the
        // O(1) inherited-context classifier — full-path scans over millions of
        // nodes made this pass take minutes.
        let shallowDepthLimit = 2

        @discardableResult
        func visit(_ node: FileNode, path: String, depth: Int, inherited: FileCategory?) -> (score: Double, safe: Int64) {
            let isDir = node.isDirectory
            let category: FileCategory
            if depth <= shallowDepthLimit {
                category = FileCategory.classify(name: node.name, path: path, isDirectory: isDir)
            } else {
                category = FileCategory.classifyFast(name: node.name, isDirectory: isDir, inherited: inherited)
            }
            let ageDays = node.modified > 0 ? (now - max(node.modified, node.accessed)) / 86_400 : 0
            let tier = tier(for: category, path: depth <= shallowDepthLimit ? path : "",
                            isDirectory: isDir, ageDays: ageDays)
            let staleness = Self.staleness(now: now, modified: node.modified, accessed: node.accessed)

            var info = ReclaimInfo(category: category, tier: tier, stalenessMultiplier: staleness)

            if isDir {
                var childScore: Double = 0
                var childSafe: Int64 = 0
                // Whole-tier directories (caches, build artifacts) score as a unit and
                // stop recursing for classification — every descendant shares the tier.
                if tier.isSafeReclaim {
                    info.score = Double(node.allocatedSize) * tier.weight * staleness
                    info.safeReclaimBytes = node.allocatedSize
                    if depth >= 1 && node.allocatedSize > 50_000_000 {
                        spots.append(Hotspot(node: node, depth: depth, score: info.score))
                    }
                } else {
                    let childInherited = category.inheritsToChildren ? category : nil
                    for child in node.children {
                        // Path strings are only needed while the full classifier runs.
                        let childPath = depth < shallowDepthLimit
                            ? (path == "/" ? "/" + child.name : path + "/" + child.name)
                            : ""
                        let r = visit(child, path: childPath, depth: depth + 1, inherited: childInherited)
                        childScore += r.score
                        childSafe += r.safe
                    }
                    info.score = childScore
                    info.safeReclaimBytes = childSafe
                }
            } else {
                info.score = Double(node.allocatedSize) * tier.weight * staleness
                info.safeReclaimBytes = tier.isSafeReclaim ? node.allocatedSize : 0
                if tier.isSafeReclaim && depth >= 1 && node.allocatedSize > 100_000_000 {
                    spots.append(Hotspot(node: node, depth: depth, score: info.score))
                }
            }

            infoMap[node.id] = info
            return (info.score, info.safeReclaimBytes)
        }

        let result = visit(root, path: root.path, depth: 0, inherited: nil)
        spots.sort { $0.score > $1.score }
        infos = infoMap
        hotspots = Array(spots.prefix(64))
        totalSafeReclaim = result.safe
    }

    public func info(for node: FileNode) -> ReclaimInfo {
        if let cached = infos[node.id] { return cached }
        return Self.computeStandalone(node: node, now: now)
    }

    /// Computes info for a single node without aggregation — used for nodes inside
    /// safe zones (e.g. children of node_modules) that the main pass didn't index.
    /// `classify` catches inherited context via path markers.
    public static func computeStandalone(node: FileNode, now: TimeInterval) -> ReclaimInfo {
        let path = node.path
        let category = FileCategory.classify(name: node.name, path: path, isDirectory: node.isDirectory)
        let ageDays = node.modified > 0 ? (now - max(node.modified, node.accessed)) / 86_400 : 0
        let analyzer = ReclaimAnalyzer()
        let tier = analyzer.tier(for: category, path: path, isDirectory: node.isDirectory, ageDays: ageDays)
        let staleness = staleness(now: now, modified: node.modified, accessed: node.accessed)
        var info = ReclaimInfo(category: category, tier: tier, stalenessMultiplier: staleness)
        info.score = Double(node.allocatedSize) * tier.weight * staleness
        info.safeReclaimBytes = tier.isSafeReclaim ? node.allocatedSize : 0
        return info
    }

    /// One-line plain-language justification for a row. Spec §2 "WHY line".
    public func whyLine(for node: FileNode) -> String {
        let info = info(for: node)
        let age = Format.age(unixTime: max(node.modified, node.accessed))
        let frees = Format.bytes(info.safeReclaimBytes > 0 ? info.safeReclaimBytes : node.allocatedSize)
        switch info.tier {
        case .regenerates:
            let what = info.category == .buildArtifact ? "Build artifact — regenerates on next build"
                : info.category == .log ? "Log files — apps recreate them"
                : info.category == .trash ? "Already in Trash — empty it to free space"
                : "Cache — apps rebuild this automatically"
            return "\(what) · untouched \(age) · frees \(frees) now"
        case .reobtainable:
            return "Installer/archive — can be downloaded again · \(age) · frees \(frees)"
        case .review:
            if node.isDirectory && info.safeReclaimBytes > 0 {
                return "Yours — review · contains \(Format.bytes(info.safeReclaimBytes)) of safe-to-delete items"
            }
            return "Yours — review before deleting · modified \(age)"
        case .coldPersonal:
            return "Your file, just old · untouched \(age) · \(frees)"
        case .application:
            return "Application bundle · last used \(age)"
        case .protected:
            return "System file — macOS needs this · not deletable from DiskX"
        }
    }
}
