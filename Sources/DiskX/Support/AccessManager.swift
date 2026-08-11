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

    /// URLs whose security scope this process currently holds, so access can be
    /// balanced with `stopAccessingSecurityScopedResource()` on teardown. Unbalanced
    /// `start…` calls leak kernel resources for the life of the process.
    private static var activeScopes: [URL] = []

    /// Restores every persisted grant and begins security-scoped access.
    ///
    /// A bookmark that fails to resolve is KEPT, not discarded: an external volume
    /// that happens to be unplugged at launch is temporarily unresolvable, and
    /// dropping it would silently revoke a grant the user has to re-authorize by
    /// hand. Only bookmarks the system reports as permanently unusable are removed.
    static func restoreGrantedURLs() -> [URL] {
        guard isSandboxed else { return [] }
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var urls: [URL] = []
        var kept: [Data] = []
        for data in stored {
            guard let (url, stale) = resolve(data) else {
                kept.append(data)      // unreachable right now ≠ revoked
                continue
            }
            guard url.startAccessingSecurityScopedResource() else {
                kept.append(data)
                continue
            }
            activeScopes.append(url)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) {
                kept.append(fresh)     // re-mint so it survives the next launch
            } else {
                kept.append(data)
            }
            urls.append(url)
        }
        UserDefaults.standard.set(kept, forKey: defaultsKey)
        return urls
    }

    /// Balances every `startAccessingSecurityScopedResource()` taken by this process.
    static func releaseAll() {
        for url in activeScopes {
            url.stopAccessingSecurityScopedResource()
        }
        activeScopes.removeAll()
    }

    static func removeGrant(path: String) {
        guard isSandboxed else { return }
        var all = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        all.removeAll { resolve($0)?.url.path == path }
        UserDefaults.standard.set(all, forKey: defaultsKey)
        if let idx = activeScopes.firstIndex(where: { $0.path == path }) {
            activeScopes[idx].stopAccessingSecurityScopedResource()
            activeScopes.remove(at: idx)
        }
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        // .withoutUI and .withoutMounting: resolving a bookmark at launch must never
        // block on an authentication dialog or silently remount a volume.
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}
