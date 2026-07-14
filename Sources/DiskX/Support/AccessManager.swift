import Foundation
import AppKit

/// Sandbox-aware folder access. In the App Store build (App Sandbox on), DiskX can
/// only scan locations the user explicitly granted through the folder picker; those
/// grants are persisted as security-scoped bookmarks and restored on launch.
/// In the direct-distribution build (no sandbox), everything passes through.
enum AccessManager {
    static let isSandboxed: Bool =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static let defaultsKey = "grantedBookmarks"

    /// Persists access to a user-picked URL. Call right after NSOpenPanel returns.
    static func grant(_ url: URL) {
        guard isSandboxed else { return }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) else { return }
        var all = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        // Replace an existing bookmark for the same path instead of accumulating.
        all.removeAll { resolve($0)?.url.path == url.path }
        all.append(bookmark)
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// Restores every persisted grant and begins security-scoped access.
    /// Returns the reachable URLs (stale bookmarks are dropped).
    static func restoreGrantedURLs() -> [URL] {
        guard isSandboxed else { return [] }
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var urls: [URL] = []
        var kept: [Data] = []
        for data in stored {
            guard let (url, stale) = resolve(data) else { continue }
            if stale {
                // Re-mint the bookmark so it survives the next launch.
                if url.startAccessingSecurityScopedResource(),
                   let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
                    kept.append(fresh)
                    urls.append(url)
                }
            } else if url.startAccessingSecurityScopedResource() {
                kept.append(data)
                urls.append(url)
            }
        }
        UserDefaults.standard.set(kept, forKey: defaultsKey)
        return urls
    }

    static func removeGrant(path: String) {
        guard isSandboxed else { return }
        var all = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        all.removeAll { resolve($0)?.url.path == path }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}
