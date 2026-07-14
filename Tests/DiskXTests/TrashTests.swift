import XCTest
@testable import DiskXCore

final class TrashTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskXTrashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func scan(_ path: String) throws -> FileNode {
        let exp = expectation(description: "scan")
        let holder = Holder()
        let session = ScanSession(path: path) { result in
            holder.result = result
            exp.fulfill()
        }
        session.start()
        wait(for: [exp], timeout: 30)
        return try holder.result!.get()
    }

    func testMinimalCoverDropsNestedSelections() throws {
        try Data(repeating: 1, count: 1000).write(to: tempDir.appendingPathComponent("a.bin"))
        let sub = tempDir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1000).write(to: sub.appendingPathComponent("inner.bin"))

        let root = try scan(tempDir.path)
        let folder = root.children.first { $0.name == "folder" }!
        let inner = folder.children.first!
        let a = root.children.first { $0.name == "a.bin" }!

        let cover = TrashEngine.minimalCover(of: [inner, folder, a])
        XCTAssertEqual(Set(cover.map(\.id)), Set([folder.id, a.id]),
                       "nested child must be covered by its selected ancestor")
    }

    func testTrashAndRestoreRoundTrip() throws {
        let fileURL = tempDir.appendingPathComponent("victim.bin")
        try Data(repeating: 7, count: 50_000).write(to: fileURL)

        let root = try scan(tempDir.path)
        let victim = root.children.first { $0.name == "victim.bin" }!

        let outcome = TrashEngine.trash(nodes: [victim])
        XCTAssertEqual(outcome.successCount, 1, outcome.failures.first?.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let trashedPath = outcome.results[0].trashedTo
        XCTAssertNotNil(trashedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashedPath!))

        // Tree bookkeeping: detach subtracts sizes from ancestors.
        let before = root.allocatedSize
        victim.detachFromTree()
        XCTAssertEqual(root.children.count, 0)
        XCTAssertLessThan(root.allocatedSize, before)
        XCTAssertEqual(root.fileCount, 0)

        // Undo: move back from Trash, re-attach, sizes restored.
        try FileManager.default.moveItem(atPath: trashedPath!, toPath: fileURL.path)
        root.appendChild(victim)
        root.propagateSizes(allocated: victim.allocatedSize, logical: victim.logicalSize, files: victim.fileCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(root.allocatedSize, before)
        XCTAssertEqual(root.fileCount, 1)
    }

    func testTrashReportsFailuresHonestly() throws {
        let ghost = FileNode(id: 999, name: tempDir.appendingPathComponent("never-existed.bin").path,
                             flags: [], parent: nil, allocatedSize: 10, logicalSize: 10)
        let outcome = TrashEngine.trash(nodes: [ghost])
        XCTAssertEqual(outcome.successCount, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertNotNil(outcome.failures[0].error)
    }
}

private final class Holder: @unchecked Sendable {
    var result: Result<FileNode, ScanError>?
}
