import XCTest
@testable import DiskXCore

/// Regression tests for the findings of the adversarial security audit.
/// Each test corresponds to a defect that was confirmed reproducible.
final class SecurityTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskXSecurity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func scan(_ path: String) throws -> FileNode {
        let exp = expectation(description: "scan")
        let holder = Holder()
        let session = ScanSession(path: path) { holder.result = $0; exp.fulfill() }
        session.start()
        wait(for: [exp], timeout: 60)
        return try holder.result!.get()
    }

    /// Creates a sparse file of `size` logical bytes occupying no blocks.
    private func makeSparse(_ relative: String, size: off_t) throws {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0, "could not create \(relative)")
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, size), 0, "ftruncate failed for \(relative)")
    }

    // MARK: - Saturating arithmetic

    func testSaturatingAddDoesNotTrap() {
        XCTAssertEqual(SaturatingMath.add(.max, 1), .max)
        XCTAssertEqual(SaturatingMath.add(.max, .max), .max)
        XCTAssertEqual(SaturatingMath.add(.min, -1), .min)
        XCTAssertEqual(SaturatingMath.add(5, 7), 12)
    }

    func testSaturatingNegateHandlesInt64Min() {
        XCTAssertEqual(SaturatingMath.negate(.min), .max)   // -Int64.min would trap
        XCTAssertEqual(SaturatingMath.negate(42), -42)
    }

    func testSanitizeRejectsNegativeAndAbsurdSizes() {
        XCTAssertEqual(SaturatingMath.sanitizeSize(-1), 0)
        XCTAssertEqual(SaturatingMath.sanitizeSize(.min), 0)
        XCTAssertEqual(SaturatingMath.sanitizeSize(.max), 0)
        XCTAssertEqual(SaturatingMath.sanitizeSize(4096), 4096)
    }

    /// The audit reproduced a SIGTRAP (exit 133) by scanning a directory of sparse
    /// files whose logical sizes sum past Int64.max. The scan must now complete.
    func testScanningHugeSparseFilesDoesNotCrash() throws {
        let huge: off_t = 1 << 53          // 8 PiB, occupies zero blocks
        for i in 0..<1200 {
            try makeSparse("sparse/f\(i).bin", size: huge)
        }
        let root = try scan(tempDir.path)
        XCTAssertGreaterThan(root.fileCount, 0)
        // Reaching this line at all is the assertion: the old code trapped.
        XCTAssertGreaterThanOrEqual(root.logicalSize, 0)
    }

    /// The same payload split across subdirectories overflowed in propagateSizes
    /// rather than the per-directory batch, so both paths need to saturate.
    func testSparseFilesSplitAcrossDirectoriesDoNotCrash() throws {
        let huge: off_t = 1 << 53
        for i in 0..<700 { try makeSparse("a/f\(i).bin", size: huge) }
        for i in 0..<700 { try makeSparse("b/f\(i).bin", size: huge) }
        let root = try scan(tempDir.path)
        XCTAssertGreaterThanOrEqual(root.logicalSize, 0)
    }

    // MARK: - Deletion safety

    func testTrashRefusesWhenIdentityChanged() throws {
        let victim = tempDir.appendingPathComponent("victim.bin")
        try Data(repeating: 7, count: 1024).write(to: victim)
        let root = try scan(tempDir.path)
        let node = root.children.first { $0.name == "victim.bin" }!

        // Capture identity, then replace the file with a different one.
        let stale = FileIdentity.capture(path: node.path)
        XCTAssertNotNil(stale)
        try FileManager.default.removeItem(at: victim)
        try Data(repeating: 9, count: 2048).write(to: victim)

        let outcome = TrashEngine.trash(nodes: [node], expecting: [node.id: stale!])
        XCTAssertEqual(outcome.successCount, 0, "must refuse to delete a swapped path")
        XCTAssertEqual(outcome.bytesFreed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path),
                      "the replacement file must survive")
    }

    func testTrashSucceedsWhenIdentityMatches() throws {
        let victim = tempDir.appendingPathComponent("ok.bin")
        try Data(repeating: 3, count: 4096).write(to: victim)
        let root = try scan(tempDir.path)
        let node = root.children.first { $0.name == "ok.bin" }!
        let identity = FileIdentity.capture(path: node.path)!

        let outcome = TrashEngine.trash(nodes: [node], expecting: [node.id: identity])
        XCTAssertEqual(outcome.successCount, 1, outcome.failures.first?.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(outcome.results.first?.nodeID, node.id)
        if let trashed = outcome.results.first?.trashedTo {
            try? FileManager.default.removeItem(atPath: trashed)
        }
    }

    func testTrashReportsVanishedFileAsFailure() throws {
        let ghost = FileNode(id: 4242,
                             name: tempDir.appendingPathComponent("never.bin").path,
                             flags: [], parent: nil, allocatedSize: 10, logicalSize: 10)
        let outcome = TrashEngine.trash(nodes: [ghost])
        XCTAssertEqual(outcome.successCount, 0)
        XCTAssertEqual(outcome.bytesFreed, 0, "must not book bytes it did not free")
        XCTAssertNotNil(outcome.failures.first?.error)
    }

    // MARK: - Protected-tier gating

    /// The protected path check used to be skipped below depth 2, so deep system
    /// paths were offered for deletion as "Yours — review".
    func testDeepSystemPathsStayProtected() {
        let analyzer = ReclaimAnalyzer()
        let root = FileNode(id: 1, name: "/", flags: [.directory], parent: nil)
        let priv = FileNode(id: 2, name: "private", flags: [.directory], parent: root)
        root.appendChild(priv)
        let varDir = FileNode(id: 3, name: "var", flags: [.directory], parent: priv)
        priv.appendChild(varDir)
        let db = FileNode(id: 4, name: "db", flags: [.directory], parent: varDir)
        varDir.appendChild(db)
        // Several levels below the old shallow limit.
        var parent = db
        for i in 0..<4 {
            let child = FileNode(id: UInt64(10 + i), name: "sub\(i)", flags: [.directory], parent: parent)
            parent.appendChild(child)
            parent = child
        }
        let leaf = FileNode(id: 99, name: "secret.db", flags: [], parent: parent,
                            allocatedSize: 1_000_000, logicalSize: 1_000_000)
        parent.appendChild(leaf)

        analyzer.analyze(root: root)
        XCTAssertEqual(analyzer.info(for: db).tier, .protected, "/private/var/db must be protected")
        XCTAssertEqual(analyzer.info(for: leaf).tier, .protected,
                       "everything under a protected directory must stay protected")
        XCTAssertFalse(analyzer.info(for: leaf).tier.isSafeReclaim)
    }
}

private final class Holder: @unchecked Sendable {
    var result: Result<FileNode, ScanError>?
}
