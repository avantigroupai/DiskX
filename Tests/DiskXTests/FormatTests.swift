import XCTest
@testable import DiskXCore

/// `Format.age` renders the "untouched 14 months" half of every WHY line, so its
/// bucket arithmetic is user-facing copy. Byte and count formatting delegate to
/// Foundation and are locale-dependent, so those are asserted on behaviour rather
/// than on exact strings — pinning "1 MB" would fail the suite on a non-English
/// machine without anything actually being broken.
final class FormatTests: XCTestCase {

    private func age(daysAgo: Double) -> String {
        Format.age(unixTime: Date().timeIntervalSince1970 - daysAgo * 86_400)
    }

    func testAgeBuckets() {
        XCTAssertEqual(age(daysAgo: 0.25), "today")
        XCTAssertEqual(age(daysAgo: 1.5), "yesterday")
        // Half-day offsets keep the assertions clear of the truncation boundary:
        // `age` floors the day count, and the microseconds that elapse between
        // building the timestamp and formatting it would turn an exact 10.0 into 9.
        XCTAssertEqual(age(daysAgo: 10.5), "10 days ago")
        XCTAssertEqual(age(daysAgo: 45), "1 month ago")
        XCTAssertEqual(age(daysAgo: 200), "6 months ago")
        XCTAssertEqual(age(daysAgo: 400), "1 year ago")
        XCTAssertEqual(age(daysAgo: 1_200), "3 years ago")
    }

    /// An unknown timestamp must render as an em dash, never as "today" — claiming
    /// a file was touched today when we do not know would be a lie in the WHY line.
    func testUnknownAgeRendersAsDash() {
        XCTAssertEqual(Format.age(unixTime: 0), "—")
        XCTAssertEqual(Format.ageDays(unixTime: 0), 0)
    }

    func testAgeDaysCountsForward() {
        XCTAssertEqual(Format.ageDays(unixTime: Date().timeIntervalSince1970 - 10 * 86_400),
                       10, accuracy: 0.01)
        // Timestamps in the future clamp to zero rather than going negative.
        XCTAssertEqual(Format.ageDays(unixTime: Date().timeIntervalSince1970 + 86_400), 0)
    }

    func testByteFormattingScalesAndStaysNonEmpty() {
        XCTAssertFalse(Format.bytes(0).isEmpty)
        XCTAssertNotEqual(Format.bytes(1_000_000), Format.bytes(2_000_000))
        // File-style counting is decimal, so a gigabyte must not render in megabytes.
        XCTAssertNotEqual(Format.bytes(1_000_000_000), Format.bytes(1_000_000))
    }

    func testNegativeBytesDoNotCrash() {
        // Undo subtracts sizes back out of the tree; a transient negative must format.
        XCTAssertFalse(Format.bytes(-1_000).isEmpty)
    }

    func testCountFormattingIsNonEmpty() {
        XCTAssertFalse(Format.count(0).isEmpty)
        XCTAssertFalse(Format.count(1_234_567).isEmpty)
        XCTAssertNotEqual(Format.count(1), Format.count(1_000))
    }
}
