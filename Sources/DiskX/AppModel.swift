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

struct DeletePlan {
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

enum FocusPane {
    case list, map
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
    var focusPane: FocusPane = .list

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

    // Chrome
    var truth = TruthStats()
    var toast: String?
    private var toastTask: Task<Void, Never>?
    var cheatSheetVisible = false
    var inspectorVisible = false

    let scanTargets: [ScanTarget]

    init() {
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

    // MARK: - Scan lifecycle

    func startScan(path: String) {
        session?.cancel()
        progressTimer?.invalidate()
        scanGeneration += 1
        let generation = scanGeneration

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

    func refreshRows(resetCursor: Bool) {
        guard let root else { rows = []; return }
        let listing: [FileNode]
        var ghosts: [(FileNode, Int)] = []

        if flatTop || scope != nil {
            var files = root.largestFiles(limit: 2000)
            if let scope, let analyzer {
                files = files.filter { scope.matches(info: analyzer.info(for: $0), node: $0) }
                // Scopes also surface whole safe directories (DerivedData, node_modules…).
                let dirSpots = analyzer.hotspots.filter { scope.matches(info: analyzer.info(for: $0.node), node: $0.node) }
                files = (dirSpots.map(\.node) + files).uniqued()
            }
            listing = Array(files.prefix(500))
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

        let sorted = sortNodes(filtered)
        let maxSize = max(sorted.map(\.allocatedSize).max() ?? 1, 1)

        var newRows: [Row] = []
        newRows.reserveCapacity(sorted.count + ghosts.count)
        for (ghost, _) in ghosts {
            newRows.append(makeRow(ghost, maxSize: maxSize, isGhost: true))
        }
        for node in sorted {
            newRows.append(makeRow(node, maxSize: maxSize, isGhost: false))
        }
        rows = newRows
        if resetCursor {
            cursor = 0
            selectedIDs = rows.isEmpty ? [] : [rows[0].id]
            selectionAnchor = nil
        } else {
            cursor = min(cursor, max(0, rows.count - 1))
        }
    }

    private func makeRow(_ node: FileNode, maxSize: Int64, isGhost: Bool) -> Row {
        let info = analyzer?.info(for: node) ?? ReclaimAnalyzer.computeStandalone(node: node, now: Date().timeIntervalSince1970)
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

    private func sortNodes(_ nodes: [FileNode]) -> [FileNode] {
        let sorted: [FileNode]
        switch sortMode {
        case .reclaim:
            if let analyzer {
                sorted = nodes.sorted { analyzer.info(for: $0).score > analyzer.info(for: $1).score }
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

    func requestDelete() {
        guard pendingDelete == nil, !isTrashing else { return }
        let candidates = TrashEngine.minimalCover(of: deleteCandidates)
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = TrashEngine.trash(nodes: items)
            await MainActor.run { [weak self] in
                self?.trashCompleted(outcome, items: items)
            }
        }
    }

    private func trashCompleted(_ outcome: TrashEngine.Outcome, items: [FileNode]) {
        isTrashing = false
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
        // If the current folder itself was trashed, walk up to a surviving ancestor.
        if let current = currentNode, records.contains(where: { $0.node.id == current.id }) {
            currentNode = current.parent ?? root
        }
        refreshRows(resetCursor: false)
        updateTruthScanned()
        if let analyzer, let root {
            let generation = scanGeneration
            Task.detached(priority: .utility) { [weak self] in
                analyzer.analyze(root: root)
                await MainActor.run { [weak self] in
                    guard let self, generation == self.scanGeneration else { return }
                    self.refreshRows(resetCursor: false)
                    self.updateTruthScanned()
                }
            }
        }

        let failures = outcome.failures
        if failures.isEmpty {
            showToast("Moved \(records.count) item\(records.count == 1 ? "" : "s") to Trash — \(Format.bytes(outcome.bytesFreed)) frees when Trash empties · ⌘Z to undo")
        } else {
            showToast("\(records.count) trashed, \(failures.count) failed: \(failures.first!.error ?? "unknown error")")
        }
    }

    func undoLastTrash() {
        guard let batch = undoStack.popLast() else {
            showToast("Nothing to undo")
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var restored: [TrashRecord] = []
            var failed = 0
            let fm = FileManager.default
            for record in batch {
                do {
                    try fm.moveItem(at: record.trashURL, to: URL(fileURLWithPath: record.originalPath))
                    restored.append(record)
                } catch {
                    failed += 1
                }
            }
            let restoredFinal = restored, failedFinal = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                for record in restoredFinal {
                    if let parent = record.node.parent {
                        parent.appendChild(record.node)
                        parent.propagateSizes(allocated: record.node.allocatedSize,
                                              logical: record.node.logicalSize,
                                              files: record.node.fileCount)
                    }
                    self.freedThisSession -= record.bytes
                }
                self.refreshRows(resetCursor: false)
                self.updateTruthScanned()
                self.showToast(failedFinal == 0 ? "Restored \(restoredFinal.count) item\(restoredFinal.count == 1 ? "" : "s") from Trash"
                                                : "Restored \(restoredFinal.count), \(failedFinal) failed")
            }
        }
    }

    // MARK: - Item actions

    func quickLook() {
        let nodes = deleteCandidates
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
        if panel.runModal() == .OK, let url = panel.url {
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
