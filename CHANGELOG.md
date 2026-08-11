# Changelog

All notable changes to DiskX are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

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
