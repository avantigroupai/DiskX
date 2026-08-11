import Foundation

/// Saturating integer arithmetic for filesystem-reported sizes.
///
/// Sizes come from the kernel via `getattrlistbulk` and are ultimately controlled
/// by whatever filesystem is mounted. Sparse files legitimately report petabyte
/// logical sizes while occupying no blocks, and a hostile SMB/NFS/FUSE server can
/// report anything at all — including `Int64.max` or a negative `off_t`.
///
/// Swift's `+=` traps on overflow, so summing such values crashed the whole app
/// (SIGTRAP) mid-scan. Aggregates therefore saturate instead of trapping: a wrong
/// total is a cosmetic problem, a dead process is a denial of service.
public enum SaturatingMath {
    /// Largest file size we accept from the filesystem before treating the value
    /// as garbage. APFS caps a single file at 2^63-1 but practical files are far
    /// below 2^53 (8 PiB), which is also the largest sparse size APFS will create.
    public static let maxSaneFileSize: Int64 = 1 << 53

    /// Clamps a filesystem-reported size into a sane, non-negative range.
    /// Negative and absurd values become 0 rather than poisoning every ancestor total.
    @inline(__always)
    public static func sanitizeSize(_ value: Int64) -> Int64 {
        (value > 0 && value <= maxSaneFileSize) ? value : 0
    }

    /// Addition that saturates at the Int64 bounds instead of trapping.
    @inline(__always)
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    /// Negation that cannot trap (`-Int64.min` overflows).
    @inline(__always)
    public static func negate(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}
