# DiskX — Design Specification v1.0

**The WizTree-fast, ncdu-friendly disk visualizer macOS never shipped.**
Base concept: Concept A (Reclaim Sort + Goal Mode + Truth Bar + risk-proportional deletion), grafted with Concept B's ghost-row hoisting, editable rules file, pre-flight deletion rigor, offload, export/CLI, and command palette, and Concept C's Strata map option, per-row WHY line, reconciliation strip, QuickLook-inside-the-confirm-sheet, and exclude-from-rescan.

Platform: macOS 14+, Swift 5.10+, SwiftUI. Distribution: Developer ID, notarized, non-sandboxed (no crippled MAS build). Free core, optional one-time-purchase Pro (menu-bar monitor, scheduled baselines). No subscription, no upsells, no telemetry, no AI.

---

## 1. Product Thesis

Every existing analyzer sorts by raw size, which puts /System and Photos Library — the things you cannot or should not touch — at the top, while the 40 GB of Xcode caches you could delete right now sits three levels deep. DiskX's default ordering answers the question users actually ask: **"What should I delete first?"** Everything else in the app — honest byte accounting, keyboard completeness, fear-free deletion, WizTree-class scan speed — exists to make acting on that answer instant and safe.

---

## 2. Window Layout

Single main window, default 1200 × 760 pt, minimum 900 × 600 pt. Native SwiftUI with unified toolbar title bar. Light/dark native. Additional windows per volume via ⌘N.

```
┌────────────────────────────────────────────────────────────────────┐
│ TOOLBAR  [Volume ▾] [Scan/Pause ◔ 38,400 files/s] [Search  ⌘F]      │
│          [Sort: Reclaim|Size|Grown|Age|Files] [View: List|Map|Both] │
│          [Basket (3)]                                               │
├────────────────────────────────────────────────────────────────────┤
│ TRUTH BAR (48 pt) — full-width stacked capacity bar + chips         │
├──────────────┬─────────────────────────────────────────────────────┤
│ SIDEBAR      │  BREADCRUMB PATH BAR                                 │
│ (⌘1, 220 pt, │ ┌───────────────────────┬───────────────────────────┐│
│ collapsible) │ │ RECLAIM LIST (44%)    │ MAP (56%)                 ││
│  Volumes     │ │ outline/table hybrid  │ Treemap or Strata icicle  ││
│  Snapshots   │ │ w/ in-row bars,       │ single Canvas, area-      ││
│  Purgeable   │ │ ghost rows, badges,   │ accurate, keyboard-       ││
│  Inaccessible│ │ WHY lines             │ navigable                 ││
│  Dev Junk    │ └───────────────────────┴───────────────────────────┘│
│  Baselines   │  INSPECTOR (I, right slide-over, 300 pt)             │
│  Smart scopes│                                                      │
├──────────────┴─────────────────────────────────────────────────────┤
│ BASKET SHELF (appears when non-empty) chips · total · Review ⌘⏎     │
├────────────────────────────────────────────────────────────────────┤
│ STATUS BAR (24 pt) — selection/marks summary · Reconciliation strip │
│  · scan stats · FDA glyph                                           │
└────────────────────────────────────────────────────────────────────┘
```

### Components

**Toolbar.** Volume popup (remembers last target; auto-rescans on launch from the cached snapshot, then delta-refreshes). Scan/Pause button with progress ring and live throughput readout ("38,400 files/s") — the speed is a visible feature. Search field (⌘F or `/`): live fuzzy filter by name, kind, date within scope; ⌥Return on a hit reveals it in the tree. Sort segmented control (5 modes, see §4). View toggle: List / Map / Both (Both is default). Basket button with count badge.

**Truth Bar** (48 pt strip under the toolbar). A full-width stacked capacity bar of the whole volume: *Your files / App data / Regenerable caches / System* (solid greys of increasing depth) · *Snapshots* (diagonal hatch) · *Purgeable* (dotted outline) · *Free* (empty). Clicking (or arrowing to) any segment filters the view and opens a plain-language explainer — including the honest ones macOS refuses to give: what "System Data" actually contains, why purgeable space takes hours to shrink, why Finder / Disk Utility / Storage Settings disagree. Right side: **"Reclaimable now: ~74 GB safe"** and a session counter ("Freed this session: 23.1 GB") that ticks up on every delete. If any directories returned EPERM, an **"inaccessible" chip** appears ("2.1 GB unreadable — grant Full Disk Access") deep-linking to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

**Sidebar** (⌘1). Volumes with segmented capacity gauges that reconcile with Finder (Scanned / Snapshots — with per-snapshot list via `tmutil listlocalsnapshots` / Purgeable / Inaccessible / Cloud-only). Below: saved **Baselines** for the Grown diff, and **Smart Scopes**: Dev Junk (cross-toolchain roll-up: DerivedData, simulators, stale node_modules, Docker.raw, Homebrew/npm/yarn/pip/cargo/gradle caches), Large & Old, Downloads, Trash contents, System Data Explained.

**Reclaim List** (primary pane; keyboard home). Row anatomy, left to right:

1. Mark margin — filled `circle.fill` glyph when x-marked; marked rows dim.
2. Monochrome SF Symbol for kind (`folder`, `doc.text`, `film`, `shippingbox` for bundles/packages) — all `currentColor`, weight/opacity for emphasis, never colour.
3. Name (type-ahead target).
4. In-row proportional bar drawn behind the row (dust-style): length = share of current folder in neutral text colour at ~15 % opacity; a darker inner segment = the reclaimable share.
5. Safety badge: `arrow.triangle.2.circlepath` regenerates · `arrow.down.circle` re-obtainable · `person` yours · `exclamationmark.triangle` review · `lock` protected.
6. Age chip ("2.4 y").
7. Primary metric right-aligned in SF Mono (reclaimable GB in Reclaim mode; allocated bytes elsewhere), logical size secondary.
8. **WHY line** (secondary text, one line): "Xcode cache — regenerates on next build · untouched 14 months · frees 21.3 GB now."

**Ghost-row hoisting** (grafted from Ledger): folders aggregate descendant reclaim ("Library — 34 GB reclaimable of 120 GB"), and any deep descendant whose reclaim dominates its ancestors is hoisted into the current level as an indented ghost row: `↳ …/Xcode/DerivedData — 18 GB, 6 levels deep`. Return on a ghost row jumps there; Delete, x, Space, and b all act on it in place. This kills repetitive drill-down — dust's insight, in a GUI.

A clickable breadcrumb path bar sits above the list; ⌘↑ walks up. Density toggle (comfortable/compact) in the View menu.

**Map pane.** Two layouts, toggled in the View menu (⌥M):

- **Treemap** (default): squarified, area exactly proportional to allocated bytes — no sunburst angle-lies. Rendered in a single SwiftUI `Canvas` from a squarified layout precomputed off the main thread (flat array of rect/shade/nodeID; thousands of rects at 60 fps). Sub-pixel cells merge into an "other" cell; labels render only above a legibility threshold. Manual hit-testing via a grid index; hover highlight drawn on a lightweight overlay Canvas so the base map never re-renders per mouse move. Hover shows a file-info readout **next to the cursor** (the explicit GrandPerspective request).
- **Strata** (grafted from Concept C): icicle/flame-graph layout — root as the full-width top band, each depth a band below, width strictly proportional to bytes. Always-horizontal labels, whole disk readable top-down in one view. Same Canvas engine, same interactions.

Shared map encoding (both layouts, pure monochrome): **brightness = safety tier** (lighter = safer to delete), diagonal hatch = snapshot-held, outline-only ghost = cloud-dataless placeholder, subtle texture variants = kind. The single system accent colour is reserved exclusively for selection/focus. Packages and bundles are drillable, never opaque blobs. Every drawn cell is exposed as an accessibility element (name + size) for VoiceOver. List cursor and map highlight are one synchronized selection — click or arrow in either, the other follows.

**Inspector** (I): QuickLook thumbnail; logical vs allocated vs clone-private size; clone/hard-link/snapshot/dataless flags; dates; full path; and the "Why this rank?" breakdown showing the exact arithmetic: "18.2 GB private × regenerates (1.0) × untouched 14 mo (1.2)".

**Basket shelf** (bottom; collapsed to a pill until non-empty): chips for staged items, running total "≈ 18.6 GB back", Review (⌘⏎) and Clear buttons.

**Status bar**: exactly what Delete would act on right now ("7 marked — 12.4 GB"), the **reconciliation strip** ("Used 412 GB = files 361 + snapshots 28 + purgeable 19 + inaccessible 4", each term clickable), scan throughput, FDA status glyph.

**Optional menu-bar extra (Pro)**: tiny capacity gauge + "grew 4.1 GB this week" from background baselines.

---

## 3. View Modes

| Mode | Trigger | Description |
|---|---|---|
| **Both** (default) | View toggle / ⌘3 | List 44 % + Map 56 %, synchronized selection, draggable split. |
| **List** | View toggle | Full-width Reclaim List; maximal density for keyboard work. |
| **Map** | View toggle | Full-window map with a thin selected-item detail strip. |
| **Flat "Top Files"** | ` (backtick) | WizTree-style File View: every individual file in scope in one ranked list, no folder rollups, current sort applied. A view transform, not a separate screen — marks, selection, and keyboard state persist. |
| **Goal Mode** | G | Overlay field pre-filled from disk pressure: "I need __ GB". A bracket appears over the top N rows: "These 7 items get you to 50 GB — all safe." Ordering is greedy-knapsack over Reclaim Score so the shortest safe path to the goal is always the visible top of the list. Esc dismisses. |
| **Map layout** | ⌥M | Toggles Treemap ↔ Strata icicle. |

---

## 4. Sorting — The Innovative Default

### 4.1 Reclaim Sort (mode 1, default on the boot volume)

Deterministic, fully inspectable, explicitly **not** AI:

```
reclaimScore = trueReclaimableBytes × safetyMultiplier × stalenessMultiplier
```

**trueReclaimableBytes — honest bytes, not du bytes.**
- Base: APFS allocated size (`ATTR_FILE_ALLOCSIZE`), hard-link-deduped by (device, inode) — only nlink > 1 files enter the sharded seen-set.
- Cloud-dataless placeholders (`SF_DATALESS`) count their real local size (~0), shown as ghosts; scanning never triggers downloads (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF` set at startup).
- APFS clones: a background refinement pass runs `ATTR_CMNEXT_PRIVATESIZE` on the top ~500 candidates so displayed figures converge live from "~11.2 GB" to exact ("18 GB file — only 1.2 GB private, rest shared with a clone").
- Snapshot-held bytes are split out with an inline flag: "held by a snapshot until Jul 16 — deleting frees space then." This kills the category's #1 trust-killer: "I deleted 20 GB and freed nothing."

**safetyMultiplier — signed, on-device, user-editable rules** (human-readable file at `~/Library/Application Support/DiskX/reclaim-rules.yaml`; signed defaults, updatable, auditable, scriptable):

| Tier | Weight | Examples | Badge |
|---|---|---|---|
| Regenerates | 1.0 | DerivedData, simulators, node_modules beside a stale package.json, Docker prunable layers, ~/Library/Caches, brew/npm/pip/cargo/gradle caches, browser caches | `arrow.triangle.2.circlepath` + "Xcode rebuilds this automatically" |
| Re-obtainable | 0.8 | .dmg/.pkg installers whose app is installed, archives with the expanded folder alongside, superseded iOS backups | `arrow.down.circle` |
| Yours — review | 0.5 | App data, project directories | `exclamationmark.triangle` |
| Cold personal | 0.35 | Your own files untouched > 1 year — labelled "yours, just old", never "junk" | `person` |
| Applications | 0.15 | App bundles — Delete routes to a leftover-aware uninstall action | `shippingbox` |
| Protected | 0.02, unrankable for deletion | /System, SIP paths, root-owned, firmlink duplicates — **never hidden** (hiding loses trust), demoted to a greyed section, lock-badged, unselectable for deletion | `lock` |

Every classification shows its reasoning in the WHY line. Nothing is ever auto-deleted.

**stalenessMultiplier** — from max(lastAccessed via `kMDItemLastUsedDate` when available, lastModified): < 30 d = 0.5 · 30–180 d = 0.8 · 180 d–1 y = 1.0 · 1–3 y = 1.5 · > 3 y = 2.0 (capped). Bakes "Large & Old" into the default ordering.

The **displayed number is always honest gigabytes-reclaimable**, never an abstract score; the score only orders rows. `I` on any row shows the exact arithmetic.

### 4.2 All sort modes (keys 1–5; S cycles; same key again reverses)

1. **Reclaim** (default) — as above.
2. **Size** — allocated bytes descending, logical shown secondary. Default on external/network volumes where the ruleset does not apply.
3. **Grown** — diff vs the automatically kept baseline of the previous scan (plus user-saved baselines), with Grew / New / Shrank / Removed badges. Answers the "my disk filled overnight" panic.
4. **Forgotten** — staleness × size, pure Large & Old, no safety weighting.
5. **Name/Kind** — alphabetical with kind grouping; also Count sub-order for inode hogs (node_modules).

Sort mode, scope, view, and volume persist across launches. Sorts are lenses over one ledger: same rows, same marks, same keyboard state; re-sorts animate gently with selection preserved.

---

## 5. Complete Keyboard Map

Philosophy: 100 % of the app operates without a mouse. Every command also lives in the menu bar with its shortcut. `?` shows a searchable full-screen cheat-sheet overlay. ⌘K opens a fuzzy command palette listing everything.

### Focus
| Key | Action |
|---|---|
| Tab / ⇧Tab | Cycle panes: List → Map → Sidebar → Shelf (accent focus ring on the focused pane) |
| ⌘1 | Toggle sidebar |
| ⌘2 | Focus list |
| ⌘3 | Toggle map pane |
| ⌘4 | Toggle Basket shelf |

### Navigate — List
| Key | Action |
|---|---|
| ↑ / ↓ (k / j) | Move cursor |
| → / Return (l) | Descend into folder or package; Return on a file = QuickLook; Return on a ghost row = jump to its real location |
| ← / ⌘↑ (h) | Ascend to parent |
| Home / End | First / last |
| ⌥↑ / ⌥↓ | Page |
| type-ahead | Jump to matching name |
| ⌘⇧. | Toggle hidden files |

### Navigate — Map (when focused)
| Key | Action |
|---|---|
| Arrows | Move to the **geometrically neighboring rectangle** (the literal App Store wish); in Strata: ←/→ siblings, ↓ largest child, ↑ parent band |
| Return | Zoom into the focused cell's folder |
| Esc | Zoom out one level |
| Space / X / Delete / I / B | Work identically to the list; list selection follows the map cursor |

### Select and mark
| Key | Action |
|---|---|
| ⇧↑ / ⇧↓ | Extend contiguous selection |
| ⌘A | Select all in scope |
| X | Toggle persistent mark on current row and advance (dua-cli style; marks survive navigation, lens switches, and view toggles) |
| ⇧X | Clear all marks |
| Esc | Clear selection/marks (first press), then zoom out (second) |

Marks take precedence over highlight; the status bar always states exactly what Delete will act on.

### Inspect
| Key | Action |
|---|---|
| Space | QuickLook (QLPreviewPanel via responder-chain bridge; genie zoom from the row/cell; arrows flip through the selection while open; Space closes) |
| I | Inspector / "Why this rank?" |
| ⇧⌘R / E | Reveal in Finder |
| ⌘O | Open with default app |
| ⌘C | Copy full path (⌥⌘C copies row as TSV) |

### Act
| Key | Action |
|---|---|
| Delete / Backspace / D | Trash flow on marks (or selection if no marks) — see §7 |
| ⌥Delete | Explicit permanent-delete path, extra-guarded (§7.5) |
| B | Stage selection/marks into the Basket |
| ⌘⏎ | Review and commit Basket |
| ⌘Z | Undo last trash batch (app-level Put Back via recorded Trash URLs) |
| ⇧⌘O | **Offload**: move selection to another volume instead of deleting |
| ⌦ (in Basket review) | Remove item from batch |
| ⌘E | Export scope as CSV / JSON (free, no Pro gate) |
| — | Exclude item from future rescans (context menu + palette) |

### Sort and view
| Key | Action |
|---|---|
| 1–5 | Reclaim · Size · Grown · Forgotten · Name/Kind |
| S | Cycle sorts; same sort again reverses |
| ` | Toggle flat Top Files view |
| ⌥M | Toggle Treemap ↔ Strata |
| G | Goal Mode |
| / or ⌘F | Search/filter (Esc clears and returns focus to list) |
| ⌘K | Command palette |

### Scan and app
| Key | Action |
|---|---|
| ⌘R | Delta-rescan of selected subtree; ⇧⌘R full rescan |
| ⌘. or P | Pause / resume scan |
| ⌘N | New window on another volume |
| ⌘, | Settings · ⌘/ Help · ? cheat sheet |

### Dialog rules (every dialog in the app)
Return or **Y** confirms · Esc or **N** cancels — bare keys, no modifiers, exactly like ncdu. ↑/↓ scroll lists inside sheets without moving button focus; Tab moves between controls; Space QuickLooks a listed item from inside a sheet. Risky variants disable Return (§7). **No dialog ever requires the mouse.**

A `diskx` CLI ships alongside (headless scan/export, honoring the same rules file).

---

## 6. Scan Engine UX

**Engine.** Parallel `getattrlistbulk` enumeration: each directory opened with `open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)`; attrs `ATTR_CMN_RETURNED_ATTRS | NAME | ERROR | OBJTYPE | FILEID` + `ATTR_FILE_ALLOCSIZE | LINKCOUNT | DATALENGTH`; ~128 KB buffers. Bounded work-stealing pool of dedicated threads (≈ 32–64 in-flight directories) — never the Swift Concurrency cooperative pool for blocking syscalls. Per-entry `ATTR_CMN_RETURNED_ATTRS` check with fts/lstat fallback per subtree (SMB/NFS/FAT). Physical traversal only; prune on device-ID change (firmlinks, mounts). Sharded (dev, inode) set for hard-link dedup. `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` at startup. Per-thread aggregation, merged snapshots.

**Experience.**
- **Never a blank wait.** Results stream progressively: first rows within one second; rows appear and re-rank with gentle spring animation; map cells grow live (SpaceSniffer delight). Target: full 1 TB internal SSD in 10–30 s.
- Progress: toolbar ring + live "38,400 files/s · 3.1 GB/s" readout. UI updates batched at 10–30 Hz snapshots via AsyncStream — never per-file publishes.
- **Pause/resume** (⌘. or P, and the toolbar pill).
- **Remembers the last volume/scope** and auto-scans on launch from the cached snapshot, then delta-refreshes.
- Every completed scan automatically becomes a **baseline** for the Grown sort; users can pin named baselines.
- **No rescan tax**: after any deletion the in-memory model updates in place — rows animate out, ancestor totals, Truth Bar, gauges, and map reflow live.
- Targeted rescan of a selected subtree only (⌘R).
- Permission errors are recorded per directory and surfaced as the "inaccessible" bucket — never silent undercounting. FDA onboarding: probe a known protected path, show honest explainer UI, deep-link to System Settings, advise relaunch. Permission prompts are queued, never allowed to interrupt a running scan.
- Totals are reconciled against `volumeAvailableCapacity*` / `volumeTotalCapacity` keys so DiskX's numbers visibly agree with Finder via the reconciliation strip.

---

## 7. Deletion Flow (multi-select → Delete → keyboard-confirmable dialog)

**Step 1 — Select 1–n items.** Any mix of ⇧-arrow contiguous selection, X-marks gathered while roaming (across folders, lenses, and views), ⌘A, ⌘-click, or Basket staging (B). Status bar live-shows "6 items — ~11.4 GB reclaimable."

**Step 2 — Press Delete (or Backspace, or D).** Pre-flight (async, typically < 100 ms), grafted from Ledger's rigor:
- Re-stat every path (TOCTOU guard). Changed sizes get amber notes ("size changed since scan: 2.1 → 3.4 GB"); vanished items are dropped with a note; root-owned/protected items move to a "cannot be trashed" section rather than being silently skipped; no-Trash volumes are detected.
- A fast PRIVATESIZE pass runs so the promised number is the truth, not the scan-time estimate.

**Step 3 — Confirmation sheet** (native sheet, keyboard-focused from the first frame):
- Title: "Move 6 items to Trash?"
- Honest math subtitle: "Frees about 11.4 GB now — 10.1 GB private, 1.3 GB shared with clones." Snapshot note where relevant: "3.2 GB is held by a Time Machine snapshot and frees on Jul 16." If everything regenerates: "All of these are safe — apps rebuild them automatically."
- Scrollable list of every item with monochrome icon, path, size, safety badge, and any amber notes. ↑/↓ scroll without moving button focus; **Space QuickLooks any listed item without leaving the sheet** (from Strata — the last-chance "what am I about to delete" check).
- Buttons: **Move to Trash** (default) and Cancel, visible focus ring.
- **Keyboard: Return or Y confirms; Esc or N cancels.** Y/N work bare regardless of button focus. Cancel preserves marks.
- **Risk-proportional friction** (the signature mechanic): if every item is tier "regenerates/re-obtainable," one Return confirms. If any item is tier "review" or contains > 10 k files, the default flips to Cancel, **Return goes inert**, and confirming requires an explicit **Y** (or Tab/arrow + Space). Safe deletes stay one keystroke; scary ones need one deliberate keystroke more. Protected items can never enter the flow.
- Optional checkbox (Tab + Space): "Don't ask again for regenerable caches this session" — Regenerates tier only.

**Step 4 — Execute.** `FileManager.trashItem(at:resultingItemURL:)` per item — never permanent by default — with resulting Trash URLs recorded. Inline progress if > 1 s. Per-item failures are listed after the batch; successes proceed. Rows animate out; every ancestor size, the Truth Bar, sidebar gauges, and the map update in place — **no rescan**. Toast: "Moved 6 items to Trash — 11.4 GB frees when the Trash empties · ⌘Z to undo." ⌘Z restores the entire batch from the recorded URLs (app-level Put Back, immune to macOS's broken batch Put Back). The sidebar Trash bucket shows "11.4 GB recoverable in Trash," and DiskX links to Finder's Empty Trash rather than hard-deleting on its own.

**Step 5 — Permanent-delete fallback.** On volumes with no .Trashes (some SMB/exFAT), or via explicit ⌥Delete, the sheet switches to a visually distinct destructive variant: "Permanently delete 3 items? This cannot be undone." Cancel is default; **Return and bare Y are disabled**; confirming requires **⌘Return** (hint rendered in the button: "⌘Return to delete") or Tab + Space on the red button. Esc/N always cancels. Root-owned files are reported plainly ("owned by the system — DiskX won't escalate privileges") with a Reveal in Finder offer.

**Step 6 — Basket variant.** B stages items across the whole session (DaisyDisk's Collector, minus the mouse); ⌘⏎ opens a full review sheet — same rules, per-item removal with ⌦, Space-QuickLook — then one Return/Y trashes the batch.

**Non-destructive alternative.** ⇧⌘O **offloads** (moves) the selection to another volume instead of deleting — the wish of video/design/archive users, from Ledger.

---

## 8. Safety Features (summary)

1. Trash-first always; permanent delete only behind the ⌘Return-gated explicit path.
2. App-level batch undo (⌘Z) via recorded Trash URLs.
3. Pre-flight re-stat + fresh reclaim math at confirm time (TOCTOU-proof).
4. Risk-proportional confirm friction; protected/system items visible but lock-badged and unselectable.
5. Every classification explains itself (WHY line + inspectable arithmetic + editable rules file); nothing ever auto-deletes.
6. Cloud placeholders never downloaded; snapshot-held space never over-promised; honest reconciliation with Finder totals.
7. App-bundle deletion routes to leftover-aware uninstall.
8. Per-item failure reporting; no silent skips, no silent privilege escalation.
9. Full VoiceOver support: rows and map cells expose name, size, and safety tier; sizes are spoken.

---

## 9. Visual Design Notes

- **Native macOS throughout**: SwiftUI, unified toolbar, native sheets/popovers/menus, system focus rings, full menu bar with every shortcut, Settings via ⌘,. Light/dark native.
- **Monochrome SF Symbols only** — every glyph is a single-colour font icon inheriting `currentColor`. No coloured fills, no coloured glows, no multicolour or emoji icons, anywhere (UI, dialogs, menu-bar extra, docs).
- Hierarchy is expressed with **shade, hatch, texture, and weight — never hue**: safety tier = brightness ramp; snapshots = diagonal hatch; cloud ghosts = outline-only; kind = subtle texture. The single system accent colour is reserved exclusively for selection and focus.
- Typography: SF Pro for text; **SF Mono for all byte counts** so columns align. Secondary text for WHY lines.
- Motion: gentle spring re-ranks during scan streaming, rows animate out on delete, map cells grow/shrink organically — always subdued, never showy; respects Reduce Motion.
- Density: comfortable/compact list toggle; in-row bars at ~15 % opacity keep the ledger scannable, not noisy.
- The treemap/Strata Canvas draws from a precomputed layout; hover highlights live on an overlay layer; labels only above legibility thresholds; sub-pixel cells merge into "other."
- Trust surface: Developer ID + notarized (no Gatekeeper friction), no subscription, no upsell nags, no telemetry, no AI — stated plainly in onboarding and About.

---

## 10. Out of Scope for v1 (explicitly deferred)

Duplicate-file hashing pass (opt-in, v1.x) · scheduled background baselines beyond the previous-scan auto-baseline (Pro) · menu-bar extra (Pro) · AppleScript dictionary · network-share scan optimizations beyond the fts fallback.