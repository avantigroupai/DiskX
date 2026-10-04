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

    func testMinimalCoverDeduplicatesIdenticalNodes() throws {
        let nodeA = FileNode(id: 1, name: "a.txt", flags: [], parent: nil)
        let nodeB = FileNode(id: 2, name: "b.txt", flags: [], parent: nil)

        let cover = TrashEngine.minimalCover(of: [nodeA, nodeB, nodeA, nodeB, nodeA])
        XCTAssertEqual(cover.count, 2)
        XCTAssertEqual(cover.map(\.id), [1, 2], "Duplicates must be stripped while preserving order")
    }

    func testMinimalCoverDeduplicatesWithAncestors() throws {
        let parent = FileNode(id: 10, name: "parent", flags: [.directory], parent: nil)
        let child = FileNode(id: 11, name: "child", flags: [], parent: parent)
        parent.appendChild(child)

        let cover = TrashEngine.minimalCover(of: [child, parent, child, parent])
        XCTAssertEqual(cover.count, 1)
        XCTAssertEqual(cover.first?.id, 10, "Parent must cover child and redundant parent entries must be deduplicated")
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

    func testTrashMultipleNodesAndRestore() throws {
        let file1URL = tempDir.appendingPathComponent("file1.bin")
        let file2URL = tempDir.appendingPathComponent("file2.bin")
        try Data(repeating: 1, count: 20_000).write(to: file1URL)
        try Data(repeating: 2, count: 30_000).write(to: file2URL)

        let root = try scan(tempDir.path)
        let node1 = root.children.first { $0.name == "file1.bin" }!
        let node2 = root.children.first { $0.name == "file2.bin" }!

        let outcome = TrashEngine.trash(nodes: [node1, node2])
        XCTAssertEqual(outcome.successCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1URL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2URL.path))

        let trashedPath1 = outcome.results.first(where: { $0.nodeID == node1.id })?.trashedTo
        let trashedPath2 = outcome.results.first(where: { $0.nodeID == node2.id })?.trashedTo
        XCTAssertNotNil(trashedPath1)
        XCTAssertNotNil(trashedPath2)

        // Detach both from tree
        node1.detachFromTree()
        node2.detachFromTree()
        XCTAssertEqual(root.children.count, 0)
        XCTAssertEqual(root.fileCount, 0)

        // Restore both
        try FileManager.default.moveItem(atPath: trashedPath1!, toPath: file1URL.path)
        try FileManager.default.moveItem(atPath: trashedPath2!, toPath: file2URL.path)
        root.appendChild(node1)
        root.appendChild(node2)
        root.propagateSizes(allocated: node1.allocatedSize + node2.allocatedSize,
                            logical: node1.logicalSize + node2.logicalSize,
                            files: 2)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file1URL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2URL.path))
        XCTAssertEqual(root.fileCount, 2)
    }

    func testMultiItemCoverWithSeparateSubtrees() throws {
        let dirA = tempDir.appendingPathComponent("dirA")
        let dirB = tempDir.appendingPathComponent("dirB")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: dirA.appendingPathComponent("a1.bin"))
        try Data(repeating: 2, count: 500).write(to: dirA.appendingPathComponent("a2.bin"))
        try Data(repeating: 3, count: 500).write(to: dirB.appendingPathComponent("b1.bin"))

        let root = try scan(tempDir.path)
        let nodeA = root.children.first { $0.name == "dirA" }!
        let nodeA1 = nodeA.children.first { $0.name == "a1.bin" }!
        let nodeB = root.children.first { $0.name == "dirB" }!
        let nodeB1 = nodeB.children.first { $0.name == "b1.bin" }!

        // When dirA and a child of dirA are both in the list, minimalCover retains dirA
        // while also retaining separate subtree nodeB1
        let cover = TrashEngine.minimalCover(of: [nodeA1, nodeA, nodeB1])
        XCTAssertEqual(cover.count, 2)
        XCTAssertTrue(cover.contains(where: { $0.id == nodeA.id }))
        XCTAssertTrue(cover.contains(where: { $0.id == nodeB1.id }))
        XCTAssertFalse(cover.contains(where: { $0.id == nodeA1.id }))
    }
}

private final class Holder: @unchecked Sendable {
    var result: Result<FileNode, ScanError>?
}
