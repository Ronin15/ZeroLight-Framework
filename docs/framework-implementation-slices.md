# Framework Implementation Slices

The roadmap index and agent implementation contract. Work is organized as
numbered **slices**: one complete, verifiable feature each, with a **Goal**,
**Checklist**, and **Acceptance checks**. Technical rules live only in
`.claude/rules/`; this file holds roadmap process, and slice files hold intent
and data (section shape below), never rules or designs.

**Layout.** Each open slice or sub-slice is one file under
[`roadmap/slices/`](roadmap/slices/); settled slices are one file each under
[`roadmap/archive/`](roadmap/archive/) (index:
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md)).
Tracks in [`roadmap/tracks/`](roadmap/tracks/):
[VoidLight port](roadmap/tracks/voidlight-port.md) (shared contracts,
authoritative Tables T1–T6), [Emergent AI](roadmap/tracks/emergent-ai.md),
[Long-term gameplay direction](roadmap/tracks/gameplay-direction.md). Measured
pressure points: [Scaling Gaps](roadmap/scaling-gaps.md).

**Reading rule.** To implement a slice, read this index, the one slice file
(its header line names dependencies and track), and only the track/contract
files it links. Do not load the whole roadmap.

## Ground Rules

- Keep runnable defaults: `zig build`, `zig build run`, and installed assets
  work after every slice.
- **A slice is complete only when every Checklist and Acceptance item in its
  file is `[x]`** and runtime behavior, diagnostics, owning-module docs, and
  tests are integrated. Partial wiring stays `[ ]` with remaining notes in the
  slice file. Landed slices awaiting manual/`gpu-smoke` confirmation (33, 43) stay open
  until that residual closes.
- **A slice is small:** one feature, one owning area, designed, landed, and
  reviewed as one batch. Larger work is several slices.
- **One file per slice or sub-slice** (`slices/slice-<id>.md`, lowercase id;
  umbrellas such as `slice-64.md` summarize their sub-slices), each with exactly
  one row in the Open Frontier Slice Index that links to it.
- **Completed slices move to the archive:** `git mv` the file to
  `roadmap/archive/`, move its row to the
  [archive index](framework-implementation-slices-archive.md), and update the
  Suggested Order annotation. Never delete acceptance history.
- **No backlog dumping.** Design and review never park follow-ups as bare
  Scaling Gaps/backlog lines: each becomes a Checklist item in its owning slice
  or a new slice stated as intent and constraints (Status may be "gated on
  <trigger>").
  Scaling Gaps holds only measured pressure points awaiting a benchmark. "Out
  of scope" names the owning slice. Agent briefs never ask for Scaling Gaps
  lines. Only the owner adds [**Deferred By Owner**](#deferred-by-owner)
  entries.
- When a dependency does not exist yet, label the work foundation/preparation
  and leave the checklist open. Scaffolding counts only when it lands the final
  owner modules, storage defaults, validation, and tests that preserve current
  behavior; say what is scaffolded and where future behavior hooks in, and
  never document deferred behavior as complete. No half-wired states: finish
  end to end or keep every open item visible in the slice file.
- Read [architecture.md](architecture.md) and the live owning modules first.
  The rules and architecture.md win over code; code that disagrees with them
  is wrong. Code wins over a stale Current foundation. Module placement
  follows architecture.md § Source Layout.
- Every slice follows the rules in `.claude/rules/`; a slice cites a rule file
  and never restates or adds a rule. A slice that needs a new rule has a
  checklist item to add it to the owning rule file when it lands. The planned
  merged stage order is Table T4.
- Do not promote threaded stage overlap, render-collect scan changes, or
  persistence beyond Slice 46's stable-ID boundary into a checklist until
  confirmed in the live modules. Slice 46 is the save/load
  slice; Slice 54 settings are app preferences, never save data. A slice adding
  persistent `DataSystem`/`WorldSystem` state classifies it in Slice 49's
  checksum completeness lists (and 64B's classification) and adds its Slice 46
  save section in the same change.
- Version numbers (replay format and flag bits, settings schema, save format,
  checksum tag), `stage_order` positions, and component tags follow Tables
  T1–T6 in the [VoidLight port track](roadmap/tracks/voidlight-port.md); a slice
  that changes one updates the table in the same change.
- Validate per `.claude/rules/build-validation.md`; `zig build verify` passes
  before a slice is complete.

## Agent Workflow: Implementing A Slice

1. **Pick a slice** from the Open Frontier Slice Index or the Suggested Order;
   confirm the prerequisites in its header line are settled.
2. **Open the slice file** (or a landed prerequisite's archive file). Read
   **Goal**, **Current foundation**, and **Architecture notes**, plus
   architecture.md, the header's track file, and any doc the slice links; no
   other slice files unless linked.
3. **Design pass, right before implementation.** `zig-design-specialist`
   works out how to build the slice. The design goes to the implementer, not
   into the slice.
4. **Implement only that slice's scope** in the owning `src/` modules.
5. **Review before commit** (`CLAUDE.md` § Agent Pipeline); fixes fold into
   the commit.
6. **Check off Checklist items** as each lands with its tests. Items marked
   "(added by Slice N)" are part of this slice's scope.
7. **Pass every Acceptance check.**
8. **Update durable docs** (`architecture.md`, rendering/sim docs) when
   contracts change, and Tables T1–T6 when a number moves.
9. **Set Status**, run `zig build verify`, and when complete archive the file
   (Ground Rules). Follow-ups go into a slice Checklist or a new slice file.

### Standard slice section shape

| Block | Agent use |
| --- | --- |
| Header line | Roadmap index link · Depends on (linked slices) · Track |
| **Goal** | What "done" means for this chunk |
| **Current foundation** | What already exists; build on it unless it fails the cost model (`.claude/rules/engine-design.md`), then replace the failing part |
| **Architecture notes** / **Problem** | Constraints and ownership boundaries, citing rule files; never an internal design |
| **Checklist** | `[ ]` / `[x]` intent-level steps — check off as you land each |
| **Acceptance checks** | `[ ]` / `[x]` verification gates — all required before complete |
| **Status** | One line near the top: open/partial note, or a completion record before the archive move |

Some fields are optional for early foundation slices. Slices hold intent and
data only: goal, current-code facts, measured numbers, owner decisions,
constraints, checklist, and acceptance. A measured number is one line naming
its bench group and the commit it was taken at, kept only while a decision or
acceptance check depends on it. They carry no rules, internal designs
(structs, field layouts, algorithms, batch scripts, other slices' internals),
review logs, bench tables or run logs, dated status logs, or superseded
designs (those go in commit messages and changelogs). A slice states what it needs from another
slice as an outcome, never that slice's internals. Index rows are one short
line of open work. A checked item is one line naming what landed. A
slice may land across several commits, one per logical change.

## Open Frontier Slice Index

Choose the next slice here; **implement from its file**. Settled history is in
the [archive](framework-implementation-slices-archive.md).

| Slice | Status | Open work (see the slice file for the full Checklist) |
| --- | --- | --- |
| [**33**](roadmap/slices/slice-33.md) | Landed (visual verification pending) | Data-Driven AI Archetypes And Debug Introspection |
| [**35**](roadmap/slices/slice-35.md) | Not started | AI And Steering Hot-Loop SIMD Restructure — after 55, 52D |
| [**38**](roadmap/slices/slice-38.md) | Not started | Elevation Above The Surface — after 64G |
| [**42**](roadmap/slices/slice-42.md) | Not started | Affect Expansion — More Feelings, Coupling, And Mood — after 73, 56, 61, 59 |
| [**43**](roadmap/slices/slice-43.md) | Landed (hardware verification pending) | SDL3 Gamepad/Controller Support |
| [**44**](roadmap/slices/slice-44.md) | Not started | Input Rebinding And Extended Gamepad Controls — after 53B, 54 |
| [**46**](roadmap/slices/slice-46.md) | Not started | Save/Load Persistence — after 49, 51, 53B, 54, 64B, 64G, 74 |
| [**49**](roadmap/slices/slice-49.md) | In progress | Session Seed And Determinism Checksum Harness — after 64G |
| [**50**](roadmap/slices/slice-50.md) | Not started | Thread System Hardening |
| [**51**](roadmap/slices/slice-51.md) | Not started | Background Job Lane With Deterministic Step Handoff — after 49, 50, 64A |
| [**52**](roadmap/slices/slice-52.md) | Not started (umbrella) | Release Build Baseline, Pinned Dependencies, And CI — after 49 |
| [**52A**](roadmap/slices/slice-52a.md) | In progress | Release CPU Baseline, Toolchain Pins, Pinned SDL, Committed Shaders |
| [**52B**](roadmap/slices/slice-52b.md) | Not started | Platform Packaging Layouts — after 52A |
| [**52C**](roadmap/slices/slice-52c.md) | Not started | CI Workflows And Release Performance Baseline — after 52A, 49, 50, 52B |
| [**52D**](roadmap/slices/slice-52d.md) | Not started | SIMD Layer Codegen For The v2 Release Baseline — after 52A |
| [**53A**](roadmap/slices/slice-53a.md) | Not started | Scalable GPU Text Labels |
| [**53B**](roadmap/slices/slice-53b.md) | Not started | UI Widget Toolkit, Menu Migration, And HUD Primitives — after 53A |
| [**54**](roadmap/slices/slice-54.md) | Not started | Persistent Settings — after 53B, 52B |
| [**55**](roadmap/slices/slice-55.md) | Not started | Cognition Think-Interval Coasting (Decision LOD) — after 73 |
| [**56**](roadmap/slices/slice-56.md) | Not started | Health, Damage, And Combat Domain Controller — after 49, 73 |
| [**56B**](roadmap/slices/slice-56b.md) | Not started | Projectiles And Ranged Combat — after 56 |
| [**57**](roadmap/slices/slice-57.md) | Not started | Items, Inventory, And Equipment — after 56, 49, 59 |
| [**57B**](roadmap/slices/slice-57b.md) | Not started | Inventory And Equipment UI — after 53A, 53B, 57, 49, 64C |
| [**58**](roadmap/slices/slice-58.md) | Not started | Seeded Procedural World Generation — after 49, 57, 61, 64G |
| [**59**](roadmap/slices/slice-59.md) | Not started | Game Time, Day/Night Cycle, Seasons, And Weather — after 49, 60 |
| [**60**](roadmap/slices/slice-60.md) | Not started | Camera Behavior And Scene Composite Pass — after 49, 54, 70A |
| [**61**](roadmap/slices/slice-61.md) | Not started | Harvesting And World Resource Nodes — after 73, 56, 57, 49 |
| [**62**](roadmap/slices/slice-62.md) | Not started | NPC Population, Spawning, And Spawn Tables — after 49, 57, 58, 59, 63, 64G, 75 |
| [**63**](roadmap/slices/slice-63.md) | Not started | Social Relationships And Trade — after 73, 53B, 56, 57, 57B, 61 |
| [**64**](roadmap/slices/slice-64.md) | Not started (umbrella) | Cross-Machine Determinism Completion And Replay Tooling — after 49, 50, 51, 52D, 53B |
| [**64A**](roadmap/slices/slice-64a.md) | Not started | Simulation-Invisible Pause, Float Min/Max Policy, And FP Environment Assertion — after 49, 52D |
| [**64B**](roadmap/slices/slice-64b.md) | Not started | Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage — after 49, 50, 64A, 64G, 74 |
| [**64C**](roadmap/slices/slice-64c.md) | Not started | Headless Replay Runner, Session Descriptor, And New Game Seed Flow — after 49, 51, 53B, 64A, 64B, 74 |
| [**64D**](roadmap/slices/slice-64d.md) | Gated: first simulation `atan2` consumer | Deterministic Vector `atan2` — after 52D |
| [**64G**](roadmap/slices/slice-64g.md) | In progress | Chunk-Owned Terrain And Nav |
| [**65**](roadmap/slices/slice-65.md) | Not started (umbrella) | Threading Layout Cleanup And Background-Lane Heavy Consumers — after 50, 51 |
| [**65A**](roadmap/slices/slice-65a.md) | Not started | Thread-Shared Layout Consolidation And Background-Lane OS Priority — after 50, 51 |
| [**65B**](roadmap/slices/slice-65b.md) | Not started | Deferred Nav Rebuild On The Background Lane — after 51, 65A, 64G, 49, 64B |
| [**65C**](roadmap/slices/slice-65c.md) | Not started | Streaming Worldgen On The Background Lane — after 58, 53B, 51, 74 |
| [**66**](roadmap/slices/slice-66.md) | Not started (umbrella) | Distribution, Signing, Symbols, And Store Delivery — after 52B, 52C, 54 |
| [**66A**](roadmap/slices/slice-66a.md) | Not started | Shipped-Build Crash Triage — Split Symbols, Symbol Store, Crash Reports, Linux Window Icon — after 52B, 52C, 54 |
| [**66B**](roadmap/slices/slice-66b.md) | Gated: per target | Additional Package Targets — macOS universal2, aarch64-linux, aarch64-windows — after 66A, 64C, 52A |
| [**66C**](roadmap/slices/slice-66c.md) | Gated: first public release outside Steam | Signing, Notarization, .dmg, And Linux AppImage — after 66A |
| [**66D**](roadmap/slices/slice-66d.md) | Gated: a Steamworks app ID | SteamPipe Upload Automation — after 66A |
| [**66E**](roadmap/slices/slice-66e.md) | Gated: first release-candidate tag | Authoritative Perf Runner — after 52C |
| [**67**](roadmap/slices/slice-67.md) | Not started (umbrella) | UI, Input, And Text Completion — after 53A, 53B, 54, 44, 46, 60 |
| [**67A**](roadmap/slices/slice-67a.md) | Not started | Pointer Input, Menu Hold-To-Repeat, And Scancode Bindings — after 53B, 54, 44 |
| [**67B**](roadmap/slices/slice-67b.md) | Not started | Debug Text Migration, Event Log, Text Atlas Telemetry, And UI Sound Cues — after 53A, 53B, 44 |
| [**67C**](roadmap/slices/slice-67c.md) | Not started | Save Slot Presentation — Thumbnails, Named Saves, And The Text-Input Widget — after 46, 60, 67A |
| [**67E**](roadmap/slices/slice-67e.md) | Not started | Localization Roots — after 53B |
| [**68A**](roadmap/slices/slice-68a.md) | Not started | Battle-Scale Hardening — Shared Entity Table, Action-Bus Fairness, Control Re-Baseline — after 55, 56, 75 |
| [**68B**](roadmap/slices/slice-68b.md) | Not started | Knockback Impulses And Retaliation Memory — after 73, 55, 56, 56B, 49 |
| [**68C**](roadmap/slices/slice-68c.md) | Not started | Carried-Inventory Death Drop And Ranged Ammo — after 56B, 57, 61 |
| [**69**](roadmap/slices/slice-69.md) | Not started (umbrella) | World Generation Breadth And Regional Environment — after 58, 59 |
| [**69A**](roadmap/slices/slice-69a.md) | Not started | Worldgen Breadth — Caves, Structures And Villages, Autotile Edge Sets — after 58, 61, 62, 65C, 64G |
| [**69B**](roadmap/slices/slice-69b.md) | Not started | Regional (Biome) Weather — after 58, 59, 60 |
| [**69C**](roadmap/slices/slice-69c.md) | Not started | Time Skip — after 59, 49, 75, 64B, 67B, 67E, 57B |
| [**69D**](roadmap/slices/slice-69d.md) | Gated: first scripted-weather consumer | Scripted Weather Override — after 59, 69B |
| [**69E**](roadmap/slices/slice-69e.md) | Gated: benches show off-view weather is a measurable cost share | Per-Zoom Weather Spawn Rect — after 59, 60 |
| [**69F**](roadmap/slices/slice-69f.md) | Gated: worlds that cannot hold every chunk expanded in memory | Chunk Storage Forms For Large Worlds — after 64G, 58, 46, 74, 75 |
| [**70**](roadmap/slices/slice-70.md) | Not started (umbrella) | Presentation Polish And Sprite Vertex Compaction — after 60, 54, 44 |
| [**70A**](roadmap/slices/slice-70a.md) | Not started | Sprite Vertex Compaction (Indexed Quads, Packed Color) |
| [**70B**](roadmap/slices/slice-70b.md) | Not started | Presentation Polish (Runtime Scene Resolution, Pad Zoom, Fade-Out, Sharp-Bilinear, Zoom Tween) — after 60, 54, 44 |
| [**71**](roadmap/slices/slice-71.md) | Not started (umbrella) | AI Behavior Parity And Navigation/Collision Static Fast Paths — after 71A, 71B, 71C, 71D |
| [**71A**](roadmap/slices/slice-71a.md) | Not started | AI Behavior Parity — Patrol, Follow, Guard — after 73, 55, 56, 61, 62, 63 |
| [**71B**](roadmap/slices/slice-71b.md) | In progress | Static Collider Index, Collision Static Split, And Group-Field Prewarm — after 64G, 62, 71A |
| [**71C**](roadmap/slices/slice-71c.md) | Not started | Cover-Aware Flee And Ranged Pursue (`cover` Interest Markers) — after 73, 56B |
| [**71D**](roadmap/slices/slice-71d.md) | Not started | AI Merchant Selling (Forage → Sell Loop) — after 73, 63, 61, 57, 56, 55, 71A |
| [**72**](roadmap/slices/slice-72.md) | In progress | Live Capacity Sizing Pass — F and G re-scoped after 64G |
| [**73**](roadmap/slices/slice-73.md) | Not started | Data-Driven Cognition — after 49 |
| [**74**](roadmap/slices/slice-74.md) | Not started | World Instances — after 64G, 49, 50, 75 |
| [**75**](roadmap/slices/slice-75.md) | Not started | Far Simulation — after 64G, 73 |
| [**76**](roadmap/slices/slice-76.md) | Not started | Cave-Ins — after 64G |
| [**77**](roadmap/slices/slice-77.md) | Not started | Explosions — after 64G, 76 |
| [**78**](roadmap/slices/slice-78.md) | Not started | Comptime Assessment — independent |

**Recently settled (archive only):** 37, 48, 47, 45, 40, 39, 41, 32, 8, 18–25E, 26–31, 34, 36 (plus 0–7, 9–17).

**Benches:** `.claude/rules/tests-benchmarks.md`. `frame-battle` (Slice 52C:
full fixed step plus CPU render-prep) tracks scaling shape across commits; 66E
adds the self-hosted perf runner.

## Next Priority Tracks

Sequencing hints only; slice Checklists and the Suggested Order govern.
Locomotion emergence is closed (archive 26–32, 39, 41, 47, 48; 33 visual
residual only); open work grows beside that loop.

| Track | Slices | Focus |
| --- | --- | --- |
| **Fully simulated worlds** | **64G** → **73** → **75** → **74** (74 after 50) | Chunk-owned terrain and nav, data-driven cognition, fidelity by distance from the observer, and world instances created, stepped, and destroyed in play. |
| **Determinism & threading** | **49** → **50** → **52A–52D** → **64A** → **51** → **65A** → **64B** → **64C** → **65B** (65C after 58 and 74; 64D gated) | Seeded sessions, checksum and replay over every world, cross-machine determinism, and lane consumers. |
| **Perf** | **72**, **55**, **35**, **70A**, **71B**, **68A** | Behavior independent of physical capacity, decision cadence, AI/steering math, sprite bandwidth, shared entity tables, static fast paths. |
| **Release & platform** | **52A** → **52B** → **52C** → **66A**; **52D** after 52A; **66B–66E** gated | Pinned baseline, packaging, CI, crash triage; 52A before games fork, 66A before any build leaves the team. |
| **Shipping UI / settings / input / persistence** | **53A** → **53B** → **54** → **44** → **46** → **67A** / **67B** → (60) → **67C** → **67E** | UI, settings, rebinding, and saves; bindings live in settings, never saves; no 67 work touches simulation, replay, or the checksum. |
| **Gameplay domains** | **56** → **56B** → **59** → **57** → **57B** → **61** → **58** → **63** → **62** → **71A** → **71C** / **71D** → **69A**; **42**; **68B** → **68C** | Combat, items, time, harvesting, worldgen, social, population, and AI behavior, built on 73's data-driven cognition. |
| **World presentation** | **60** → **69B** / **69C** → **70B** (69D–69F gated) | Camera rig and scene composite, regional weather, time skip, presentation polish. |

- **AI expandability:** Slice 32's arbitration path is a rule in
  `.claude/rules/simulation.md` (AI and affect).
- **Component headroom:** 14 of 32 `Component` tags used (`enum(u5)` +
  `ComponentMask = u32`); the VoidLight port projects 10 more and Slice 71A one
  (`ai_post`): **25 of 32** (Table T5).
- **Interest kinds:** all reserved kinds are wired once 71C lands
  (investigate 41, resource 61, patrol 71A, cover 71C).
- Guard CPU paths with existing benches. Architecture constraints (SDL_GPU
  submit on the render thread, state-owned `SimulationPipeline`, persistent
  data in `DataSystem`, structural changes through `SimulationFrame`) are in
  [architecture.md](architecture.md).

## Deferred By Owner

Product work the owner explicitly deferred: not slices, no design. When an
entry's trigger trips, write a slice for it and remove the entry.
Only the owner adds entries (Ground Rules).

- **Full localization.** Per-locale string tables with validation, a locale
  setting (the next settings version at landing), OS-preference default and
  live switching, plurals and per-locale argument formatting, a pseudo-locale,
  locale and font-coverage lints, and CJK / per-locale font subsets within
  53A's fixed atlas page cap (formerly 67D); builds on
  [Slice 67E](roadmap/slices/slice-67e.md) Localization Roots. Trigger: core
  complete (VoidLight-port core Slices 49–63 plus 64A–64C landed) or an
  explicit owner go-ahead. Deferred by owner 2026-10-05; design a slice when
  triggered.

## Suggested Order

The settled foundation order is in the
[archive index](framework-implementation-slices-archive.md#historical-order).

### Open slices — merged order

Dependency order for every open slice, derived from each slice's header line
(the only place dependencies are recorded); every prerequisite appears on an
earlier line or is landed. Tables T1–T6 number versions in this relative
order.

- **Residual verification (any time):** [33](roadmap/slices/slice-33.md)
  (visual/`gpu-smoke`), [43](roadmap/slices/slice-43.md) (hardware).
- **Capacity sizing:** [72](roadmap/slices/slice-72.md), any time; F and G
  are re-scoped against 64G first. Its open items cross-edit the slices they
  name in the same change.

1. **64G** Chunk-Owned Terrain And Nav.
2. **76** Cave-Ins — after 64G.
3. **77** Explosions — after 64G, 76.
4. **49** Session Seed And Determinism Checksum Harness — after 64G.
5. **73** Data-Driven Cognition — after 49.
6. **75** Far Simulation — after 64G, 73.
7. **50** Thread System Hardening.
8. **74** World Instances — after 64G, 49, 50, 75.
9. **52A** Release CPU Baseline, Toolchain Pins, Pinned SDL, Committed Shaders.
10. **52B** Platform Packaging Layouts — after 52A.
11. **52C** CI Workflows And Release Performance Baseline — after 52A, 49, 50, 52B.
12. **52D** SIMD Layer Codegen For The v2 Release Baseline — after 52A.
13. **64A** Simulation-Invisible Pause, Float Min/Max Policy, And FP Environment Assertion — after 49, 52D.
14. **55** Cognition Think-Interval Coasting (Decision LOD) — after 73.
15. **35** AI And Steering Hot-Loop SIMD Restructure — after 55, 52D.
16. **51** Background Job Lane With Deterministic Step Handoff — after 49, 50, 64A.
17. **65A** Thread-Shared Layout Consolidation And Background-Lane OS Priority — after 50, 51.
18. **64B** Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage — after 49, 50, 64A, 64G, 74.
19. **53A** Scalable GPU Text Labels.
20. **53B** UI Widget Toolkit, Menu Migration, And HUD Primitives — after 53A.
21. **54** Persistent Settings — after 53B, 52B.
22. **66A** Shipped-Build Crash Triage — Split Symbols, Symbol Store, Crash Reports, Linux Window Icon — after 52B, 52C, 54.
23. **44** Input Rebinding And Extended Gamepad Controls — after 53B, 54.
24. **64C** Headless Replay Runner, Session Descriptor, And New Game Seed Flow — after 49, 51, 53B, 64A, 64B, 74.
25. **65B** Deferred Nav Rebuild On The Background Lane — after 51, 65A, 64G, 49, 64B.
26. **46** Save/Load Persistence — after 49, 51, 53B, 54, 64B, 64G, 74.
27. **70A** Sprite Vertex Compaction (Indexed Quads, Packed Color).
28. **60** Camera Behavior And Scene Composite Pass — after 49, 54, 70A.
29. **67A** Pointer Input, Menu Hold-To-Repeat, And Scancode Bindings — after 53B, 54, 44.
30. **67B** Debug Text Migration, Event Log, Text Atlas Telemetry, And UI Sound Cues — after 53A, 53B, 44.
31. **67C** Save Slot Presentation — Thumbnails, Named Saves, And The Text-Input Widget — after 46, 60, 67A.
32. **67E** Localization Roots — after 53B.
33. **70B** Presentation Polish (Runtime Scene Resolution, Pad Zoom, Fade-Out, Sharp-Bilinear, Zoom Tween) — after 60, 54, 44.
34. **56** Health, Damage, And Combat Domain Controller — after 49, 73.
35. **56B** Projectiles And Ranged Combat — after 56.
36. **59** Game Time, Day/Night Cycle, Seasons, And Weather — after 49, 60.
37. **57** Items, Inventory, And Equipment — after 56, 49, 59.
38. **57B** Inventory And Equipment UI — after 53A, 53B, 57, 49, 64C.
39. **69C** Time Skip — after 59, 49, 75, 64B, 67B, 67E, 57B.
40. **38** Elevation Above The Surface — after 64G.
41. **61** Harvesting And World Resource Nodes — after 73, 56, 57, 49.
42. **58** Seeded Procedural World Generation — after 49, 57, 61, 64G.
43. **65C** Streaming Worldgen On The Background Lane — after 58, 53B, 51, 74.
44. **69B** Regional (Biome) Weather — after 58, 59, 60.
45. **63** Social Relationships And Trade — after 73, 53B, 56, 57, 57B, 61.
46. **62** NPC Population, Spawning, And Spawn Tables — after 49, 57, 58, 59, 63, 64G, 75.
47. **71A** AI Behavior Parity — Patrol, Follow, Guard — after 73, 55, 56, 61, 62, 63.
48. **71B** Static Collider Index, Collision Static Split, And Group-Field Prewarm — after 64G, 62, 71A.
49. **71C** Cover-Aware Flee And Ranged Pursue (`cover` Interest Markers) — after 73, 56B.
50. **71D** AI Merchant Selling (Forage → Sell Loop) — after 73, 63, 61, 57, 56, 55, 71A.
51. **69A** Worldgen Breadth — Caves, Structures And Villages, Autotile Edge Sets — after 58, 61, 62, 65C, 64G.
52. **42** Affect Expansion — More Feelings, Coupling, And Mood — after 73, 56, 61, 59.
53. **68A** Battle-Scale Hardening — Shared Entity Table, Action-Bus Fairness, Control Re-Baseline — after 55, 56, 75.
54. **68B** Knockback Impulses And Retaliation Memory — after 73, 55, 56, 56B, 49.
55. **68C** Carried-Inventory Death Drop And Ranged Ammo — after 56B, 57, 61.
56. **Gated** (each lands when its trigger trips; see its Status line):
    - **64D:** first simulation `atan2` consumer — after 52D.
    - **66B:** per target — after 66A, 64C, 52A.
    - **66C:** first public release outside Steam — after 66A.
    - **66D:** a Steamworks app ID — after 66A.
    - **66E:** first release-candidate tag — after 52C.
    - **69D:** first scripted-weather consumer — after 59, 69B.
    - **69E:** benches show off-view weather is a measurable cost share — after 59, 60.
    - **69F:** worlds that cannot hold every chunk expanded in memory — after 64G, 58, 46, 74, 75.

Umbrellas (52, 64, 65, 66, 67, 69, 70, 71) close when their sub-slices do.

## Roadmap Files

- Open slices: [`roadmap/slices/`](roadmap/slices/).
- Settled slices: [`roadmap/archive/`](roadmap/archive/), index
  [framework-implementation-slices-archive.md](framework-implementation-slices-archive.md).
- Tracks: [VoidLight port](roadmap/tracks/voidlight-port.md) (Tables T1–T6),
  [Emergent AI](roadmap/tracks/emergent-ai.md),
  [Long-term gameplay direction](roadmap/tracks/gameplay-direction.md).
- Measured pressure points: [Scaling Gaps](roadmap/scaling-gaps.md).
