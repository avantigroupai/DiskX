import SwiftUI
import AppKit
import DiskXCore

// MARK: - View-facing value types

enum ScanPhase: Equatable {
    case idle
    case scanning
    case analyzing
    case done
    case failed(String)
}

enum SortMode: Int, CaseIterable, Identifiable {
    case reclaim = 1, size, forgotten, count, name
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .reclaim: return "Reclaim"
        case .size: return "Size"
        case .forgotten: return "Forgotten"
        case .count: return "Files"
        case .name: return "Name"
        }
    }
    var symbolName: String {
        switch self {
        case .reclaim: return "sparkles"
        case .size: return "arrow.down.right.and.arrow.up.left"
        case .forgotten: return "hourglass"
        case .count: return "number"
        case .name: return "textformat"
        }
    }
}

enum ViewMode: Int, CaseIterable {
    case both, list, map
    var label: String {
        switch self {
        case .both: return "Both"
        case .list: return "List"
        case .map: return "Map"
        }
    }
    var symbolName: String {
        switch self {
        case .both: return "rectangle.split.2x1"
        case .list: return "list.bullet"
        case .map: return "square.grid.3x3.topleft.filled"
        }
    }
}

enum SmartScope: String, CaseIterable, Identifiable {
    case devJunk = "Dev Junk"
    case largeOld = "Large & Old"
    case caches = "Caches"
    case installers = "Installers"
    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .devJunk: return "hammer"
        case .largeOld: return "hourglass"
        case .caches: return "arrow.triangle.2.circlepath"
        case .installers: return "shippingbox"
        }
    }
    func matches(info: ReclaimInfo, node: FileNode) -> Bool {
        switch self {
        case .devJunk: return info.category == .buildArtifact
        case .largeOld:
            return node.allocatedSize > 100_000_000 && info.stalenessMultiplier >= 1.5
        case .caches: return info.category == .cache || info.category == .log
        case .installers: return info.category == .installer
        }
    }
}

struct Row: Identifiable, Equatable {
    static func == (lhs: Row, rhs: Row) -> Bool { lhs.id == rhs.id && lhs.primaryBytes == rhs.primaryBytes }
    let node: FileNode
    let isGhost: Bool
    let ghostSuffix: String       // "…/Xcode/DerivedData · 6 levels deep"
    let why: String
    let tier: SafetyTier
    let category: FileCategory
    let ageText: String
    let primaryBytes: Int64       // reclaimable in Reclaim mode, allocated elsewhere
    let allocatedBytes: Int64
    let barFraction: Double       // share of the largest row in this listing
    let safeFraction: Double      // reclaimable share of own size
    var id: UInt64 { node.id }
}

struct DeletePlan: Identifiable {
    let id = UUID()
    let items: [FileNode]
    let totalBytes: Int64
    let safeBytes: Int64
    let risky: Bool
    let riskReason: String?
    let excludedProtected: [FileNode]
    let notes: [String]
}

struct TrashRecord {
    let node: FileNode
    let originalPath: String
    let trashURL: URL
    let bytes: Int64
}

struct TruthStats {
    var total: Int64 = 0
    var free: Int64 = 0
    var purgeable: Int64 = 0
    var scannedTotal: Int64 = 0
    var scannedSafe: Int64 = 0
    var otherUsed: Int64 = 0     // used minus scanned (system, unscanned areas)
}

struct ScanTarget: Identifiable, Hashable {
    let name: String
    let path: String
    let symbolName: String
    var id: String { path }
}

// MARK: - AppModel

@MainActor
@Observable
final class AppModel {
    // Scan
    var phase: ScanPhase = .idle
    var scanTargetPath: String = NSHomeDirectory()
    private(set) var session: ScanSession?
    private(set) var root: FileNode?
    private(set) var analyzer: ReclaimAnalyzer?
    var progress = ScanProgress()
    var scanRate: Double = 0          // files/sec, live
    var scanDuration: TimeInterval = 0
    private var progressTimer: Timer?
    private var lastTickFiles: Int64 = 0
    private var lastTickTime: Date = .now
    private var scanGeneration = 0

    // Navigation & listing
    private(set) var currentNode: FileNode?
    private(set) var rows: [Row] = []
    var cursor: Int = 0
    var selectedIDs: Set<UInt64> = []
    private var selectionAnchor: Int?
    private(set) var marks: [UInt64: FileNode] = [:]

    // Lenses
    var sortMode: SortMode = .reclaim { didSet { refreshRows(resetCursor: true) } }
    var sortReversed: Bool = false { didSet { refreshRows(resetCursor: true) } }
    var viewMode: ViewMode = .both
    var flatTop: Bool = false { didSet { refreshRows(resetCursor: true) } }
    var scope: SmartScope? { didSet { if scope != nil { flatTop = true } else { refreshRows(resetCursor: true) } } }
    var searchText: String = "" { didSet { refreshRows(resetCursor: true) } }
    var showHidden: Bool = false { didSet { refreshRows(resetCursor: true) } }

    // Goal mode
    var goalActive = false
    var goalInput: String = ""
    var goalResult: (count: Int, bytes: Int64)?

    // Deletion & undo
    var pendingDelete: DeletePlan?
    private(set) var undoStack: [[TrashRecord]] = []
    private(set) var freedThisSession: Int64 = 0
    var isTrashing = false
    private(set) var isRestoring = false

    // Chrome
    var truth = TruthStats()
    var toast: String?
    private var toastTask: Task<Void, Never>?
    var cheatSheetVisible = false
    var inspectorVisible = false

    private(set) var scanTargets: [ScanTarget]

    init() {
        if AccessManager.isSandboxed {
            // App Store build: only user-granted locations are scannable.
            let granted = AccessManager.restoreGrantedURLs()
            scanTargets = granted.map { url in
                ScanTarget(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                           path: url.path, symbolName: "folder")
            }
            if let first = granted.first { scanTargetPath = first.path }
        } else {
            var targets: [ScanTarget] = [
                ScanTarget(name: "Home", path: NSHomeDirectory(), symbolName: "house"),
                ScanTarget(name: "Downloads", path: NSHomeDirectory() + "/Downloads", symbolName: "arrow.down.circle"),
                ScanTarget(name: "Applications", path: "/Applications", symbolName: "app"),
                ScanTarget(name: "Macintosh HD", path: "/", symbolName: "internaldrive"),
            ]
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                                options: [.skipHiddenVolumes]) ?? []
            for vol in volumes where vol.path != "/" {
                let name = (try? vol.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? vol.lastPathComponent
                targets.append(ScanTarget(name: name, path: vol.path, symbolName: "externaldrive"))
            }
            scanTargets = targets
        }
    }

    /// The location to scan automatically at launch; nil means show the welcome
    /// screen and wait for the user (sandboxed first run).
    var autoScanPath: String? {
        AccessManager.isSandboxed ? scanTargets.first?.path : scanTargetPath
    }

    // MARK: - Scan lifecycle

    func startScan(path: String) {
        // A trash batch holds live nodes of the current tree — never swap the tree
        // out underneath it.
        guard !isTrashing && !isRestoring else {
            showToast("Finishing a Trash operation — try again in a moment")
            return
        }
        session?.cancel()
        progressTimer?.invalidate()
        scanGeneration += 1
        let generation = scanGeneration

        pendingDelete = nil
        scanTargetPath = path
        phase = .scanning
        root = nil
        analyzer = nil
        // Undo records reference nodes of the old tree (unowned parents) — they must
        // not survive into a new scan.
        undoStack = []
        currentNode = nil
        rows = []
        marks = [:]
        selectedIDs = []
        cursor = 0
        goalActive = false
        goalResult = nil
        scope = nil
        flatTop = false
        searchText = ""

        let newSession = ScanSession(path: path) { [weak self] result in
            Task { @MainActor in
                self?.scanFinished(result, generation: generation)
            }
        }
        session = newSession
        newSession.start()

        lastTickFiles = 0
        lastTickTime = .now
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanTick() }
        }
        updateVolumeStats()
    }

    private func scanTick() {
        guard let session, phase == .scanning else { return }
        let p = session.progress
        let now = Date()
        let dt = now.timeIntervalSince(lastTickTime)
        if dt > 0.2 {
            scanRate = Double(p.filesScanned - lastTickFiles) / dt
            lastTickFiles = p.filesScanned
            lastTickTime = now
        }
        progress = p
        if currentNode == nil, let root = session.root {
            self.root = root
            currentNode = root
        }
        refreshRows(resetCursor: false)
        updateTruthScanned()
    }

    private func scanFinished(_ result: Result<FileNode, ScanError>, generation: Int) {
        guard generation == scanGeneration else { return }
        progressTimer?.invalidate()
        progressTimer = nil

        switch result {
        case .success(let rootNode):
            root = rootNode
            if currentNode == nil { currentNode = rootNode }
            scanDuration = session?.duration ?? 0
            progress = session?.progress ?? progress
            phase = .analyzing
            runAnalysis(generation: generation)
        case .failure(let error):
            if case .cancelled = error {
                phase = .idle
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func runAnalysis(generation: Int) {
        guard let root else { return }
        let fresh = ReclaimAnalyzer()
        Task.detached(priority: .userInitiated) { [weak self] in
            fresh.analyze(root: root)
            await MainActor.run { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                self.analyzer = fresh
                if self.phase == .analyzing { self.phase = .done }
                self.refreshRows(resetCursor: false)
                self.updateTruthScanned()
            }
        }
    }

    func cancelScan() {
        session?.cancel()
    }

    func rescan() {
        startScan(path: scanTargetPath)
    }

    // MARK: - Truth bar

    private func updateVolumeStats() {
        let url = URL(fileURLWithPath: scanTargetPath)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            truth.total = Int64(values.volumeTotalCapacity ?? 0)
            truth.free = Int64(values.volumeAvailableCapacity ?? 0)
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            truth.purgeable = max(0, important - truth.free)
        }
        updateTruthScanned()
    }

    private func updateTruthScanned() {
        truth.scannedTotal = root?.allocatedSize ?? progress.bytesFound
        truth.scannedSafe = analyzer?.totalSafeReclaim ?? 0
        let used = truth.total - truth.free - truth.purgeable
        truth.otherUsed = max(0, used - truth.scannedTotal)
    }

    // MARK: - Rows

    private var flatCache: [FileNode] = []
    private var flatCacheKey = ""

    func refreshRows(resetCursor: Bool) {
        guard let root else { rows = []; return }

        // The cursor tracks a NODE, not an index: live re-sorts must never make the
        // highlight (and thus Delete) silently land on a different file.
        let previousCursorID: UInt64? = rows.indices.contains(cursor) ? rows[cursor].id : nil
        let previousAnchorID: UInt64? = selectionAnchor.flatMap {
            rows.indices.contains($0) ? rows[$0].id : nil
        }

        let listing: [FileNode]
        var ghosts: [(FileNode, Int)] = []

        if flatTop || scope != nil {
            // Full-tree DFS is bounded (top-N heap) and cached: it re-runs only when
            // the tree meaningfully changed, not on every keystroke.
            let key = "\(scanGeneration)|\(progress.dirsScanned)|\(scope?.rawValue ?? "")|\(String(describing: phase))|\(freedThisSession)|\(undoStack.count)"
            if key != flatCacheKey {
                var files = root.largestFiles(limit: 2000)
                if let scope, let analyzer {
                    files = files.filter { scope.matches(info: analyzer.info(for: $0), node: $0) }
                    // Scopes also surface whole safe directories (DerivedData, node_modules…).
                    let dirSpots = analyzer.hotspots.filter { scope.matches(info: analyzer.info(for: $0.node), node: $0.node) }
                    files = (dirSpots.map(\.node) + files).uniqued()
                }
                flatCache = Array(files.prefix(500))
                flatCacheKey = key
            }
            listing = flatCache
        } else {
            guard let current = currentNode else { rows = []; return }
            listing = current.children
            if sortMode == .reclaim, let analyzer, let current = currentNode {
                let childIDs = Set(current.children.map(\.id))
                ghosts = analyzer.hotspots
                    .filter { isDescendant($0.node, of: current) && !childIDs.contains($0.node.id) && $0.node.id != current.id }
                    .prefix(3)
                    .map { ($0.node, $0.depth) }
            }
        }

        var filtered = listing
        if !showHidden && !flatTop && scope == nil {
            filtered = filtered.filter { !$0.name.hasPrefix(".") }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        // One info computation per node per refresh — comparators and row builders
        // share it (computeStandalone walks paths; never call it inside a sort).
        let now = Date().timeIntervalSince1970
        var infoByID: [UInt64: ReclaimInfo] = [:]
        infoByID.reserveCapacity(filtered.count + ghosts.count)
        for node in filtered {
            infoByID[node.id] = analyzer?.info(for: node) ?? ReclaimAnalyzer.computeStandalone(node: node, now: now)
        }
        for (ghost, _) in ghosts where infoByID[ghost.id] == nil {
            infoByID[ghost.id] = analyzer?.info(for: ghost) ?? ReclaimAnalyzer.computeStandalone(node: ghost, now: now)
        }

        let sorted = sortNodes(filtered, infos: infoByID)
        let maxSize = max(sorted.map(\.allocatedSize).max() ?? 1, 1)

        var newRows: [Row] = []
        newRows.reserveCapacity(sorted.count + ghosts.count)
        for (ghost, _) in ghosts {
            newRows.append(makeRow(ghost, maxSize: maxSize, isGhost: true, info: infoByID[ghost.id]!))
        }
        for node in sorted {
            newRows.append(makeRow(node, maxSize: maxSize, isGhost: false, info: infoByID[node.id]!))
        }
        rows = newRows

        if resetCursor {
            cursor = 0
            selectedIDs = rows.isEmpty ? [] : [rows[0].id]
            selectionAnchor = nil
        } else {
            if let id = previousCursorID, let idx = rows.firstIndex(where: { $0.id == id }) {
                cursor = idx
            } else {
                cursor = min(cursor, max(0, rows.count - 1))
            }
            selectionAnchor = previousAnchorID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
        }
    }

    private func makeRow(_ node: FileNode, maxSize: Int64, isGhost: Bool, info: ReclaimInfo) -> Row {
        let alloc = node.allocatedSize
        let primary = sortMode == .reclaim && info.safeReclaimBytes > 0 ? info.safeReclaimBytes : alloc
        var suffix = ""
        if isGhost, let current = currentNode {
            let currentPath = current.path
            let nodePath = node.path
            let rel = nodePath.hasPrefix(currentPath) ? String(nodePath.dropFirst(currentPath.count + 1)) : nodePath
            let depth = rel.components(separatedBy: "/").count
            suffix = "…/\(rel.components(separatedBy: "/").suffix(2).joined(separator: "/")) · \(depth) levels deep"
        }
        return Row(node: node,
                   isGhost: isGhost,
                   ghostSuffix: suffix,
                   why: analyzer?.whyLine(for: node) ?? "",
                   tier: info.tier,
                   category: info.category,
                   ageText: Format.age(unixTime: max(node.modified, node.accessed)),
                   primaryBytes: primary,
                   allocatedBytes: alloc,
                   barFraction: Double(alloc) / Double(maxSize),
                   safeFraction: alloc > 0 ? Double(info.safeReclaimBytes) / Double(alloc) : 0)
    }

    private func sortNodes(_ nodes: [FileNode], infos: [UInt64: ReclaimInfo]) -> [FileNode] {
        let sorted: [FileNode]
        switch sortMode {
        case .reclaim:
            if analyzer != nil {
                sorted = nodes.sorted { (infos[$0.id]?.score ?? 0) > (infos[$1.id]?.score ?? 0) }
            } else {
                sorted = nodes.sorted { $0.allocatedSize > $1.allocatedSize }
            }
        case .size:
            sorted = nodes.sorted { $0.allocatedSize > $1.allocatedSize }
        case .forgotten:
            let now = Date().timeIntervalSince1970
            func forgottenWeight(_ node: FileNode) -> Double {
                let staleness = ReclaimAnalyzer.staleness(now: now, modified: node.modified, accessed: node.accessed)
                return Double(node.allocatedSize) * staleness
            }
            sorted = nodes.sorted { forgottenWeight($0) > forgottenWeight($1) }
        case .count:
            sorted = nodes.sorted { $0.fileCount > $1.fileCount }
        case .name:
            sorted = nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return sortReversed ? sorted.reversed() : sorted
    }

    /// True when the node itself or any ancestor has an id in the set.
    private func hasAncestor(_ node: FileNode, in ids: Set<UInt64>) -> Bool {
        var current: FileNode? = node
        while let n = current {
            if ids.contains(n.id) { return true }
            current = n.parent
        }
        return false
    }

    private func isDescendant(_ node: FileNode, of ancestor: FileNode) -> Bool {
        var p = node.parent
        while let current = p {
            if current.id == ancestor.id { return true }
            p = current.parent
        }
        return false
    }

    // MARK: - Navigation

    var breadcrumb: [FileNode] {
        currentNode?.ancestryFromRoot ?? []
    }

    var cursorRow: Row? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    func moveCursor(_ delta: Int, extending: Bool = false) {
        guard !rows.isEmpty else { return }
        let newIndex = min(max(cursor + delta, 0), rows.count - 1)
        if extending {
            if selectionAnchor == nil { selectionAnchor = cursor }
            cursor = newIndex
            let lo = min(selectionAnchor!, cursor), hi = max(selectionAnchor!, cursor)
            selectedIDs = Set(rows[lo...hi].map(\.id))
        } else {
            cursor = newIndex
            selectionAnchor = nil
            selectedIDs = [rows[newIndex].id]
        }
    }

    func moveCursorTo(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        cursor = index
        selectionAnchor = nil
        selectedIDs = [rows[index].id]
    }

    func setCursor(toNodeID id: UInt64) {
        if let idx = rows.firstIndex(where: { $0.id == id }) {
            moveCursorTo(idx)
        }
    }

    func descend() {
        guard let row = cursorRow else { return }
        let node = row.node
        if node.isDirectory {
            if row.isGhost {
                // Jump to the ghost's real parent with the ghost selected.
                navigate(to: node.parent ?? node)
                setCursor(toNodeID: node.id)
            } else {
                navigate(to: node)
            }
        } else {
            quickLook()
        }
    }

    func ascend() {
        guard let current = currentNode, let parent = current.parent else { return }
        let previousID = current.id
        navigate(to: parent)
        setCursor(toNodeID: previousID)
    }

    func navigate(to node: FileNode) {
        guard node.isDirectory else { return }
        flatTop = false
        scope = nil
        currentNode = node
        refreshRows(resetCursor: true)
    }

    // MARK: - Selection & marks

    func selectAll() {
        selectedIDs = Set(rows.map(\.id))
    }

    func clearSelectionOrAscend() {
        if goalActive {
            goalActive = false
            goalResult = nil
            return
        }
        if !searchText.isEmpty {
            searchText = ""
            return
        }
        if !marks.isEmpty || selectedIDs.count > 1 {
            marks = [:]
            selectedIDs = cursorRow.map { [$0.id] } ?? []
            selectionAnchor = nil
            return
        }
        ascend()
    }

    func toggleMarkAtCursor() {
        guard let row = cursorRow else { return }
        toggleMark(row.node)
        moveCursor(1)
    }

    func toggleMark(_ node: FileNode) {
        if marks[node.id] != nil {
            marks.removeValue(forKey: node.id)
        } else if analyzer?.info(for: node).tier != .protected {
            marks[node.id] = node
        }
    }

    func clearMarks() {
        marks = [:]
    }

    /// What Delete would act on right now: marks win, then selection, then cursor row.
    var deleteCandidates: [FileNode] {
        if !marks.isEmpty { return Array(marks.values) }
        let selectedNodes = rows.filter { selectedIDs.contains($0.id) }.map(\.node)
        if !selectedNodes.isEmpty { return selectedNodes }
        return cursorRow.map { [$0.node] } ?? []
    }

    var statusSummary: String {
        let candidates = deleteCandidates
        guard !candidates.isEmpty else { return "" }
        let bytes = candidates.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let what = marks.isEmpty ? "selected" : "marked"
        return "\(candidates.count) \(what) — \(Format.bytes(bytes))"
    }

    // MARK: - Goal mode

    func applyGoal() {
        guard let analyzer, let gb = Double(goalInput.replacingOccurrences(of: ",", with: ".")), gb > 0 else {
            goalResult = nil
            return
        }
        let target = Int64(gb * 1_000_000_000)
        // Greedy knapsack over global hotspots: shortest safe path to the goal.
        var picked: [FileNode] = []
        var sum: Int64 = 0
        for spot in analyzer.hotspots {
            guard analyzer.info(for: spot.node).tier.isSafeReclaim else { continue }
            if picked.contains(where: { isDescendant(spot.node, of: $0) || $0.id == spot.node.id }) { continue }
            picked.append(spot.node)
            sum += spot.node.allocatedSize
            if sum >= target { break }
        }
        marks = Dictionary(uniqueKeysWithValues: picked.map { ($0.id, $0) })
        goalResult = (picked.count, sum)
    }

    // MARK: - Delete flow

    /// Builds and presents a delete plan. Pass `only:` to act on exactly one node
    /// (context menu), bypassing marks and selection.
    func requestDelete(only explicitNode: FileNode? = nil) {
        guard pendingDelete == nil, !isTrashing, !isRestoring else { return }
        // Mid-scan sizes are partial: the sheet would under-promise what actually
        // gets trashed. Deletion unlocks once enumeration is complete.
        guard phase == .done || phase == .analyzing else {
            showToast("Still scanning — deletion unlocks when the scan finishes")
            return
        }
        let baseCandidates = explicitNode.map { [$0] } ?? deleteCandidates
        let candidates = TrashEngine.minimalCover(of: baseCandidates)
        guard !candidates.isEmpty else { return }

        var deletable: [FileNode] = []
        var protectedItems: [FileNode] = []
        var notes: [String] = []
        var totalBytes: Int64 = 0
        var safeBytes: Int64 = 0
        var risky = false
        var riskReason: String?

        for node in candidates {
            let info = analyzer?.info(for: node) ?? ReclaimAnalyzer.computeStandalone(node: node, now: Date().timeIntervalSince1970)
            if info.tier == .protected {
                protectedItems.append(node)
                continue
            }
            // Pre-flight re-stat: the file may have changed or vanished since the scan.
            var st = stat()
            if lstat(node.path, &st) != 0 {
                notes.append("\(node.name) no longer exists — skipped")
                continue
            }
            deletable.append(node)
            totalBytes += node.allocatedSize
            safeBytes += info.safeReclaimBytes
            if !info.tier.isSafeReclaim {
                risky = true
                riskReason = "Contains items that are yours — review the list"
            }
            if node.fileCount > 10_000 {
                risky = true
                riskReason = "Deletes \(Format.count(node.fileCount)) files"
            }
        }

        if !protectedItems.isEmpty {
            notes.append("\(protectedItems.count) system item(s) can't be trashed from DiskX")
        }
        guard !deletable.isEmpty else {
            showToast(notes.first ?? "Nothing deletable in selection")
            return
        }
        pendingDelete = DeletePlan(items: deletable, totalBytes: totalBytes, safeBytes: safeBytes,
                                   risky: risky, riskReason: riskReason,
                                   excludedProtected: protectedItems, notes: notes)
    }

    func cancelDelete() {
        pendingDelete = nil     // marks intentionally preserved
    }

    func confirmDelete() {
        guard let plan = pendingDelete, !isTrashing else { return }
        pendingDelete = nil
        isTrashing = true
        let items = plan.items
        let generation = scanGeneration
        // Anchor the whole tree for the duration: nodes hold `unowned` parents, so
        // the tree must outlive any background path reconstruction.
        let treeAnchor = root
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = TrashEngine.trash(nodes: items)
            await MainActor.run { [weak self] in
                self?.trashCompleted(outcome, items: items, generation: generation)
                _ = treeAnchor
            }
        }
    }

    private func trashCompleted(_ outcome: TrashEngine.Outcome, items: [FileNode], generation: Int) {
        isTrashing = false
        // A rescan happened mid-trash: the deletions are real, but the old tree is
        // gone — report and leave the new scan's state untouched.
        guard generation == scanGeneration else {
            freedThisSession += outcome.bytesFreed
            showToast("Moved \(outcome.successCount) item\(outcome.successCount == 1 ? "" : "s") to Trash (before rescan) — undo unavailable")
            return
        }
        var records: [TrashRecord] = []
        for result in outcome.results where result.succeeded {
            guard let node = items.first(where: { $0.path == result.path }),
                  let trashPath = result.trashedTo else { continue }
            records.append(TrashRecord(node: node, originalPath: result.path,
                                       trashURL: URL(fileURLWithPath: trashPath),
                                       bytes: node.allocatedSize))
            node.detachFromTree()
            marks.removeValue(forKey: node.id)
            selectedIDs.remove(node.id)
        }
        if !records.isEmpty {
            undoStack.append(records)
            freedThisSession += outcome.bytesFreed
        }
        let trashedIDs = Set(records.map(\.node.id))
        // Prune marks that live inside a trashed folder — they must not resurrect
        // against a re-created path later.
        marks = marks.filter { !hasAncestor($0.value, in: trashedIDs) }
        // If the current folder (or an ancestor) was trashed, walk up to a survivor.
        if let current = currentNode {
            var node: FileNode? = current
            while let n = node {
                if trashedIDs.contains(n.id) {
                    currentNode = n.parent ?? root
                    break
                }
                node = n.parent
            }
        }
        refreshRows(resetCursor: false)
        updateTruthScanned()
        // Re-analysis always runs on a FRESH analyzer and is published on the main
        // actor — the live one is read by the UI and must never mutate off-main.
        runAnalysis(generation: scanGeneration)

        let failures = outcome.failures
        if failures.isEmpty {
            showToast("Moved \(records.count) item\(records.count == 1 ? "" : "s") to Trash — \(Format.bytes(outcome.bytesFreed)) frees when Trash empties · ⌘Z to undo")
        } else {
            showToast("\(records.count) trashed, \(failures.count) failed: \(failures.first!.error ?? "unknown error")")
        }
    }

    func undoLastTrash() {
        guard !isRestoring else { return }        // one restore batch at a time — keep LIFO intact
        guard let batch = undoStack.popLast() else {
            showToast("Nothing to undo")
            return
        }
        isRestoring = true
        let generation = scanGeneration
        let treeAnchor = root                     // keep unowned parents alive during the restore
        Task.detached(priority: .userInitiated) { [weak self] in
            var restored: [TrashRecord] = []
            var failedRecords: [TrashRecord] = []
            let fm = FileManager.default
            for record in batch {
                do {
                    try fm.moveItem(at: record.trashURL, to: URL(fileURLWithPath: record.originalPath))
                    restored.append(record)
                } catch {
                    failedRecords.append(record)
                }
            }
            let restoredFinal = restored, failedFinal = failedRecords
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRestoring = false
                guard generation == self.scanGeneration else {
                    // Files are back on disk, but they belong to a replaced tree —
                    // the running/new scan will pick them up.
                    self.showToast("Restored \(restoredFinal.count) item\(restoredFinal.count == 1 ? "" : "s") — rescan to see them")
                    _ = treeAnchor
                    return
                }
                for record in restoredFinal {
                    if let parent = record.node.parent {
                        parent.appendChild(record.node)
                        parent.propagateSizes(allocated: record.node.allocatedSize,
                                              logical: record.node.logicalSize,
                                              files: record.node.fileCount)
                    }
                    self.freedThisSession -= record.bytes
                }
                if !failedFinal.isEmpty {
                    self.undoStack.append(failedFinal)   // retryable after the user fixes the cause
                }
                self.refreshRows(resetCursor: false)
                self.updateTruthScanned()
                self.showToast(failedFinal.isEmpty ? "Restored \(restoredFinal.count) item\(restoredFinal.count == 1 ? "" : "s") from Trash"
                                                   : "Restored \(restoredFinal.count), \(failedFinal.count) failed — ⌘Z retries them")
                _ = treeAnchor
            }
        }
    }

    // MARK: - Item actions

    func quickLook() {
        // Preview what's highlighted, not the pending delete set — marks gathered
        // elsewhere must not hijack Space on the current row.
        let selectedNodes = rows.filter { selectedIDs.contains($0.id) }.map(\.node)
        let nodes = selectedNodes.isEmpty ? (cursorRow.map { [$0.node] } ?? []) : selectedNodes
        guard !nodes.isEmpty else { return }
        QuickLookController.shared.toggle(urls: nodes.map(\.url))
    }

    func revealInFinder() {
        guard let row = cursorRow else { return }
        NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
    }

    func openSelection() {
        guard let row = cursorRow else { return }
        NSWorkspace.shared.open(row.node.url)
    }

    func copyPath() {
        guard let row = cursorRow else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.node.path, forType: .string)
        showToast("Path copied")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "DiskX analyzes only locations you choose. Everything stays on this Mac."
        if panel.runModal() == .OK, let url = panel.url {
            AccessManager.grant(url)
            let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            let target = ScanTarget(name: name, path: url.path, symbolName: "folder")
            if !scanTargets.contains(where: { $0.path == target.path }) {
                scanTargets.append(target)
            }
            startScan(path: url.path)
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Sort helpers

    func selectSort(_ mode: SortMode) {
        if sortMode == mode {
            sortReversed.toggle()
        } else {
            sortMode = mode
            sortReversed = false
        }
    }

    func cycleSort() {
        let all = SortMode.allCases
        let idx = all.firstIndex(of: sortMode) ?? 0
        sortMode = all[(idx + 1) % all.count]
        sortReversed = false
    }
}

private extension Array where Element == FileNode {
    func uniqued() -> [FileNode] {
        var seen = Set<UInt64>()
        return filter { seen.insert($0.id).inserted }
    }
}
