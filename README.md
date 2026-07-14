# DiskX

**The WizTree-fast, ncdu-friendly disk visualizer macOS never shipped.**

Every existing analyzer sorts by raw size, which puts `/System` and your Photos Library — the things you cannot or should not touch — at the top, while the 40 GB of Xcode caches you could delete right now sits three levels deep. DiskX's default ordering answers the question users actually ask: **"What should I delete first?"**

## Highlights

- **Reclaim Sort** (default): rows ordered by `reclaimable bytes × safety tier × staleness` — deterministic, inspectable, never AI. The displayed number is always honest gigabytes, never an abstract score. Every row has a plain-language **WHY line** ("Xcode cache — regenerates on next build · untouched 14 months · frees 21.3 GB now").
- **Ghost-row hoisting**: deep junk (`DerivedData`, `node_modules`, …) is hoisted into the current level as `↳ …/Xcode/DerivedData · 6 levels deep` — no repetitive drill-down.
- **Truth Bar**: honest capacity accounting that reconciles with Finder — scanned files, "Other & System" (the System Data mystery, explained), purgeable, free. Plus "Reclaimable now: ~X safe" and a freed-this-session counter.
- **WizTree-class scanning**: parallel `getattrlistbulk` work-stealing pool; hard links deduped by inode; live streaming results — never a blank wait.
- **100 % keyboard**: `↑↓/jk` move · `→/Return` descend · `←/⌘↑` up · `X` mark across folders · `Space` QuickLook · `1–5` sorts · `` ` `` flat Top-Files view · `G` goal mode ("I need 25 GB back") · `?` cheat sheet.
- **Fear-free deletion**: select 1–n items → `Delete` → a keyboard-first confirm sheet. **Return or Y confirms, Esc or N cancels.** Risk-proportional friction: if everything regenerates, one Return suffices; if anything is *yours*, Return goes inert and an explicit `Y` is required. Trash-only (never permanent), app-level `⌘Z` restores the whole batch. Protected system items can never enter the flow.

## Build & run

```bash
swift build            # debug build
swift test             # engine tests
Scripts/package_app.sh # → DiskX.app (reads version.env)
open DiskX.app
```

Grant **Full Disk Access** (System Settings → Privacy & Security) to scan `~/Library` and system paths — DiskX shows an honest "unreadable" chip instead of silently undercounting.

## Architecture

| Target | Contents |
|---|---|
| `DiskXCore` | `ScanSession` (getattrlistbulk pool) · `ReclaimAnalyzer` (tiers, staleness, hotspots) · `TreemapLayout` (squarified) · `TrashEngine` (trash-only, minimal cover) · `FileNode` (lock-guarded live tree) |
| `DiskX` | SwiftUI app: `AppModel` (single brain), global `KeyboardDispatch`, views |
| `diskx-bench` | CLI scan benchmark |

Built with a multi-agent AI orchestration pipeline: research fan-out → judge-panel design synthesis → parallel module implementation → adversarial review.
