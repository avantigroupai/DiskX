import XCTest
@testable import DiskXCore

// Reclaim Sort is the product's central claim: rows are ordered by what is safe
// to delete first, not by raw size, and every row can explain itself. That makes
// the scoring rules a contract with the user rather than an implementation
// detail — these tests pin the parts of it that would silently mislead people if
// they drifted.

final class StalenessTests: XCTestCase {
    /// Fixed instant so the buckets are asserted against arithmetic, not the clock.
    private let now: TimeInterval = 1_700_000_000

    private func staleness(daysAgo: Double) -> Double {
        ReclaimAnalyzer.staleness(now: now, modified: now - daysAgo * 86_400, accessed: 0)
    }

    func testBucketBoundaries() {
        XCTAssertEqual(staleness(daysAgo: 1), 0.5)
        XCTAssertEqual(staleness(daysAgo: 29), 0.5)
        XCTAssertEqual(staleness(daysAgo: 31), 0.8)
        XCTAssertEqual(staleness(daysAgo: 179), 0.8)
        XCTAssertEqual(staleness(daysAgo: 200), 1.0)
        XCTAssertEqual(staleness(daysAgo: 364), 1.0)
        XCTAssertEqual(staleness(daysAgo: 400), 1.5)
        XCTAssertEqual(staleness(daysAgo: 2 * 365), 1.5)
        XCTAssertEqual(staleness(daysAgo: 4 * 365), 2.0)
    }

    /// A file modified years ago but opened yesterday is in active use. Taking the
    /// fresher of the two timestamps is what stops DiskX recommending the
    /// reference PDF someone reads weekly but has never edited.
    func testUsesFresherOfModifiedAndAccessed() {
        let ancient = now - 1_000 * 86_400
        let yesterday = now - 86_400
        XCTAssertEqual(ReclaimAnalyzer.staleness(now: now, modified: ancient, accessed: yesterday), 0.5)
        XCTAssertEqual(ReclaimAnalyzer.staleness(now: now, modified: yesterday, accessed: ancient), 0.5)
    }

    /// Unknown timestamps must not read as "ancient, delete it" — they are neutral.
    func testUnknownTimestampsAreNeutral() {
        XCTAssertEqual(ReclaimAnalyzer.staleness(now: now, modified: 0, accessed: 0), 1.0)
    }
}

final class SafetyTierTests: XCTestCase {
    private let analyzer = ReclaimAnalyzer()

    func testRegenerableCategories() {
        for category in [FileCategory.cache, .buildArtifact, .trash, .log] {
            XCTAssertEqual(analyzer.tier(for: category, path: "/x", isDirectory: true, ageDays: 10),
                           .regenerates, "\(category) should regenerate")
        }
    }

    func testInstallersAreReobtainable() {
        XCTAssertEqual(analyzer.tier(for: .installer, path: "/x/Xcode.dmg", isDirectory: false, ageDays: 10),
                       .reobtainable)
    }

    func testSystemAndApplicationTiers() {
        XCTAssertEqual(analyzer.tier(for: .system, path: "/System/x", isDirectory: false, ageDays: 10), .protected)
        XCTAssertEqual(analyzer.tier(for: .application, path: "/Applications/X.app", isDirectory: true, ageDays: 10),
                       .application)
        XCTAssertEqual(analyzer.tier(for: .backup, path: "/x/backup", isDirectory: true, ageDays: 10), .review)
    }

    /// Personal files age from "review" into "yours, just old" at one year. They
    /// never become safe-reclaim at any age.
    func testPersonalFilesAgeIntoColdPersonal() {
        for category in [FileCategory.media, .document, .code] {
            XCTAssertEqual(analyzer.tier(for: category, path: "/u/f", isDirectory: false, ageDays: 10), .review)
            XCTAssertEqual(analyzer.tier(for: category, path: "/u/f", isDirectory: false, ageDays: 400),
                           .coldPersonal)
        }
        XCTAssertFalse(SafetyTier.coldPersonal.isSafeReclaim)
    }

    /// Unclassified files under system prefixes must be protected regardless of age —
    /// this is the backstop for anything the category tables do not recognise.
    func testUnknownFilesUnderSystemPrefixesAreProtected() {
        for path in ["/usr/lib/thing", "/System/Library/thing", "/bin/thing",
                     "/sbin/thing", "/private/var/db/thing"] {
            XCTAssertEqual(analyzer.tier(for: .other, path: path, isDirectory: false, ageDays: 4_000),
                           .protected, "\(path) must stay protected")
        }
        XCTAssertEqual(analyzer.tier(for: .other, path: "/Users/me/thing", isDirectory: false, ageDays: 10),
                       .review)
    }

    /// "Reclaimable now: ~X safe" must only ever count things the user can lose
    /// without consequence. Widening this set changes a promise made in the UI.
    func testOnlyRegenerableAndReobtainableCountAsSafe() {
        XCTAssertTrue(SafetyTier.regenerates.isSafeReclaim)
        XCTAssertTrue(SafetyTier.reobtainable.isSafeReclaim)
        XCTAssertFalse(SafetyTier.review.isSafeReclaim)
        XCTAssertFalse(SafetyTier.coldPersonal.isSafeReclaim)
        XCTAssertFalse(SafetyTier.application.isSafeReclaim)
        XCTAssertFalse(SafetyTier.protected.isSafeReclaim)
    }

    func testWeightsDescendWithRisk() {
        let ordered: [SafetyTier] = [.regenerates, .reobtainable, .review, .coldPersonal, .application, .protected]
        for (lighter, heavier) in zip(ordered, ordered.dropFirst()) {
            XCTAssertGreaterThan(lighter.weight, heavier.weight,
                                 "\(lighter) must outweigh \(heavier)")
        }
    }
}

final class ReclaimAnalyzerTests: XCTestCase {
    private var nextID: UInt64 = 0
    private func makeID() -> UInt64 { nextID += 1; return nextID }

    private func timestamp(daysOld: Double) -> TimeInterval {
        Date().timeIntervalSince1970 - daysOld * 86_400
    }

    @discardableResult
    private func dir(_ name: String, in parent: FileNode?, daysOld: Double = 10) -> FileNode {
        let ts = timestamp(daysOld: daysOld)
        let node = FileNode(id: makeID(), name: name, flags: [.directory],
                            modified: ts, accessed: ts, parent: parent)
        parent?.appendChild(node)
        return node
    }

    /// Mirrors the scanner: the file carries its own size, and the parent chain is
    /// credited once via propagateSizes.
    @discardableResult
    private func file(_ name: String, in parent: FileNode, bytes: Int64, daysOld: Double = 10) -> FileNode {
        let ts = timestamp(daysOld: daysOld)
        let node = FileNode(id: makeID(), name: name, flags: [],
                            modified: ts, accessed: ts, parent: parent,
                            allocatedSize: bytes, logicalSize: bytes)
        parent.appendChild(node)
        parent.propagateSizes(allocated: bytes, logical: bytes, files: 1)
        return node
    }

    /// A miniature home directory: a stale cache, a re-downloadable installer and
    /// a recent personal document.
    private func makeHomeTree() -> (root: FileNode, caches: FileNode, installer: FileNode, doc: FileNode) {
        let root = FileNode(id: makeID(), name: "/Users/tester", flags: [.directory], parent: nil)
        let library = dir("Library", in: root)
        let caches = dir("Caches", in: library, daysOld: 400)
        file("blob.bin", in: caches, bytes: 200_000_000, daysOld: 400)
        let downloads = dir("Downloads", in: root)
        let installer = file("Xcode.dmg", in: downloads, bytes: 150_000_000, daysOld: 400)
        let documents = dir("Documents", in: root)
        let doc = file("report.pdf", in: documents, bytes: 5_000_000, daysOld: 5)
        return (root, caches, installer, doc)
    }

    func testTiersAssignedAcrossTheTree() {
        let tree = makeHomeTree()
        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: tree.root)

        XCTAssertEqual(analyzer.info(for: tree.caches).tier, .regenerates)
        XCTAssertEqual(analyzer.info(for: tree.caches).category, .cache)
        XCTAssertEqual(analyzer.info(for: tree.installer).tier, .reobtainable)
        XCTAssertEqual(analyzer.info(for: tree.installer).category, .installer)
        XCTAssertEqual(analyzer.info(for: tree.doc).tier, .review)
        XCTAssertEqual(analyzer.info(for: tree.doc).category, .document)
    }

    /// The headline "Reclaimable now" figure is a sum of allocated bytes in safe
    /// tiers only — the personal document must not inflate it.
    func testSafeReclaimAggregatesUpTheTree() {
        let tree = makeHomeTree()
        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: tree.root)

        XCTAssertEqual(analyzer.totalSafeReclaim, 350_000_000)
        XCTAssertEqual(analyzer.info(for: tree.root).safeReclaimBytes, 350_000_000)
        XCTAssertEqual(analyzer.info(for: tree.caches).safeReclaimBytes, 200_000_000)
        XCTAssertEqual(analyzer.info(for: tree.installer).safeReclaimBytes, 150_000_000)
        XCTAssertEqual(analyzer.info(for: tree.doc).safeReclaimBytes, 0)
    }

    /// The inversion that justifies the whole feature: a stale cache outranks a
    /// physically larger file the user actually cares about.
    func testStaleJunkOutranksBiggerPersonalFiles() {
        let root = FileNode(id: makeID(), name: "/Users/tester", flags: [.directory], parent: nil)
        let library = dir("Library", in: root)
        let caches = dir("Caches", in: library, daysOld: 400)
        file("blob.bin", in: caches, bytes: 200_000_000, daysOld: 400)
        let movies = dir("Movies", in: root)
        let video = file("holiday.mov", in: movies, bytes: 800_000_000, daysOld: 5)

        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: root)

        XCTAssertGreaterThan(analyzer.info(for: caches).score, analyzer.info(for: video).score,
                             "200 MB of stale cache must rank above a recent 800 MB video")
        XCTAssertEqual(analyzer.info(for: video).tier, .review)
    }

    /// Safe-tier directories score as a unit and stop recursing, so their contents
    /// never reach `infos`. `info(for:)` must still explain them via the standalone
    /// path rather than returning a misleading default.
    func testSafeSubtreesArePrunedButRemainExplainable() {
        let tree = makeHomeTree()
        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: tree.root)

        let blob = tree.caches.children.first!
        XCTAssertNil(analyzer.infos[blob.id], "contents of a safe directory should not be indexed")

        let info = analyzer.info(for: blob)
        XCTAssertEqual(info.tier, .regenerates, "standalone fallback must recover the tier from the path")
        XCTAssertEqual(info.category, .cache)
    }

    func testHotspotsSurfaceLargeSafeNodesInScoreOrder() {
        let tree = makeHomeTree()
        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: tree.root)

        let ids = analyzer.hotspots.map(\.node.id)
        XCTAssertTrue(ids.contains(tree.caches.id), "a 200 MB stale cache must be a hotspot")
        XCTAssertFalse(ids.contains(tree.doc.id), "personal documents are never hotspots")

        let scores = analyzer.hotspots.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >), "hotspots must be ranked by score")
        for spot in analyzer.hotspots {
            XCTAssertTrue(analyzer.info(for: spot.node).tier.isSafeReclaim)
            XCTAssertGreaterThanOrEqual(spot.depth, 1, "the scan root is never its own hotspot")
        }
    }

    /// Small safe items are not worth hoisting; the thresholds keep the ghost-row
    /// list meaningful.
    func testSmallSafeItemsAreNotHotspots() {
        let root = FileNode(id: makeID(), name: "/Users/tester", flags: [.directory], parent: nil)
        let library = dir("Library", in: root)
        let caches = dir("Caches", in: library, daysOld: 400)
        file("tiny.bin", in: caches, bytes: 1_000_000, daysOld: 400)

        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: root)
        XCTAssertFalse(analyzer.hotspots.map(\.node.id).contains(caches.id))
    }

    func testWhyLinesExplainTheRanking() {
        let tree = makeHomeTree()
        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: tree.root)

        let cacheWhy = analyzer.whyLine(for: tree.caches)
        XCTAssertTrue(cacheWhy.contains("Cache"), cacheWhy)
        XCTAssertTrue(cacheWhy.contains("frees"), cacheWhy)

        let installerWhy = analyzer.whyLine(for: tree.installer)
        XCTAssertTrue(installerWhy.contains("Installer"), installerWhy)

        let docWhy = analyzer.whyLine(for: tree.doc)
        XCTAssertTrue(docWhy.contains("review"), docWhy)
    }

    /// Protected items stay visible but must say plainly that DiskX will not
    /// delete them.
    func testProtectedItemsSayTheyAreNotDeletable() {
        let node = FileNode(id: makeID(), name: "/usr/lib/libfoo.dylib", flags: [],
                            modified: timestamp(daysOld: 30), accessed: timestamp(daysOld: 30),
                            parent: nil, allocatedSize: 4_000, logicalSize: 4_000)
        let analyzer = ReclaimAnalyzer()
        let info = analyzer.info(for: node)
        XCTAssertEqual(info.tier, .protected)
        XCTAssertEqual(info.safeReclaimBytes, 0)
        XCTAssertTrue(analyzer.whyLine(for: node).contains("not deletable"))
    }

    func testEmptyTreeAnalyzesCleanly() {
        let root = FileNode(id: makeID(), name: "/Users/tester", flags: [.directory], parent: nil)
        let analyzer = ReclaimAnalyzer()
        analyzer.analyze(root: root)
        XCTAssertEqual(analyzer.totalSafeReclaim, 0)
        XCTAssertTrue(analyzer.hotspots.isEmpty)
    }
}
