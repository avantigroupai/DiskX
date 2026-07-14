import Foundation
import Darwin
import os

public struct ScanProgress: Sendable {
    public init() {}
    public var filesScanned: Int64 = 0
    public var dirsScanned: Int64 = 0
    public var bytesFound: Int64 = 0
    public var deniedDirs: Int64 = 0
    public var currentPath: String = ""
    public var finished: Bool = false
}

public enum ScanError: Error, LocalizedError {
    case cannotOpenRoot(String, errno: Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotOpenRoot(let path, let err):
            let hint = (err == EACCES || err == EPERM)
                ? " DiskX may need Full Disk Access (System Settings → Privacy & Security)."
                : ""
            return "Could not open \(path): \(String(cString: strerror(err))).\(hint)"
        case .cancelled:
            return "Scan cancelled."
        }
    }
}

/// One scan of a directory tree. Create, call `start`, poll `progress`, read `root` when done.
///
/// Uses `getattrlistbulk(2)` — the bulk enumeration syscall Finder uses — with a
/// work-stealing pool of workers, one buffer per worker. This is the fastest
/// userland directory walk available on APFS.
public final class ScanSession: @unchecked Sendable {
    private struct Job {
        let node: FileNode
        let path: String
    }

    // Attribute constants from <sys/attr.h>, declared locally as UInt32 to avoid
    // sign-conversion issues with the imported macros.
    private static let CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
    private static let CMN_ERROR: UInt32 = 0x2000_0000
    private static let CMN_NAME: UInt32 = 0x0000_0001
    private static let CMN_OBJTYPE: UInt32 = 0x0000_0008
    private static let CMN_MODTIME: UInt32 = 0x0000_0400
    private static let CMN_ACCTIME: UInt32 = 0x0000_1000
    private static let CMN_FILEID: UInt32 = 0x0200_0000
    private static let FILE_LINKCOUNT: UInt32 = 0x0000_0001
    private static let FILE_TOTALSIZE: UInt32 = 0x0000_0002
    private static let FILE_ALLOCSIZE: UInt32 = 0x0000_0004

    private static let VREG: UInt32 = 1
    private static let VDIR: UInt32 = 2
    private static let VLNK: UInt32 = 5

    /// Bundle-ish directory extensions we don't descend into visually (still sized fully).
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "xcarchive", "photoslibrary", "musiclibrary",
        "tvlibrary", "fcpbundle", "imovielibrary", "aplibrary", "plugin", "kext",
        "qlgenerator", "xpc", "prefpane", "appex", "docset", "playground",
        "xcodeproj", "xcworkspace", "pkpass", "scptd", "lproj",
    ]

    /// Paths never descended into when scanning system roots (other volumes, VM, autofs).
    static let systemSkipPaths: Set<String> = [
        "/Volumes", "/dev", "/net", "/home",
        "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
        "/System/Volumes/Recovery", "/System/Volumes/Hardware", "/System/Volumes/iSCPreboot",
        "/System/Volumes/xarts", "/System/Volumes/Data/home",
        "/private/var/vm",
    ]

    public let rootPath: String
    public private(set) var root: FileNode?

    private let cond = NSCondition()
    private var pending: [Job] = []
    private var outstanding: Int = 0
    private var cancelled = false

    private let progressLock = OSAllocatedUnfairLock(initialState: ScanProgress())
    private let hardlinkLock = OSAllocatedUnfairLock(initialState: Set<UInt64>())
    private let idCounter = OSAllocatedUnfairLock(initialState: UInt64(0))

    private let workerCount: Int
    private let onCompletion: @Sendable (Result<FileNode, ScanError>) -> Void
    private let startedAt = Date()
    public private(set) var duration: TimeInterval = 0

    public init(path: String,
                workerCount: Int = max(4, ProcessInfo.processInfo.activeProcessorCount),
                completion: @escaping @Sendable (Result<FileNode, ScanError>) -> Void) {
        // Resolve symlinks so node paths reconstruct correctly (/tmp → /private/tmp).
        let resolved = (path as NSString).resolvingSymlinksInPath
        self.rootPath = resolved.isEmpty ? path : resolved
        self.workerCount = workerCount
        self.onCompletion = completion
    }

    public var progress: ScanProgress { progressLock.withLock { $0 } }

    public func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    public func start() {
        var st = stat()
        guard lstat(rootPath, &st) == 0 else {
            let err = errno
            let cb = onCompletion, path = rootPath
            DispatchQueue.main.async { cb(.failure(.cannotOpenRoot(path, errno: err))) }
            return
        }

        let rootName = rootPath == "/" ? "/" : rootPath
        let rootNode = FileNode(id: nextID(), name: rootName, flags: [.directory], parent: nil)
        self.root = rootNode

        cond.lock()
        pending = [Job(node: rootNode, path: rootPath)]
        outstanding = 1
        cond.unlock()

        let group = DispatchGroup()
        for _ in 0..<workerCount {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                workerLoop()
            }
        }
        group.notify(queue: .main) { [self] in
            duration = Date().timeIntervalSince(startedAt)
            let wasCancelled = cond.withLocked { cancelled }
            if wasCancelled {
                onCompletion(.failure(.cancelled))
                return
            }
            rootNode.sortBySizeRecursively()
            rootNode.markScanComplete()
            progressLock.withLock { $0.finished = true }
            onCompletion(.success(rootNode))
        }
    }

    private func nextID() -> UInt64 {
        idCounter.withLock { $0 += 1; return $0 }
    }

    // MARK: - Worker

    private func workerLoop() {
        let bufSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            cond.lock()
            while pending.isEmpty && outstanding > 0 && !cancelled {
                cond.wait()
            }
            if cancelled || (pending.isEmpty && outstanding == 0) {
                cond.broadcast()
                cond.unlock()
                return
            }
            let job = pending.removeLast()
            cond.unlock()

            processDirectory(job, buffer: buffer, bufSize: bufSize)

            cond.lock()
            outstanding -= 1
            if outstanding == 0 { cond.broadcast() }
            cond.unlock()
        }
    }

    private func enqueue(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        cond.lock()
        pending.append(contentsOf: jobs)
        outstanding += jobs.count
        cond.broadcast()
        cond.unlock()
    }

    private func processDirectory(_ job: Job, buffer: UnsafeMutableRawPointer, bufSize: Int) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM {
                progressLock.withLock { $0.deniedDirs += 1 }
            }
            job.node.markScanComplete()
            return
        }
        defer { close(fd) }

        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = Self.CMN_RETURNED_ATTRS | Self.CMN_ERROR | Self.CMN_NAME
            | Self.CMN_OBJTYPE | Self.CMN_MODTIME | Self.CMN_ACCTIME | Self.CMN_FILEID
        attrs.fileattr = Self.FILE_LINKCOUNT | Self.FILE_TOTALSIZE | Self.FILE_ALLOCSIZE

        var newJobs: [Job] = []
        var batchAllocated: Int64 = 0
        var batchLogical: Int64 = 0
        var batchFiles: Int64 = 0

        while true {
            if cond.withLocked({ cancelled }) { break }
            let count = getattrlistbulk(fd, &attrs, buffer, bufSize, 0)
            if count <= 0 { break }

            var offset = 0
            for _ in 0..<count {
                let entry = buffer.advanced(by: offset)
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry.advanced(by: 4)

                // attribute_set_t: five u_int32 groups
                let retCommon = p.loadUnaligned(as: UInt32.self)
                let retFile = p.advanced(by: 12).loadUnaligned(as: UInt32.self)
                p = p.advanced(by: 20)

                if retCommon & Self.CMN_ERROR != 0 {
                    p = p.advanced(by: 4)
                }

                var name = ""
                if retCommon & Self.CMN_NAME != 0 {
                    let nameOffset = Int(p.loadUnaligned(as: Int32.self))
                    name = String(cString: p.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self))
                    p = p.advanced(by: 8)
                }

                var objType: UInt32 = 0
                if retCommon & Self.CMN_OBJTYPE != 0 {
                    objType = p.loadUnaligned(as: UInt32.self)
                    p = p.advanced(by: 4)
                }

                var modified: TimeInterval = 0
                if retCommon & Self.CMN_MODTIME != 0 {
                    modified = TimeInterval(p.loadUnaligned(as: Int64.self))
                    p = p.advanced(by: 16)
                }

                var accessed: TimeInterval = 0
                if retCommon & Self.CMN_ACCTIME != 0 {
                    accessed = TimeInterval(p.loadUnaligned(as: Int64.self))
                    p = p.advanced(by: 16)
                }

                var fileID: UInt64 = 0
                if retCommon & Self.CMN_FILEID != 0 {
                    fileID = p.loadUnaligned(as: UInt64.self)
                    p = p.advanced(by: 8)
                }

                var linkCount: UInt32 = 1
                if retFile & Self.FILE_LINKCOUNT != 0 {
                    linkCount = p.loadUnaligned(as: UInt32.self)
                    p = p.advanced(by: 4)
                }

                var logicalSize: Int64 = 0
                if retFile & Self.FILE_TOTALSIZE != 0 {
                    logicalSize = p.loadUnaligned(as: Int64.self)
                    p = p.advanced(by: 8)
                }

                var allocatedSize: Int64 = 0
                if retFile & Self.FILE_ALLOCSIZE != 0 {
                    allocatedSize = p.loadUnaligned(as: Int64.self)
                }

                offset += entryLength
                if name.isEmpty { continue }

                let childPath = job.path == "/" ? "/" + name : job.path + "/" + name

                if objType == Self.VDIR {
                    var flags: FileNode.Flags = [.directory]
                    let ext = (name as NSString).pathExtension.lowercased()
                    if !ext.isEmpty && Self.packageExtensions.contains(ext) {
                        flags.insert(.package)
                    }
                    let child = FileNode(id: nextID(), name: name, flags: flags,
                                         modified: modified, accessed: accessed, parent: job.node)
                    job.node.appendChild(child)
                    if !Self.systemSkipPaths.contains(childPath) {
                        newJobs.append(Job(node: child, path: childPath))
                    } else {
                        child.markScanComplete()
                    }
                } else if objType == Self.VREG || objType == Self.VLNK {
                    var flags: FileNode.Flags = objType == Self.VLNK ? [.symlink] : []
                    var countedAllocated = allocatedSize
                    var countedLogical = logicalSize
                    // Hard links: count the size only once per inode.
                    if linkCount > 1 && fileID != 0 {
                        let inode = fileID
                        let isFirst = hardlinkLock.withLock { seen -> Bool in
                            seen.insert(inode).inserted
                        }
                        if !isFirst {
                            flags.insert(.hardlinkDup)
                            countedAllocated = 0
                            countedLogical = 0
                        }
                    }
                    let child = FileNode(id: nextID(), name: name, flags: flags,
                                         modified: modified, accessed: accessed, parent: job.node,
                                         allocatedSize: countedAllocated, logicalSize: countedLogical)
                    job.node.appendChild(child)
                    batchAllocated += countedAllocated
                    batchLogical += countedLogical
                    batchFiles += 1
                }
                // Sockets, fifos, devices: ignored.
            }
        }

        if batchFiles > 0 || batchAllocated > 0 {
            job.node.propagateSizes(allocated: batchAllocated, logical: batchLogical, files: batchFiles)
        }
        job.node.markScanComplete()
        enqueue(newJobs)

        let files = batchFiles, bytes = batchAllocated
        progressLock.withLock {
            $0.filesScanned += files
            $0.dirsScanned += 1
            $0.bytesFound += bytes
            $0.currentPath = job.path
        }
    }
}

private extension NSCondition {
    func withLocked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
