# Changelog

All notable changes to DiskX are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.7] — 2026-10-06

### Fixed & Improved

- **Truth Bar Capacity Strip Rendering**:
  Fixed segmented bar right edge rendering where the Free space segment was drawn as a sharp 4-sided stroke rectangle clipped by a continuous rounded rectangle, causing missing corners and detached vertical line artifacts. Refactored the capacity bar to use a continuous background track, smooth outer border, and transparent Free segment with subpixel width normalization.
- **File List Navigation & Sorting Controls**:
  Added an interactive list column header bar (NAME, UNTOUCHED, SIZE/RECLAIMABLE) for one-click column sorting and direction toggles, a direct sort dropdown and reverse button in the breadcrumb bar, and contextual menu sort actions.

## [1.0.6] — 2026-10-04

### Comprehensive 88-Round QA & Hardening Release

- **Saturating Math in Reclaim & Progress Aggregation**:
  Hardened `childSafe` accumulation in `ReclaimAnalyzer` and live scanner counters with `SaturatingMath.add` and added `SaturatingMath.subtract` to prevent arithmetic overflow/underflow (`SIGTRAP`) across petabyte allocations or corrupted filesystem data.
- **TrashEngine Minimal Cover Deduplication**:
  `TrashEngine.minimalCover(of:)` now automatically deduplicates identical node IDs before calculating ancestral cover, preventing redundant deletion attempts and double-processing errors.
- **Treemap Micro-Weight Protection**:
  Added guard against floating point underflow and division-by-zero (`guard s2 * minW > 0 else { return .infinity }`) in squarified treemap aspect-ratio evaluation for near-zero weights.
- **Bare System Prefix & Volume Trash Detection**:
  Enhanced `FileCategory.classify` to match bare system prefixes (e.g. `/System`, `/usr`, `/bin`, `/sbin`, `/private/var/db`) without requiring trailing slashes, and correctly identify root and volume `.trashes` directories.
- **Deterministic Sort Tie-Breaking**:
  Added secondary tie-breaking by allocated size and localized natural name across `.reclaim`, `.size`, `.forgotten`, and `.count` modes to completely eliminate UI list flicker.
- **Underflow Protection on Undo**:
  Protected `freedThisSession` from underflowing below zero when restoring batches from Trash.
- **Expanded Test Suite (75 Tests)**:
  Added unit and regression test coverage for all 88 QA rounds, including duplicate cover handling, saturating arithmetic, system root classification, and micro-weight treemap layouts. All 75 tests passing.

## [1.0.5] — 2026-10-04

### Added

- **Keyboard Shortcut for Multi-Selection Deletion (`⌫`, `⌘⌫`, `⌦`, `D`)**:
  Pressing the Delete key, `⌘⌫` (Command + Backspace), Forward Delete, or `D` on any multi-file selection now prompts with the confirmation sheet asking "Move \(n) items to Trash? Frees about X now."
- **Prioritize Multi-Selection over Background Marks**:
  When two or more items are actively selected on screen, Delete commands immediately target the active selection rather than background marks.
- **Full Keyboard Navigation in Confirmation Dialog**:
  Confirm deletion with `Return` or `Y` (an explicit `Y` is required if deleting risky user data), or cancel with `Esc`, `N`, or `⌘.`. Numeric keypad Enter (code 76) is also supported.
- **Command-Key Enhancements (`⌘⌫`, `⌘F`, `⇧⌘R`, `⇧⌘O`)**:
  Added native macOS shortcuts for Move to Trash (`⌘⌫`), Find/Filter (`⌘F`), Reveal in Finder (`⇧⌘R`), and Open (`⇧⌘O`).
- **Batch Marking with `X`**:
  Pressing `X` on multiple selected rows now marks or unmarks all selected items at once.
- **Menu Bar Integration**:
  Added discoverable menu bar commands for Move to Trash (`⌘⌫`), Find (`⌘F`), and Quick Look (`⌘Y`).
- **Context Menu Keyboard Badges**:
  Context menu entries now show their keyboard equivalents (`E`, `⏎`, `⌘C`, `X`, `⌫`).

## [1.0.4] — 2026-10-04

### Added

- **Multi-Selection Context Menu Deletion**:
  Right-clicking when multiple files are selected now shows a dedicated **"Move \(count) Items to Trash (⌫)"** option that operates on all selected files simultaneously while ensuring unrelated background marks do not ride along.
- **Multi-Selection Row Actions**:
  "Reveal in Finder", "Open", "Copy Paths", and "Mark/Unmark" in the context menu now seamlessly process all selected items together.
- **"Untouched" Sort Mode (Key `3`)**:
  Sort files by how long they have been untouched (using the fresher of modification and access timestamps). Longest untouched files appear first by default; toggle with `⇧S` or the toolbar direction button to reverse.
- **Sort Direction Reversal (`⇧S`)**:
  Reverse sort direction for all six sort modes with `⇧S`, the menu bar item, or the direction button in the toolbar.
- **Test Coverage**:
  Added comprehensive tests for multi-node trashing, detaching, restore, and untouched duration sorting (64 tests total, all passing).

## [1.0.1] — 2026-08-11

The first build users can simply open. 1.0.0 was ad-hoc signed, so macOS
quarantined it and every user had to detour through right-click → Open or an
`xattr` command before the app would launch. That detour is gone.

No behavioural changes to scanning, ranking or deletion — this release is about
distribution, documentation and test coverage.

### Added

- **Developer ID signing and Apple notarization.**
  [`Scripts/notarize_release.sh`](Scripts/notarize_release.sh) builds a universal
  binary, signs it under the hardened runtime with a secure timestamp, then
  notarizes and staples **both** the `.app` and the `.dmg`.
  Notarizing only the DMG — the usual shortcut — leaves the extracted app without
  its own ticket, so a user who drags it to `/Applications` and first launches it
  offline still meets Gatekeeper. Stapling both means the first launch works with
  no network. Verified with `spctl` (`source=Notarized Developer ID`),
  `stapler validate`, and against a DMG carrying a real
  `com.apple.quarantine` flag.
- **[`Entitlements/DiskX-DeveloperID.entitlements`](Entitlements/DiskX-DeveloperID.entitlements)** —
  entitlements for direct distribution. Deliberately an empty dictionary: the
  direct build stays unsandboxed so it can survey whole volumes (Full Disk Access
  is a TCC grant, not an entitlement), and DiskX needs none of the
  hardened-runtime exceptions.
- **[`ARCHITECTURE.md`](ARCHITECTURE.md)** — full write-up of the target layout,
  scan engine, node tree, classification, Reclaim Sort, treemap geometry,
  deletion/undo, sandboxing and the release pipeline, with the reasoning behind
  the non-obvious parts.
- **This changelog.**
- **28 new tests** (17 → 45, all passing):
  - `ReclaimTests.swift` — `ReclaimAnalyzer` previously had **zero** coverage
    despite being the product's central claim. Now covers staleness buckets and
    the fresher-of-mtime/atime rule, category→tier mapping, the system-prefix
    backstop, safe-reclaim aggregation, safe-subtree pruning with the standalone
    fallback, hotspot selection and ordering, and WHY-line wording.
  - `FormatTests.swift` — age buckets (user-facing copy in every WHY line),
    unknown-timestamp handling, negative byte formatting from undo.
  - `FileNodeTests` in `EngineTests.swift` — root-path reconstruction, ancestry
    ordering, delete/undo size symmetry across all ancestors, `largestFiles`
    edge cases.

### Fixed

- **Universal builds were impossible.** Building arm64 and then x86_64 in the
  shared `.build` failed with `command ... not registered` for every auxiliary
  file: SwiftPM keeps one llbuild database per scratch path, keyed to the
  architecture of the last build.
  [`Scripts/package_app.sh`](Scripts/package_app.sh) now gives each architecture
  its own scratch path, which also keeps both independently incremental.
  Universal builds were advertised before this release but did not build.
- **Stale documentation pointer** — the README referred to a
  `sign-and-notarize.sh` that does not exist in this repository.

### Changed

- README, website and `llms.txt` now describe the notarized artifact instead of
  the quarantine workaround.
- `.gitignore` blocks `*.p12`, `*.cer`, `*.pem`, `*.key`, `*.mobileprovision`
  and `.env*` as defence in depth. Signing material has never been committed —
  the private key, app-specific password and notary credential profile all live
  in the macOS login keychain — and these patterns keep it that way if someone
  exports one into the working tree while debugging.
- Doc comments added for the view-facing value types (`ScanPhase`, `Row`,
  `DeletePlan`, `TruthStats`, `SmartScope`), `ScanError`, `ScanProgress` and
  `Format`, covering the reasoning a reader cannot recover from the code:
  why `analyzing` is a separate phase from `scanning`, why `Row` equality is
  deliberately shallow, and why `TruthStats.otherUsed` is derived by subtraction.

### Notes for packagers

Notarization requires a *Developer ID Application* certificate in the **login**
keychain — iCloud Keychain never syncs signing identities — plus a stored
`notarytool` credential profile and current Apple Developer Program agreements.
A submission failing with HTTP 403 *"required agreement is missing or has
expired"* is an account problem rather than a build problem; the release script
detects that case and explains it. The notary service caches agreement state and
lags the developer portal by a few minutes after acceptance.

---

## [1.0.0] — 2026-08-11

First public release.

### Added

- **Reclaim Sort** (default ordering): rows ranked by
  `reclaimable bytes × safety tier × staleness` — deterministic and inspectable,
  never AI. Displayed numbers are always honest gigabytes, never an abstract
  score. Every row carries a plain-language WHY line.
- **Ghost-row hoisting**: deep junk (`DerivedData`, `node_modules`, …) surfaces
  in the current level as `↳ …/Xcode/DerivedData · 6 levels deep`, so nobody has
  to drill down to find it.
- **Truth Bar**: capacity accounting that reconciles with Finder — scanned files,
  "Other & System" (the System Data mystery, explained), purgeable and free —
  plus "Reclaimable now: ~X safe" and a freed-this-session counter.
- **WizTree-class scanning**: parallel `getattrlistbulk` work-stealing pool, hard
  links deduped by `(device, inode)`, live streaming results. Roughly 29,000
  files/second on a 1.33-million-file home directory.
- **Squarified treemap** synchronized with the file list.
- **100% keyboard operation**: `↑↓/jk` move, `→/Return` descend, `←/⌘↑` up,
  `X` mark across folders, `Space` Quick Look, `1–5` sorts, `` ` `` flat
  Top-Files view, `G` goal mode, `?` cheat sheet.
- **Fear-free deletion**: Trash-only, never permanent. Risk-proportional
  confirmation — if everything regenerates one Return suffices; if anything is
  yours, Return goes inert and an explicit `Y` is required. App-level ⌘Z restores
  the whole batch. Protected system items can never enter the flow.
- **App Store readiness**: sandbox entitlements, privacy manifest with
  required-reason API declarations, app icon, category and copyright metadata,
  and sandbox-aware scanning via security-scoped bookmarks.
- Light, dark and system themes with semantic colors and Liquid Glass
  (macOS 26+) with material fallbacks.

### Fixed

- **Scan hang** on dataless iCloud/File-Provider directories. Three guards now
  apply: a process-wide policy that never materializes dataless files, `O_NONBLOCK`
  on every directory open, and never descending into dataless directories.
- **Analysis was ~50× too slow** — building an absolute path per node and using
  Foundation's Unicode-normalizing `String.contains` over millions of nodes made
  the pass take minutes. Now a shallow/deep classifier split with literal
  substring matching and precomputed path markers.
- Spacing pass: no text squeezed to a border anywhere.

[1.0.1]: https://github.com/avantigroupai/DiskX/releases/tag/1.0.1
[1.0.0]: https://github.com/avantigroupai/DiskX/releases/tag/1.0.0
