# DiskX Architecture

How DiskX is put together, and — more usefully — *why* each part is the way it
is. Where a design looks odd, there is normally a macOS behaviour or a
performance cliff behind it; those are called out explicitly so nobody
"simplifies" them back into a bug.

- [Target layout](#target-layout)
- [The scan engine](#the-scan-engine)
- [The node tree](#the-node-tree)
- [Classification](#classification)
- [Reclaim Sort](#reclaim-sort)
- [Treemap layout](#treemap-layout)
- [Deletion and undo](#deletion-and-undo)
- [The app layer](#the-app-layer)
- [Sandboxing and file access](#sandboxing-and-file-access)
- [Build, signing and release](#build-signing-and-release)
- [Testing](#testing)

---

## Target layout

Four SwiftPM targets, declared in [Package.swift](Package.swift):

| Target | Kind | Contents |
|---|---|---|
| `DiskXCore` | library | Scan engine, node tree, classification, Reclaim Sort, treemap geometry, trash engine. No AppKit, no SwiftUI. |
| `DiskX` | executable | The app: SwiftUI views, `AppModel`, keyboard dispatch, Quick Look, theming, sandbox access. |
| `diskx-bench` | executable | Headless benchmark harness that drives `ScanSession` directly. |
| `DiskXTests` | test | Unit tests against `DiskXCore`. |

The split is load-bearing rather than cosmetic. Everything in `DiskXCore` is
pure model and algorithm, so it is testable without a window server — which is
why the test target depends only on `DiskXCore` and runs in CI with no UI
session. Anything that imports SwiftUI belongs in `DiskX`.

All targets build in Swift 5 language mode under a Swift 6.2 toolchain
(`swiftLanguageMode(.v5)`). The concurrency model here is explicit locks and
`@unchecked Sendable`, not actors — see [The node tree](#the-node-tree) — and
strict Swift 6 concurrency checking would reject it without making it safer.

---

## The scan engine

[`Sources/DiskXCore/Engine/DiskScanner.swift`](Sources/DiskXCore/Engine/DiskScanner.swift)

`ScanSession` walks a directory tree with `getattrlistbulk(2)` — the bulk
enumeration syscall Finder itself uses — across a work-stealing pool sized to
`activeProcessorCount` (minimum 4). Each worker owns one 256 KB buffer and pulls
jobs off a shared `pending` stack guarded by an `NSCondition`. One
`getattrlistbulk` call returns dozens of entries with their attributes already
attached, so a directory of 500 files costs a handful of syscalls instead of
1 + 500 `lstat` calls.

Attributes are requested in a single `attrlist` and parsed by hand out of the
returned buffer: name, device id, object type, mtime, atime, `st_flags`, file
id, link count, total size and allocated size. The parser walks the buffer with
explicit offsets because the packed layout is positional — each attribute is
present only if its bit is set in the returned-attributes mask, so the field
order in the parse loop must match the bit order in the request. Reordering
either one silently misreads every subsequent field.

### Why it does not hang

Three separate mechanisms, each guarding a different failure mode. All three
exist because a scan that never finishes is worse than a scan that misses a
folder:

1. **`setiopolicy_np(MATERIALIZE_DATALESS_FILES, PROCESS, OFF)`**, applied once
   process-wide. Without it, `open(2)` on a dataless directory such as
   `~/Library/CloudStorage` asks the file provider to materialize it and blocks
   until that finishes — potentially forever, and it would also download the
   user's entire cloud drive as a side effect of a disk survey.
2. **`O_NONBLOCK` on every directory open.** A stalled provider or synthetic
   mount would otherwise block the worker forever, `outstanding` would never
   reach zero, and the whole scan would hang with no error. Non-blocking returns
   `EAGAIN`/`ENOTSUP` immediately and the directory is counted as denied.
3. **Dataless directories are never descended into** even with the policy set,
   because a wedged provider can still block. The node is flagged
   `.cloudDataless` and marked complete.

`DISKX_TRACE=1` writes every directory path to stderr before the `open(2)`. When
a scan does stall on some exotic filesystem, the tail of that log names the
directory.

### Correctness details

- **Hard links are counted once**, keyed on `(device, inode)` — inode numbers
  repeat across volumes, so the device id is required. Duplicates are kept in
  the tree, flagged `.hardlinkDup`, and contribute zero bytes.
- **Symlinks are never followed** (`O_NOFOLLOW`); they appear as nodes with
  their own small size. This is what stops a `/tmp → /private/tmp` style loop
  from recursing forever.
- **`/System/Volumes/Data` is skipped** along with `/Volumes`, `/dev`, `/net`,
  `/home` and the VM/Preboot/Recovery volumes. Its contents are already reached
  through the root-level firmlinks (`/Users`, `/Applications`, …), so descending
  would count the entire data volume twice and produce a total larger than the
  disk.
- **The root is probed with `open(2)`, not `lstat`.** An unreadable root has to
  fail loudly with `ScanError.cannotOpenRoot` — which carries a Full Disk Access
  hint when `errno` is `EACCES`/`EPERM` — rather than succeed as an empty tree
  and quietly report that the disk is empty.
- **Package directories** (`.app`, `.framework`, `.photoslibrary`, …) are
  flagged `.package` and sized in full, but presented as single items rather
  than trees the user drills into.

Sizes accumulate per *batch*, not per file: a directory's whole batch is summed
locally, then `propagateSizes` walks the ancestor chain once. Propagating per
file would take the same locks millions of times.

---

## The node tree

[`Sources/DiskXCore/Models/FileNode.swift`](Sources/DiskXCore/Models/FileNode.swift)

`FileNode` is a reference type with an `OSAllocatedUnfairLock` guarding its
mutable state (`children`, sizes, file count, scan-complete flag). It is
`@unchecked Sendable` on purpose: scanner workers append children and accumulate
sizes concurrently while the UI reads snapshots through the same lock. Unfair
locks are the right primitive here — contention is low and the critical sections
are a few instructions each, so the cost is far below an actor hop per node
across millions of nodes.

Once the scan completes the tree is effectively immutable and can be read
without ceremony. The two exceptions are deletion (`detachFromTree`) and its
undo, both of which run on the main actor after the scan has finished.

Two details worth keeping:

- **`parent` is `unowned`.** Children hold strong references to nothing upward,
  so the tree is a clean ownership hierarchy with no retain cycles; dropping the
  root frees everything.
- **`path` is reconstructed by walking parents**, not stored. Storing an
  absolute path per node would cost more than the node itself on a
  million-file scan. The `//` guard handles the root-is-`/` case so
  `/` + `Users` does not become `//Users`.

`largestFiles(limit:)` powers the flat Top-Files view. It uses a fixed-capacity
min-heap keyed on size, so finding the top 100 of 1.3 million files is
O(F log 100) with 100 nodes of memory, instead of materializing and sorting the
entire file list.

---

## Classification

[`Sources/DiskXCore/Models/FileCategory.swift`](Sources/DiskXCore/Models/FileCategory.swift)

Twelve coarse categories (cache, build artifact, installer, log, trash, backup,
media, document, code, application, system, other), each with a `disposability`
weight and a monochrome SF Symbol.

There are deliberately **two** classifiers:

- **`classify(name:path:isDirectory:)`** — the thorough one. Checks path markers
  (`/library/caches/`, `/node_modules/`, `/deriveddata/`), system prefixes, then
  extension tables.
- **`classifyFast(name:isDirectory:inherited:)`** — O(1). Table lookups on the
  name plus the parent's inherited category, and it never looks at the path.

The fast path exists because running the full classifier over millions of nodes
made analysis take *minutes*. Two specific costs drove that: building an
absolute path string per node, and `String.contains`, which performs Unicode
normalization by default. The latter is why `literallyContains` exists — it
forces `options: .literal`. The `/name/` path markers are precomputed for the
same reason; interpolating them per call was itself a hot spot.

`inheritsToChildren` is the mechanism that makes the fast path correct: a file
inside `node_modules` is a build artifact regardless of its extension, so
categories that own their whole subtree (cache, build artifact, trash,
application, system, backup, log) propagate downward, while leaf categories
(media, document, code) do not drag their children along.

---

## Reclaim Sort

[`Sources/DiskXCore/Engine/ReclaimAnalyzer.swift`](Sources/DiskXCore/Engine/ReclaimAnalyzer.swift)

The product's central claim: default ordering answers *"what should I delete
first?"* rather than *"what is biggest?"*. It is a deterministic, inspectable
score — **never machine learning** — so every row can explain itself.

```
score = allocatedSize × tier.weight × stalenessMultiplier
```

**Safety tiers** and their weights:

| Tier | Weight | Meaning |
|---|---|---|
| `regenerates` | 1.0 | Caches, build artifacts, logs, trash — apps rebuild these |
| `reobtainable` | 0.8 | Installers and archives — downloadable again |
| `review` | 0.5 | App data, project dirs — yours, look first |
| `coldPersonal` | 0.35 | Your own files, just old |
| `application` | 0.15 | App bundles |
| `protected` | 0.02 | System/SIP — visible, never deletable through DiskX |

**Staleness** multiplies by recency of the *fresher* of mtime/atime: 0.5 under
30 days, 0.8 under 180, 1.0 under a year, 1.5 under three years, 2.0 beyond.

Only `reobtainable` and `regenerates` count as `isSafeReclaim`, and only those
feed the "Reclaimable now: ~X safe" figure. The number shown to the user is
always honest allocated bytes; the score orders rows and is never displayed.

### The shallow/deep split

`analyze(root:)` runs the full path-based classifier for the first two levels
only (a few hundred nodes), where system prefixes and path markers actually
matter, and the O(1) inherited classifier below that. Path strings are only
built while the full classifier is in play. This is the change that took
analysis from minutes to well under a second.

Directories in a safe tier **score as a unit and stop recursing** — every
descendant of a `Caches` folder shares its tier, so there is nothing to learn by
walking in. Nodes inside those pruned subtrees are therefore absent from
`infos`, which is exactly why `computeStandalone` exists: when the UI needs
detail for a node the main pass never indexed, it classifies that one node from
its full path.

**Hotspots** are safe-tier nodes at depth ≥ 1 over 50 MB (directories) or 100 MB
(files), sorted by score, capped at 64. They are what the UI hoists as ghost
rows (`↳ …/Xcode/DerivedData · 6 levels deep`) so deep junk surfaces without
drilling.

`whyLine(for:)` renders the plain-language justification for each row from the
same data — category, age and reclaimable bytes. It is the user-facing proof
that the ranking is inspectable rather than magic.

---

## Treemap layout

[`Sources/DiskXCore/Engine/TreemapLayout.swift`](Sources/DiskXCore/Engine/TreemapLayout.swift)

Squarified treemap (Bruls, Huizing, van Wijk 2000). Pure geometry with no
AppKit dependency, which is what makes it directly unit-testable.

Weights are normalized to the container's area, then items are greedily packed
into rows; a row is closed when adding the next item would worsen its worst
aspect ratio. Rows are laid as vertical strips when the remaining rect is wider
than tall, horizontal otherwise. Squarification matters for usability, not
looks: tiles near 1:1 stay large enough to read and click, where a naive
slice-and-dice produces unusable slivers.

Callers must pass items sorted by weight descending — the greedy algorithm
assumes it. Non-positive weights are dropped, and the placements tile the
container exactly (verified in tests to within 1 pt² of the container area).

---

## Deletion and undo

[`Sources/DiskXCore/Engine/TrashEngine.swift`](Sources/DiskXCore/Engine/TrashEngine.swift)

Deletion is **trash-only** — `FileManager.trashItem` — never
`removeItem`. There is no code path in DiskX that permanently deletes a user
file, which is what makes the confirm flow safe to keep lightweight.

`minimalCover(of:)` drops any node whose ancestor is also selected: trashing the
ancestor already covers it, and trashing both would fail on the second item
because it no longer exists. Marking across folders makes this situation
routine, not exotic.

Every item returns an `ItemResult` carrying its own error, so partial failures
are reported honestly rather than collapsed into one "something went wrong".
`trashedTo` records where each item landed in the Trash, which is what makes
undo a plain `moveItem` back.

Undo is a tree operation as much as a filesystem one: `detachFromTree`
subtracts the node's aggregate sizes from every ancestor on delete, and the undo
path re-appends the node and calls `propagateSizes` with the same figures. Both
directions must stay symmetric or the Truth Bar drifts away from Finder.

---

## The app layer

[`Sources/DiskX/AppModel.swift`](Sources/DiskX/AppModel.swift) is a
`@MainActor @Observable` model holding scan lifecycle, the row list,
navigation, selection and marks, goal mode, the delete flow and sort state. Views
in `Sources/DiskX/Views/` are thin and derive everything from it.

Notable pieces:

- **Truth Bar** reconciles scanned bytes, "Other & System", purgeable and free
  space against what Finder reports, so the total adds up instead of leaving
  users to wonder about "System Data".
- **`KeyboardDispatch`** centralizes the key map (`↑↓/jk`, `→/Return`, `←/⌘↑`,
  `X`, `Space`, `1–5`, `` ` ``, `G`, `?`) so the bindings live in one place
  rather than scattered across views.
- **`QuickLookController`** bridges to `QLPreviewPanel` for `Space`.
- **`AppTheme`** carries light/dark/system with semantic colors and Liquid Glass
  (macOS 26+) with material fallbacks.
- **`GlassStyle`** holds the shared surface treatment. Per the project's spacing
  rule, insets are generous (≥ 8–10 pt) and text is never squeezed to a border.

---

## Sandboxing and file access

Two distribution builds with deliberately different postures:

| | Mac App Store | Direct (Developer ID) |
|---|---|---|
| Entitlements | [`DiskX-AppStore.entitlements`](Entitlements/DiskX-AppStore.entitlements) | [`DiskX-DeveloperID.entitlements`](Entitlements/DiskX-DeveloperID.entitlements) |
| App Sandbox | required | off |
| Scope | user-granted folders only | whole volumes, via Full Disk Access |

[`AccessManager`](Sources/DiskX/Support/AccessManager.swift) detects the sandbox
at runtime (`APP_SANDBOX_CONTAINER_ID`) and, when sandboxed, persists each
folder grant as a security-scoped bookmark in `UserDefaults`, restoring them on
launch.
Unsandboxed, everything passes straight through.

The Developer ID entitlements file is intentionally an **empty dictionary**.
Full Disk Access is a TCC grant, not an entitlement, and DiskX needs none of the
hardened-runtime exceptions (no JIT, no unsigned executable memory, no dyld
environment variables, no library-validation opt-out). The sandbox file's
security-scoped-bookmark keys are inert outside the sandbox and must not be
copied across.

When a folder cannot be read, DiskX shows an honest "unreadable folders" chip
rather than silently undercounting — the same principle as the Truth Bar.

---

## Build, signing and release

Three scripts, each with one job:

| Script | Produces |
|---|---|
| [`Scripts/package_app.sh`](Scripts/package_app.sh) | `DiskX.app` — ad-hoc or identity-signed. The shared packager the other two call. |
| [`Scripts/package_appstore.sh`](Scripts/package_appstore.sh) | Sandboxed `.pkg` for App Store Connect upload. |
| [`Scripts/notarize_release.sh`](Scripts/notarize_release.sh) | Notarized, stapled universal `.app` + `.dmg` for direct distribution. |

`version.env` is the single source of version truth (`MARKETING_VERSION`,
`BUILD_NUMBER`, `BUNDLE_ID`, `MACOS_MIN_VERSION`); all three scripts source it.

### Universal builds need per-arch scratch paths

`package_app.sh` builds each architecture into its own SwiftPM scratch path
(`.build/universal-arm64`, `.build/universal-x86_64`) and `lipo`s the results.
This is not tidiness. SwiftPM keeps **one llbuild database per scratch path**,
keyed to the architecture of the last build, so building arm64 and then x86_64
in a shared `.build` fails with `command ... not registered` for every auxiliary
file. Separate scratch paths also keep both architectures independently
incremental.

### Notarization

`notarize_release.sh` runs: build universal → sign with Developer ID under the
hardened runtime with a secure timestamp → notarize the `.app` → staple →
package the stapled app into a DMG → sign the DMG → notarize → staple → verify
with `spctl` and `stapler validate`.

The two-stage order is deliberate. Notarizing only the DMG — the common
shortcut — leaves the extracted `.app` without its own ticket, so a user who
drags it to `/Applications` and first launches it offline still gets the
Gatekeeper prompt, because Gatekeeper has to reach Apple to verify. Stapling
both means the first launch works with no network.

Requirements, none of which live in this repo: a *Developer ID Application*
certificate in the **login** keychain (iCloud Keychain never syncs signing
identities), a stored `notarytool` credential profile built from an
app-specific password, and current Apple Developer Program agreements. A
submission that fails with HTTP 403 *"required agreement is missing or has
expired"* is an account problem, not a build problem — the script detects that
case and says so. Note that the notary service caches agreement state and lags
the developer portal by a few minutes after acceptance.

Signing material is never committed. `.gitignore` blocks `*.p12`, `*.cer`,
`*.pem`, `*.key`, `*.mobileprovision`, `*.provisionprofile` and `.env*` as
defence in depth; the private key, app-specific password and notary profile all
live in the login keychain.

---

## Testing

`swift test` runs [`Tests/DiskXTests`](Tests/DiskXTests) against `DiskXCore`.
No window server required.

| File | Covers |
|---|---|
| `EngineTests.swift` | Scanner counts/sizes/sorting, hard-link dedup, symlink non-traversal, top-N selection, unreadable-root failure; treemap tiling, proportionality and degenerate inputs; both classifiers and inheritance. |
| `ReclaimTests.swift` | Staleness buckets, category→tier mapping, score ordering, safe-reclaim aggregation, safe-subtree pruning, hotspot selection, WHY lines, standalone classification. |
| `TrashTests.swift` | Minimal cover, trash/restore round-trip with tree bookkeeping, honest failure reporting. |
| `FormatTests.swift` | Byte/count formatting and the age buckets that appear in every WHY line. |

Scanner tests build real temp trees and run a real `ScanSession` rather than
mocking the filesystem — the syscall-level behaviour (bulk enumeration, hard
links, `O_NOFOLLOW`) *is* the thing under test, and a mock would assert nothing
about it. Test files are written with non-zero bytes so APFS cannot hole-punch
them into zero allocated size.

Assertions on allocated size use `>=` against logical size, since allocation
rounds up to block boundaries and the exact figure is filesystem-dependent.
