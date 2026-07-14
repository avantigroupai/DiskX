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

    /// Classify a node by name, extension, and full path (lowercased internally).
    public static func classify(name: String, path: String, isDirectory: Bool) -> FileCategory {
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()

        if lowerPath.contains("/.trash/") || lowerName == ".trash" { return .trash }

        for marker in cachePathMarkers where lowerPath.contains(marker) { return .cache }
        if lowerName == "caches" && isDirectory { return .cache }

        if isDirectory {
            if buildArtifactDirNames.contains(lowerName) { return .buildArtifact }
            if lowerName.hasSuffix(".app") { return .application }
            if lowerName.hasSuffix(".photoslibrary") || lowerName.hasSuffix(".musiclibrary") { return .media }
        }

        // Inherited context: anything inside a build-artifact dir is a build artifact.
        for dirName in buildArtifactDirNames {
            if lowerPath.contains("/\(dirName)/") { return .buildArtifact }
        }
        if lowerPath.contains("/deriveddata/") || lowerPath.contains("/xcode/ios devicesupport/") {
            return .buildArtifact
        }
        if lowerPath.contains(".app/") { return .application }

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
        if lowerPath.contains("/library/logs/") || lowerPath.contains("/var/log/") { return .log }
        if lowerPath.contains("/backups.backupdb/") || lowerPath.contains("/mobilesync/backup/") { return .backup }
        return .other
    }
}
