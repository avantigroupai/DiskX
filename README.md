# DiskX — macOS disk space analyzer & disk explorer

**The WizTree-fast, ncdu-friendly disk visualizer macOS never shipped.**
A free, open-source **disk space analyzer for Mac** that shows what's eating your
storage — and, unlike every other **disk usage analyzer**, tells you what's
actually safe to delete first.

![DiskX showing Reclaim Sort with ghost-row hoisting, plain-language WHY lines, the Truth Bar capacity strip, and a synchronized squarified treemap](docs/screenshot.png)

If you've ever searched *"what is taking up space on my Mac"*, *"how to free up
disk space on macOS"*, *"what is System Data"*, or *"find large files Mac"* — this
is the tool that answers it in one screen. DiskX is a native Swift/SwiftUI
**storage analyzer, disk explorer and disk cleaner** for macOS 14+ (Apple Silicon
and Intel), combining a **treemap visualization**, a keyboard-driven file browser,
and safe one-keystroke deletion.

Every existing analyzer sorts by raw size, which puts `/System` and your Photos Library — the things you cannot or should not touch — at the top, while the 40 GB of Xcode caches you could delete right now sits three levels deep. DiskX's default ordering answers the question users actually ask: **"What should I delete first?"**

## Download

**[⬇ Download DiskX 1.0.3 (.dmg)](https://github.com/avantigroupai/DiskX/releases/latest)** — macOS 14 Sonoma or later, universal.

1.0.3 is the **notarized** build of the 1.0.2 security release, which fixes a
reproducible crash that let any scanned folder abort the app and hardens the
deletion path. Update from 1.0.0/1.0.1/1.0.2.

Drag it to Applications and open it. No right-click → Open, no `xattr`, no
Privacy & Security detour: it is Developer ID signed, notarized by Apple, and
stapled — both the DMG *and* the app inside it, so first launch works offline
too. Gatekeeper reports `source=Notarized Developer ID`.

Prefer to build it yourself? See [Build & run](#build--run) — it takes about ten seconds.

## Highlights

- **Reclaim Sort** (default): rows ordered by `reclaimable bytes × safety tier × staleness` — deterministic, inspectable, never AI. The displayed number is always honest gigabytes, never an abstract score. Every row has a plain-language **WHY line** ("Xcode cache — regenerates on next build · untouched 14 months · frees 21.3 GB now").
- **Ghost-row hoisting**: deep junk (`DerivedData`, `node_modules`, …) is hoisted into the current level as `↳ …/Xcode/DerivedData · 6 levels deep` — no repetitive drill-down.
- **Truth Bar**: honest capacity accounting that reconciles with Finder — scanned files, "Other & System" (the System Data mystery, explained), purgeable, free. Plus "Reclaimable now: ~X safe" and a freed-this-session counter.
- **WizTree-class scanning**: parallel `getattrlistbulk` work-stealing pool; hard links deduped by inode; live streaming results — never a blank wait.
- **100 % keyboard**: `↑↓/jk` move · `→/Return` descend · `←/⌘↑` up · `X` mark across folders · `Space` QuickLook · `1–5` sorts · `` ` `` flat Top-Files view · `G` goal mode ("I need 25 GB back") · `?` cheat sheet.
- **Fear-free deletion**: select 1–n items → `Delete` → a keyboard-first confirm sheet. **Return or Y confirms, Esc or N cancels.** Risk-proportional friction: if everything regenerates, one Return suffices; if anything is *yours*, Return goes inert and an explicit `Y` is required. Trash-only (never permanent), app-level `⌘Z` restores the whole batch. Protected system items can never enter the flow.

## DiskX vs. the alternatives

DiskX exists because we read thousands of user reviews and forum threads about the
tools below and built around what people kept asking for. If you're comparing Mac
disk space analyzers, here's an honest summary — including where the others are
genuinely better.

| Tool | Platform | Price | Approach | Where DiskX differs |
|---|---|---|---|---|
| **DiskX** | macOS 14+ | Free, open source | Treemap + keyboard list, reclaim-first sorting | Sorts by what's safe to delete, not raw size; 100 % keyboard; Trash-only with undo |
| **DaisyDisk** | macOS | ~$10 one-time | Beautiful sunburst chart, drag-to-collector deletion | DaisyDisk's sunburst is gorgeous and it's genuinely fast; DiskX trades it for an area-accurate treemap, keyboard-only operation, and explicit "safe to delete" reasoning |
| **CleanMyMac** | macOS | Subscription | Automated one-click cleanup suites | CleanMyMac automates far more (malware scan, uninstaller, maintenance); DiskX only analyzes and deletes what *you* pick, with no subscription, no telemetry, no background agents |
| **Disk Inventory X** | macOS | Free | The classic treemap that inspired this category | Disk Inventory X is effectively unmaintained and slow on modern multi-TB disks; DiskX is a native, parallel, Apple Silicon rewrite of the same idea |
| **GrandPerspective** | macOS | Free (GPL) | Long-lived, well-maintained treemap | GrandPerspective is a great free treemap; DiskX adds labeled rows, reclaim scoring, keyboard navigation and safer deletion |
| **OmniDiskSweeper** | macOS | Free | Finder-style size-sorted column browser | OmniDiskSweeper is very fast and very simple, but it **deletes permanently** and shows no visualization; DiskX always routes through the Trash and is undoable |
| **WizTree / TreeSize / WinDirStat / SpaceSniffer** | Windows | Free / paid | The Windows gold standard for fast scans | These don't exist on macOS — DiskX is the answer to "I wish there were a WizTree for Mac" |
| **ncdu / dust / gdu** | Terminal | Free | Blazing keyboard-driven TUIs | DiskX keeps ncdu's keyboard efficiency and its delete-with-confirm flow, in a native GUI with a treemap |
| **macOS Storage Settings** | Built in | Free | High-level category bars | The built-in panel famously can't explain "System Data"; the DiskX **Truth Bar** reconciles scanned files, system, purgeable and free space so the numbers add up |

**Common search terms this project answers:** mac disk space analyzer · disk usage
analyzer macOS · disk explorer Mac · treemap disk visualizer · find large files on
Mac · free up storage on MacBook · what is System Data on Mac · delete Xcode
DerivedData · clean node_modules · Disk Inventory X alternative · DaisyDisk
alternative · WizTree for Mac · ncdu GUI · open source Mac disk cleaner.

## Build & run

```bash
swift build            # debug build
swift test             # engine tests
Scripts/package_app.sh # → DiskX.app (reads version.env)
open DiskX.app
```

Grant **Full Disk Access** (System Settings → Privacy & Security) to scan `~/Library` and system paths — DiskX shows an honest "unreadable" chip instead of silently undercounting.

## App Store edition

The Mac App Store build is sandboxed: DiskX scans only locations you grant via the
folder picker (persisted as security-scoped bookmarks), starting from a welcome
screen instead of an automatic Home scan. Ship checklist:

1. **Apple Developer Program** membership; create an app record in App Store Connect
   with the bundle id from [version.env](version.env).
2. Certificates: `Apple Distribution` + `3rd Party Mac Developer Installer`; a Mac
   App Store provisioning profile saved as `Entitlements/DiskX.provisionprofile`.
3. Build the upload package:
   ```bash
   APP_IDENTITY="Apple Distribution: <Team>" \
   INSTALLER_IDENTITY="3rd Party Mac Developer Installer: <Team>" \
   Scripts/package_appstore.sh        # → DiskX-<version>.pkg
   ```
4. Upload with Transporter.app, then fill in screenshots/description/privacy
   ("Data Not Collected" — the app has no telemetry).

Already handled in-repo: App Sandbox entitlements
([Entitlements/DiskX-AppStore.entitlements](Entitlements/DiskX-AppStore.entitlements)),
privacy manifest with required-reason API declarations
([PrivacyInfo.xcprivacy](Sources/DiskX/Resources/PrivacyInfo.xcprivacy)),
app icon (Icon.icns), category/copyright/hi-res Info.plist metadata, and
sandbox-aware scanning (`AccessManager`). Direct distribution (Developer ID +
notarization, no sandbox) keeps full-disk scanning:
[Scripts/notarize_release.sh](Scripts/notarize_release.sh) builds a universal
binary, signs it with the Developer ID identity under the hardened runtime, then
notarizes and staples both the `.app` and the DMG.

## Appearance

Light, dark, and system themes — Settings (⌘,) → Appearance. All UI uses semantic
colors and Liquid Glass (macOS 26+) with material fallbacks, so both modes are
first-class.

## Architecture

| Target | Contents |
|---|---|
| `DiskXCore` | `ScanSession` (getattrlistbulk pool) · `ReclaimAnalyzer` (tiers, staleness, hotspots) · `TreemapLayout` (squarified) · `TrashEngine` (trash-only, minimal cover) · `FileNode` (lock-guarded live tree) |
| `DiskX` | SwiftUI app: `AppModel` (single brain), global `KeyboardDispatch`, views |
| `diskx-bench` | CLI scan benchmark |

## How it was built — the AI orchestration pipeline

DiskX was developed end-to-end in one session by a multi-agent orchestration
framework: three deterministic workflows fanning out **48 specialized agents**
(~3.3M tokens), coordinated by a main loop that owned the architecture,
integration, and verification.

```mermaid
flowchart LR
    subgraph W1["Workflow 1 — Research & Design (9 agents)"]
        R1["4 pain-point researchers<br/>(Disk Inventory X, DaisyDisk,<br/>WizTree/ncdu, user wishes)"] --> J
        R2["1 macOS tech researcher<br/>(getattrlistbulk, APFS, sandbox)"] --> J
        C["3 UX concept designers<br/>novice-first · keyboard-first ·<br/>visualization-innovation"] --> J
        J["Judge panel:<br/>scores concepts, synthesizes<br/>DESIGN-SPEC.md"]
    end
    subgraph M["Main loop (inline)"]
        A["Engine + AppModel contracts<br/>scanner · treemap · trash · analyzer"]
    end
    subgraph W2["Workflow 2 — Implementation (6 agents, parallel)"]
        I["file list · treemap · truth bar ·<br/>confirm sheet · chrome · QuickLook<br/>— disjoint files vs pinned API"]
    end
    subgraph W3["Workflow 3 — Adversarial Review (33 agents)"]
        F["5 dimension finders:<br/>deletion safety · scanner ABI ·<br/>concurrency · keyboard UX · perf"] --> V
        V["28 independent skeptic verifiers<br/>(one per finding, briefed to refute)"]
    end
    W1 --> M --> W2 --> W3 --> X["Main loop: fix all 28<br/>confirmed findings, package,<br/>benchmark, ship"]
```

1. **Research & design** — five researchers swept reviews, Reddit, and HN in
   parallel for the pain points of every existing disk analyzer (22 tool
   findings, 59 explicit user wishes), while a tech agent mapped the fastest
   scanning APIs. Three designers then produced competing concepts from
   different angles, and a judge agent scored them and synthesized the final
   [design spec](docs/DESIGN-SPEC.md) — the origin of Reclaim Sort, the Truth
   Bar, ghost-row hoisting, and risk-proportional deletion.
2. **Parallel implementation** — the main loop first wrote the core engine and
   pinned the `AppModel` API as a contract, then six agents implemented the
   SwiftUI modules concurrently, each owning disjoint files and verifying its
   own diagnostics. Integration and build fixes stayed in the main loop.
3. **Adversarial review** — five finder agents attacked orthogonal dimensions;
   every single finding was handed to an independent verifier instructed to
   *refute* it. 28 findings survived (0 refuted) — including six criticals like
   firmlink double-counting and a cursor/selection desync — and all 28 were
   fixed and re-verified before packaging.

The engine was additionally validated headlessly: 14 unit/integration tests
(including a real Trash round-trip) and a benchmark scanning **1.33M files in
45s (~29,000 files/sec) — 2.4× faster than `du`** on the same tree, with the
reclaim analysis over the whole tree taking a further 1.2s.

## Links

- **Website:** https://avantigroupai.github.io/diskx-web/
- **Releases:** https://github.com/avantigroupai/DiskX/releases
- **Design spec:** [docs/DESIGN-SPEC.md](docs/DESIGN-SPEC.md)

## License

Not yet licensed for redistribution — all rights reserved for now. If you want to
use DiskX in your own project, open an issue.

<sub>Keywords: macOS disk space analyzer, Mac disk usage analyzer, disk explorer,
storage analyzer, treemap disk visualizer, find large files, free up disk space,
System Data explainer, Disk Inventory X alternative, DaisyDisk alternative,
GrandPerspective alternative, OmniDiskSweeper alternative, WizTree for Mac,
ncdu GUI, open source Mac disk cleaner, Apple Silicon, SwiftUI.</sub>
