import Foundation

/// Semantic category of a file/folder — drives the reclaimability intelligence
/// and the monochrome iconography. Categories are intentionally coarse.
public enum FileCategory: String, CaseIterable, Sendable {
    case cache = "Caches"
    case buildArtifact = "Build Artifacts"
    case installer = "Installers & Archives"
    case log = "Logs"
    case trash = "Trash"
    case backup = "Backups & Images"
    case media = "Media"
    case document = "Documents"
    case code = "Code"
    case application = "Applications"
    case system = "System"
    case other = "Other"

    /// How safe it typically is to delete items in this category (0 = never, 1 = regenerable).
    public var disposability: Double {
        switch self {
        case .cache: return 1.0
        case .trash: return 1.0
        case .log: return 0.9
        case .buildArtifact: return 0.85
        case .installer: return 0.8
        case .backup: return 0.4
        case .media: return 0.25
        case .application: return 0.3
        case .code: return 0.1
        case .document: return 0.05
        case .system: return 0.0
        case .other: return 0.15
        }
    }

    /// SF Symbol name — monochrome glyphs only.
    public var symbolName: String {
        switch self {
        case .cache: return "arrow.triangle.2.circlepath"
        case .buildArtifact: return "hammer"
        case .installer: return "shippingbox"
        case .log: return "doc.text"
        case .trash: return "trash"
        case .backup: return "externaldrive"
        case .media: return "photo.on.rectangle"
        case .document: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .application: return "app"
        case .system: return "gearshape"
        case .other: return "questionmark.square.dashed"
        }
    }

    // MARK: - Classification tables

    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "webm", "mts", "m2ts",
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg",
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "raw", "cr2", "cr3",
        "nef", "arw", "dng", "psd", "ai", "sketch", "webp", "bmp", "svg",
    ]

    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers",
        "txt", "rtf", "md", "epub", "csv", "odt",
    ]

    static let installerExtensions: Set<String> = [
        "dmg", "pkg", "iso", "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "xip", "mpkg", "war", "deb", "rpm",
    ]

    static let codeExtensions: Set<String> = [
        "swift", "c", "h", "cpp", "hpp", "m", "mm", "js", "ts", "tsx", "jsx", "py",
        "rb", "go", "rs", "java", "kt", "cs", "php", "sh", "pl", "sql", "json",
        "yaml", "yml", "toml", "xml", "html", "css", "scss",
    ]

    static let logExtensions: Set<String> = ["log", "crash", "ips", "diag", "spin", "hang"]

    static let backupExtensions: Set<String> = ["sparsebundle", "sparseimage", "backupbundle", "ipsw", "vdi", "vmdk", "qcow2", "ova"]

    /// Directory names whose entire contents are build artifacts.
    static let buildArtifactDirNames: Set<String> = [
        "node_modules", "deriveddata", ".build", "build", "target", "dist", ".gradle",
        "pods", ".venv", "venv", "__pycache__", ".tox", ".next", ".nuxt", ".turbo",
        ".cache", "cmake-build-debug", "cmake-build-release", ".parcel-cache",
    ]

    /// Path substrings that mark caches.
    static let cachePathMarkers: [String] = [
        "/library/caches/", "/.cache/", "/cache/", "/caches/",
    ]

    static let systemPathPrefixes: [String] = [
        "/system/", "/usr/", "/bin/", "/sbin/", "/private/var/db/", "/library/apple/",
    ]

    /// True when a directory of this category makes every descendant the same
    /// category (a file inside node_modules is a build artifact, full stop).
    public var inheritsToChildren: Bool {
        switch self {
        case .cache, .buildArtifact, .trash, .application, .system, .backup, .log:
            return true
        default:
            return false
        }
    }

    private static let backupDirNames: Set<String> = ["backups.backupdb", "mobilesync"]

    /// O(1) per-node classification for the analyzer's tree walk: name/extension
    /// table lookups plus the parent's inherited context — never scans the path.
    /// Semantically equivalent to `classify` for nodes deeper than the shallow
    /// levels (where the analyzer still uses the full version).
    public static func classifyFast(name: String, isDirectory: Bool, inherited: FileCategory?) -> FileCategory {
        if let inherited, inherited.inheritsToChildren {
            return inherited
        }
        let lowerName = name.lowercased()
        if isDirectory {
            if buildArtifactDirNames.contains(lowerName) { return .buildArtifact }
            if lowerName == "caches" || lowerName == "cache" { return .cache }
            if lowerName == ".trash" { return .trash }
            if lowerName == "logs" { return .log }
            if backupDirNames.contains(lowerName) { return .backup }
            if lowerName.hasSuffix(".app") { return .application }
            if lowerName.hasSuffix(".photoslibrary") || lowerName.hasSuffix(".musiclibrary") { return .media }
            return .other
        }
        let ext = (lowerName as NSString).pathExtension
        if !ext.isEmpty {
            if mediaExtensions.contains(ext) { return .media }
            if documentExtensions.contains(ext) { return .document }
            if installerExtensions.contains(ext) { return .installer }
            if logExtensions.contains(ext) { return .log }
            if backupExtensions.contains(ext) { return .backup }
            if codeExtensions.contains(ext) { return .code }
        }
        return .other
    }

    /// Precomputed "/name/" markers — interpolating them per call was a hot spot.
    private static let buildArtifactPathMarkers: [String] = buildArtifactDirNames.map { "/\($0)/" }

    /// Locale-independent substring check; Foundation's default `contains` does
    /// Unicode normalization and is far too slow for per-node use.
    private static func literallyContains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .literal) != nil
    }

    /// Classify a node by name, extension, and full path (lowercased internally).
    public static func classify(name: String, path: String, isDirectory: Bool) -> FileCategory {
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()

        if literallyContains(lowerPath, "/.trash/") || lowerName == ".trash" { return .trash }

        for marker in cachePathMarkers where literallyContains(lowerPath, marker) { return .cache }
        if lowerName == "caches" && isDirectory { return .cache }

        if isDirectory {
            if buildArtifactDirNames.contains(lowerName) { return .buildArtifact }
            if lowerName.hasSuffix(".app") { return .application }
            if lowerName.hasSuffix(".photoslibrary") || lowerName.hasSuffix(".musiclibrary") { return .media }
        }

        // Inherited context: anything inside a build-artifact dir is a build artifact.
        for marker in buildArtifactPathMarkers where literallyContains(lowerPath, marker) {
            return .buildArtifact
        }
        if literallyContains(lowerPath, "/deriveddata/") || literallyContains(lowerPath, "/xcode/ios devicesupport/") {
            return .buildArtifact
        }
        if literallyContains(lowerPath, ".app/") { return .application }

        for prefix in systemPathPrefixes where lowerPath.hasPrefix(prefix) { return .system }

        let ext = (lowerName as NSString).pathExtension
        if !ext.isEmpty {
            if mediaExtensions.contains(ext) { return .media }
            if documentExtensions.contains(ext) { return .document }
            if installerExtensions.contains(ext) { return .installer }
            if logExtensions.contains(ext) { return .log }
            if backupExtensions.contains(ext) { return .backup }
            if codeExtensions.contains(ext) { return .code }
        }
        if literallyContains(lowerPath, "/library/logs/") || literallyContains(lowerPath, "/var/log/") { return .log }
        if literallyContains(lowerPath, "/backups.backupdb/") || literallyContains(lowerPath, "/mobilesync/backup/") { return .backup }
        return .other
    }
}
