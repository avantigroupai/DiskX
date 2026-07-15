import XCTest
@testable import DiskXCore

final class ScannerTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskXTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFile(_ relative: String, size: Int) throws {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = Data(repeating: 0xAB, count: size)   // non-zero so APFS can't hole-punch
        try data.write(to: url)
    }

    private func scan(_ path: String) throws -> FileNode {
        let exp = expectation(description: "scan")
        let holder = ResultHolder()
        let session = ScanSession(path: path) { result in
            holder.result = result
            exp.fulfill()
        }
        session.start()
        wait(for: [exp], timeout: 30)
        return try holder.result!.get()
    }

    func testScanCountsAndSizes() throws {
        try makeFile("a/one.bin", size: 100_000)
        try makeFile("a/two.bin", size: 50_000)
        try makeFile("a/sub/three.bin", size: 25_000)
        try makeFile("b/four.bin", size: 10_000)
        try makeFile("five.bin", size: 5_000)

        let root = try scan(tempDir.path)
        XCTAssertEqual(root.fileCount, 5)
        XCTAssertEqual(root.logicalSize, 190_000)
        XCTAssertGreaterThanOrEqual(root.allocatedSize, 190_000) // allocation rounds up to blocks

        // Children sorted by size descending after scan.
        let names = root.children.map(\.name)
        XCTAssertEqual(names.first, "a")

        let a = root.children.first { $0.name == "a" }!
        XCTAssertEqual(a.fileCount, 3)
        XCTAssertEqual(a.logicalSize, 175_000)
        XCTAssertTrue(a.scanComplete)

        // Path reconstruction round-trips.
        let sub = a.children.first { $0.name == "sub" }!
        let three = sub.children.first!
        XCTAssertTrue(FileManager.default.fileExists(atPath: three.path))
    }

    func testHardLinksCountedOnce() throws {
        try makeFile("orig.bin", size: 80_000)
        let src = tempDir.appendingPathComponent("orig.bin").path
        let dst = tempDir.appendingPathComponent("hardlink.bin").path
        XCTAssertEqual(link(src, dst), 0, "hardlink creation failed")

        let root = try scan(tempDir.path)
        XCTAssertEqual(root.fileCount, 2)
        XCTAssertEqual(root.logicalSize, 80_000, "hard-linked size must be counted once")
    }

    func testSymlinksNotFollowed() throws {
        try makeFile("real/data.bin", size: 40_000)
        let linkPath = tempDir.appendingPathComponent("loop").path
        XCTAssertEqual(symlink(tempDir.path, linkPath), 0)

        let root = try scan(tempDir.path)
        // The symlink is listed but not traversed: only 1 real file + the link node.
        XCTAssertEqual(root.logicalSize, Int64(40_000) + root.children.first { $0.name == "loop" }!.logicalSize)
        XCTAssertEqual(root.fileCount, 2)
    }

    func testLargestFiles() throws {
        try makeFile("x/big.bin", size: 90_000)
        try makeFile("y/small.bin", size: 1_000)
        try makeFile("mid.bin", size: 30_000)

        let root = try scan(tempDir.path)
        let top = root.largestFiles(limit: 2)
        XCTAssertEqual(top.map(\.name), ["big.bin", "mid.bin"])
    }

    func testMissingRootFails() {
        let exp = expectation(description: "fail")
        let session = ScanSession(path: "/nonexistent-diskx-test-path") { result in
            if case .failure = result { exp.fulfill() }
        }
        session.start()
        wait(for: [exp], timeout: 5)
    }
}

private final class ResultHolder: @unchecked Sendable {
    var result: Result<FileNode, ScanError>?
}

final class TreemapTests: XCTestCase {
    func testTilesFillRectExactly() {
        let items = (1...20).map { TreemapLayout.Item(id: UInt64($0), weight: Double($0 * $0)) }
            .sorted { $0.weight > $1.weight }
        let rect = CGRect(x: 0, y: 0, width: 800, height: 500)
        let placements = TreemapLayout.layout(items: items, in: rect)

        XCTAssertEqual(placements.count, 20)
        let totalArea = placements.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(totalArea, Double(rect.width * rect.height), accuracy: 1.0)

        for p in placements {
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(p.rect.insetBy(dx: 0.01, dy: 0.01)),
                          "tile \(p.id) escapes container")
        }
    }

    func testAreasProportionalToWeights() {
        let items = [TreemapLayout.Item(id: 1, weight: 300),
                     TreemapLayout.Item(id: 2, weight: 100)]
        let placements = TreemapLayout.layout(items: items, in: CGRect(x: 0, y: 0, width: 400, height: 100))
        let a1 = placements.first { $0.id == 1 }!.rect
        let a2 = placements.first { $0.id == 2 }!.rect
        XCTAssertEqual(Double(a1.width * a1.height) / Double(a2.width * a2.height), 3.0, accuracy: 0.01)
    }

    func testZeroWeightsSkipped() {
        let items = [TreemapLayout.Item(id: 1, weight: 10),
                     TreemapLayout.Item(id: 2, weight: 0)]
        let placements = TreemapLayout.layout(items: items, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(placements.count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(TreemapLayout.layout(items: [], in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }
}

final class CategoryTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(FileCategory.classify(name: "chunk.js", path: "/users/x/proj/node_modules/react/chunk.js", isDirectory: false), .buildArtifact)
        XCTAssertEqual(FileCategory.classify(name: "data.db", path: "/users/x/library/caches/app/data.db", isDirectory: false), .cache)
        XCTAssertEqual(FileCategory.classify(name: "Xcode.dmg", path: "/users/x/downloads/Xcode.dmg", isDirectory: false), .installer)
        XCTAssertEqual(FileCategory.classify(name: "movie.mkv", path: "/users/x/movies/movie.mkv", isDirectory: false), .media)
        XCTAssertEqual(FileCategory.classify(name: "report.pdf", path: "/users/x/documents/report.pdf", isDirectory: false), .document)
        XCTAssertEqual(FileCategory.classify(name: "node_modules", path: "/users/x/proj/node_modules", isDirectory: true), .buildArtifact)
        XCTAssertEqual(FileCategory.classify(name: "system.log", path: "/private/var/log/system.log", isDirectory: false), .log)
    }

    /// The analyzer's hot path uses classifyFast with inherited context instead of
    /// scanning the full path. It must agree with the full classifier for the cases
    /// that matter.
    func testFastClassifierInheritsContext() {
        // A file deep inside node_modules inherits buildArtifact without a path scan.
        XCTAssertEqual(FileCategory.classifyFast(name: "chunk.js", isDirectory: false, inherited: .buildArtifact), .buildArtifact)
        XCTAssertEqual(FileCategory.classifyFast(name: "blob.bin", isDirectory: false, inherited: .cache), .cache)
        // Directory names still classify without inheritance.
        XCTAssertEqual(FileCategory.classifyFast(name: "node_modules", isDirectory: true, inherited: nil), .buildArtifact)
        XCTAssertEqual(FileCategory.classifyFast(name: "Caches", isDirectory: true, inherited: nil), .cache)
        // Extensions classify by name alone.
        XCTAssertEqual(FileCategory.classifyFast(name: "movie.mkv", isDirectory: false, inherited: nil), .media)
        XCTAssertEqual(FileCategory.classifyFast(name: "Xcode.dmg", isDirectory: false, inherited: nil), .installer)
        // Non-inheriting parents (media/document/other) don't drag children along.
        XCTAssertEqual(FileCategory.classifyFast(name: "notes.txt", isDirectory: false, inherited: .media), .document)
        // Inheriting categories are marked as such; leaf categories are not.
        XCTAssertTrue(FileCategory.buildArtifact.inheritsToChildren)
        XCTAssertTrue(FileCategory.cache.inheritsToChildren)
        XCTAssertFalse(FileCategory.media.inheritsToChildren)
        XCTAssertFalse(FileCategory.document.inheritsToChildren)
    }
}
