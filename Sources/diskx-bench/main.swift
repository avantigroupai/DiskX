import Foundation
import DiskXCore

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory() + "/Library"
let start = Date()
// Completion arrives on the main queue — keep it running via dispatchMain(),
// never block it with a semaphore.
let session = ScanSession(path: path) { result in
    switch result {
    case .success(let root):
        let dt = Date().timeIntervalSince(start)
        print(String(format: "Scanned %@ in %.2fs — %lld files, %lld dirs, %@",
                     path, dt, root.fileCount, session.progress.dirsScanned, ByteCountFormatter.string(fromByteCount: root.allocatedSize, countStyle: .file)))
        print(String(format: "Rate: %.0f files/sec", Double(root.fileCount) / dt))
        if session.progress.deniedDirs > 0 { print("Denied dirs: \(session.progress.deniedDirs)") }
        let analyzer = ReclaimAnalyzer()
        let analyzeStart = Date()
        analyzer.analyze(root: root)
        print(String(format: "Analyze: %.2fs — safe reclaim %@, %d hotspots",
                     Date().timeIntervalSince(analyzeStart),
                     ByteCountFormatter.string(fromByteCount: analyzer.totalSafeReclaim, countStyle: .file),
                     analyzer.hotspots.count))
    case .failure(let err):
        print("FAILED: \(err.localizedDescription)")
    }
    exit(0)
}
session.start()
dispatchMain()
