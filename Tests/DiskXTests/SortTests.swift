import XCTest
@testable import DiskXCore

final class SortTests: XCTestCase {
    private let fixedNow: TimeInterval = 1_700_000_000

    private func makeNode(
        id: UInt64,
        name: String,
        modified: TimeInterval = 0,
        accessed: TimeInterval = 0,
        allocatedSize: Int64 = 1000,
        fileCount: Int64 = 1
    ) -> FileNode {
        FileNode(
            id: id,
            name: name,
            flags: [],
            modified: modified,
            accessed: accessed,
            parent: nil,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize
        )
    }

    func testSortModeMetadata() {
        let cases = SortMode.allCases
        XCTAssertEqual(cases.count, 6)
        XCTAssertEqual(cases.map(\.rawValue), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(cases.map(\.label), ["Reclaim", "Size", "Untouched", "Forgotten", "Files", "Name"])
        XCTAssertEqual(SortMode.untouched.symbolName, "clock")
    }

    func testUntouchedSortDescendingLongestFirst() {
        let node3Years = makeNode(id: 1, name: "old_3y.txt", modified: fixedNow - 3 * 365 * 86_400)
        let node180d = makeNode(id: 2, name: "mid_180d.txt", modified: fixedNow - 180 * 86_400)
        let node1d = makeNode(id: 3, name: "recent_1d.txt", modified: fixedNow - 86_400)
        let node1h = makeNode(id: 4, name: "fresh_1h.txt", modified: fixedNow - 3_600)

        let nodes = [node1d, node3Years, node1h, node180d]
        let sorted = FileNodeSorter.sort(nodes, by: .untouched, reversed: false, now: fixedNow)

        XCTAssertEqual(sorted.map(\.name), ["old_3y.txt", "mid_180d.txt", "recent_1d.txt", "fresh_1h.txt"],
                       "Descending untouched sort must put files untouched the longest first")
    }

    func testUntouchedSortAscendingShortestFirst() {
        let node3Years = makeNode(id: 1, name: "old_3y.txt", modified: fixedNow - 3 * 365 * 86_400)
        let node180d = makeNode(id: 2, name: "mid_180d.txt", modified: fixedNow - 180 * 86_400)
        let node1d = makeNode(id: 3, name: "recent_1d.txt", modified: fixedNow - 86_400)
        let node1h = makeNode(id: 4, name: "fresh_1h.txt", modified: fixedNow - 3_600)

        let nodes = [node1d, node3Years, node1h, node180d]
        let sorted = FileNodeSorter.sort(nodes, by: .untouched, reversed: true, now: fixedNow)

        XCTAssertEqual(sorted.map(\.name), ["fresh_1h.txt", "recent_1d.txt", "mid_180d.txt", "old_3y.txt"],
                       "Ascending untouched sort must put files untouched the shortest (freshest) first")
    }

    func testUntouchedSortUsesFresherOfModifiedAndAccessed() {
        // fileA was modified 100 days ago, but accessed 2 days ago -> lastTouched is 2 days ago
        let fileA = makeNode(id: 1, name: "fileA.txt", modified: fixedNow - 100 * 86_400, accessed: fixedNow - 2 * 86_400)
        // fileB was modified 10 days ago, and never accessed -> lastTouched is 10 days ago
        let fileB = makeNode(id: 2, name: "fileB.txt", modified: fixedNow - 10 * 86_400, accessed: 0)

        // Longest untouched first: fileB (10 days untouched) should come before fileA (2 days untouched)
        let desc = FileNodeSorter.sort([fileA, fileB], by: .untouched, reversed: false, now: fixedNow)
        XCTAssertEqual(desc.map(\.name), ["fileB.txt", "fileA.txt"])

        // Shortest untouched first: fileA (2 days untouched) should come before fileB (10 days untouched)
        let asc = FileNodeSorter.sort([fileA, fileB], by: .untouched, reversed: true, now: fixedNow)
        XCTAssertEqual(asc.map(\.name), ["fileA.txt", "fileB.txt"])
    }

    func testUntouchedSortUnknownTimestampsAtBottom() {
        let nodeKnownOld = makeNode(id: 1, name: "known_old.txt", modified: fixedNow - 300 * 86_400)
        let nodeKnownNew = makeNode(id: 2, name: "known_new.txt", modified: fixedNow - 10 * 86_400)
        let nodeUnknown = makeNode(id: 3, name: "unknown.txt", modified: 0, accessed: 0)

        let desc = FileNodeSorter.sort([nodeUnknown, nodeKnownNew, nodeKnownOld], by: .untouched, reversed: false, now: fixedNow)
        XCTAssertEqual(desc.map(\.name), ["known_old.txt", "known_new.txt", "unknown.txt"],
                       "Unknown timestamps must sink to the bottom in descending untouched sort")

        let asc = FileNodeSorter.sort([nodeUnknown, nodeKnownOld, nodeKnownNew], by: .untouched, reversed: true, now: fixedNow)
        XCTAssertEqual(asc.map(\.name), ["known_new.txt", "known_old.txt", "unknown.txt"],
                       "Unknown timestamps must sink to the bottom in ascending untouched sort")
    }

    func testUntouchedSortTieBreakers() {
        let sameTime = fixedNow - 10 * 86_400
        let bigFile = makeNode(id: 1, name: "b_big.txt", modified: sameTime, allocatedSize: 50_000)
        let smallFileA = makeNode(id: 2, name: "a_small.txt", modified: sameTime, allocatedSize: 5_000)
        let smallFileB = makeNode(id: 3, name: "b_small.txt", modified: sameTime, allocatedSize: 5_000)

        let desc = FileNodeSorter.sort([smallFileB, bigFile, smallFileA], by: .untouched, reversed: false, now: fixedNow)
        XCTAssertEqual(desc.map(\.name), ["b_big.txt", "a_small.txt", "b_small.txt"])

        let asc = FileNodeSorter.sort([smallFileB, bigFile, smallFileA], by: .untouched, reversed: true, now: fixedNow)
        XCTAssertEqual(asc.map(\.name), ["b_small.txt", "a_small.txt", "b_big.txt"])
    }

    func testSizeSortDescendingAndAscending() {
        let a = makeNode(id: 1, name: "a", allocatedSize: 100)
        let b = makeNode(id: 2, name: "b", allocatedSize: 300)
        let c = makeNode(id: 3, name: "c", allocatedSize: 200)

        let desc = FileNodeSorter.sort([a, b, c], by: .size, reversed: false)
        XCTAssertEqual(desc.map(\.name), ["b", "c", "a"])

        let asc = FileNodeSorter.sort([a, b, c], by: .size, reversed: true)
        XCTAssertEqual(asc.map(\.name), ["a", "c", "b"])
    }

    func testCountSortDescendingAndAscending() {
        let a = makeNode(id: 1, name: "a")
        a.propagateSizes(allocated: 0, logical: 0, files: 10)
        let b = makeNode(id: 2, name: "b")
        b.propagateSizes(allocated: 0, logical: 0, files: 50)
        let c = makeNode(id: 3, name: "c")
        c.propagateSizes(allocated: 0, logical: 0, files: 25)

        let desc = FileNodeSorter.sort([a, b, c], by: .count, reversed: false)
        XCTAssertEqual(desc.map(\.name), ["b", "c", "a"])

        let asc = FileNodeSorter.sort([a, b, c], by: .count, reversed: true)
        XCTAssertEqual(asc.map(\.name), ["a", "c", "b"])
    }

    func testNameSortAscendingAndDescending() {
        let a = makeNode(id: 1, name: "alpha")
        let b = makeNode(id: 2, name: "beta")
        let c = makeNode(id: 3, name: "gamma")

        let asc = FileNodeSorter.sort([c, a, b], by: .name, reversed: false)
        XCTAssertEqual(asc.map(\.name), ["alpha", "beta", "gamma"])

        let desc = FileNodeSorter.sort([c, a, b], by: .name, reversed: true)
        XCTAssertEqual(desc.map(\.name), ["gamma", "beta", "alpha"])
    }
}
