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
  slice file.
- **A slice is small:** one feature, one owning area, designed, landed, and
  reviewed as one batch. Larger work is several slices.
- **One file per slice or sub-slice** (`slices/slice-<id>.md`, lowercase id;
  umbrellas such as `slice-52.md` summarize their sub-slices), each with exactly
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
- Version numbers (settings schema, save format, checksum tag),
  `stage_order` positions, and component tags follow Tables
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
3. **Design plan right before implementation.** `zig-design-specialist`
   writes the plan for each slice or landing whose design is open, against
   the live code (`AGENTS.md` § Agent Pipeline). The plan goes to the
   implementer, not into the slice.
4. **Implement only that slice's scope** in the owning `src/` modules.
5. **Review before commit** (`AGENTS.md` § Agent Pipeline); fixes fold into
   the commit.
6. **Pass every Acceptance check.** Items marked "(added by Slice N)" are
   part of this slice's scope.
7. **Docs commit, once the slice's programming is done:** check off Checklist
   items, update durable docs (`architecture.md`, rendering/sim docs) and
   Tables T1–T6 from the landings' commit notes (`AGENTS.md` § Agent
   Pipeline), and bring every open slice the landed code affects up to
   date: its Current foundation and `file:line` refs, items the landing
   closed or made obsolete, and the interfaces or orders it builds on.
8. **Set Status**, run `zig build verify` before the slice's final commit, and
   when complete archive the file (Ground Rules). Follow-ups go into a slice
   Checklist or a new slice file.

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
| [**35**](roadmap/slices/slice-35.md) | Not started | AI Decision Math And World-Gate SIMD Restructure — after 55, 52D |
| [**38**](roadmap/slices/slice-38.md) | Not started | Elevation Above The Surface — after 64G |
| [**42**](roadmap/slices/slice-42.md) | Not started | Affect Expansion — More Feelings, Coupling, And Mood — after 73, 56, 61, 59 |
| [**43**](roadmap/slices/slice-43.md) | Landed (hardware verification pending) | SDL3 Gamepad/Controller Support |
| [**44**](roadmap/slices/slice-44.md) | Not started | Input Rebinding And Extended Gamepad Controls — after 53B, 54 |
| [**46**](roadmap/slices/slice-46.md) | Not started | Save/Load Persistence — after 49, 51, 53B, 54, 64B, 64G, 74 |
| [**49**](roadmap/slices/slice-49.md) | In progress | Session Seed And Determinism Checksum Harness — after 64G |
| [**50**](roadmap/slices/slice-50.md) | Landed (acceptance runs pending) | Thread System Hardening |
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
| [**56**](roadmap/slices/slice-56.md) | Not started | Health, Damage, And Combat Domain Controller — after 88, 49, 73 |
| [**56B**](roadmap/slices/slice-56b.md) | Not started | Projectiles And Ranged Combat — after 56 |
| [**57**](roadmap/slices/slice-57.md) | Not started | Items, Inventory, And Equipment — after 88, 56, 49, 59 |
| [**57B**](roadmap/slices/slice-57b.md) | Not started | Inventory And Equipment UI — after 53A, 53B, 57, 49 |
| [**58**](roadmap/slices/slice-58.md) | Not started | Seeded Procedural World Generation — after 49, 57, 61, 64G |
| [**59**](roadmap/slices/slice-59.md) | Not started | Game Time, Day/Night Cycle, Seasons, And Weather — after 49, 60 |
| [**60**](roadmap/slices/slice-60.md) | Not started | Camera Behavior And Scene Composite Pass — after 49, 54, 70A |
| [**61**](roadmap/slices/slice-61.md) | Not started | Harvesting And World Resource Nodes — after 88, 73, 56, 57, 49 |
| [**62**](roadmap/slices/slice-62.md) | Not started | NPC Population, Spawning, And Spawn Tables — after 88, 49, 57, 58, 59, 63, 64G, 75 |
| [**63**](roadmap/slices/slice-63.md) | Not started | Social Relationships And Trade — after 73, 53B, 56, 57, 57B, 61 |
| [**64A**](roadmap/slices/slice-64a.md) | Not started | Simulation-Invisible Pause, Float Min/Max Policy, And FP Environment Assertion — after 49, 52D |
| [**64B**](roadmap/slices/slice-64b.md) | Not started | Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage — after 49, 50, 64A, 64G, 74 |
| [**64C**](roadmap/slices/slice-64c.md) | Not started | Session Descriptor And New Game Seed Flow — after 49, 53B, 74 |
| [**64D**](roadmap/slices/slice-64d.md) | Gated: first simulation `atan2` consumer | Deterministic Vector `atan2` — after 52D |
| [**64G**](roadmap/slices/slice-64g.md) | Sealed | Chunk-Owned Terrain And Nav — three follow-ups open |
| [**65**](roadmap/slices/slice-65.md) | Not started (umbrella) | Threading Layout Cleanup And Background-Lane Heavy Consumers — after 50, 51 |
| [**65A**](roadmap/slices/slice-65a.md) | Not started | Thread-Shared Layout Consolidation And Background-Lane OS Priority — after 50, 51 |
| [**65B**](roadmap/slices/slice-65b.md) | Not started | Deferred Nav Rebuild On The Background Lane — after 51, 65A, 64G, 49, 64B |
| [**65C**](roadmap/slices/slice-65c.md) | Not started | Streaming Worldgen On The Background Lane — after 58, 53B, 51, 74 |
| [**66**](roadmap/slices/slice-66.md) | Not started (umbrella) | Distribution, Signing, Symbols, And Store Delivery — after 52B, 52C, 54 |
| [**66A**](roadmap/slices/slice-66a.md) | Not started | Shipped-Build Crash Triage — Split Symbols, Symbol Store, Crash Reports, Linux Window Icon — after 52B, 52C, 54 |
| [**66B**](roadmap/slices/slice-66b.md) | Gated: per target | Additional Package Targets — macOS universal2, aarch64-linux, aarch64-windows — after 66A, 52A |
| [**66C**](roadmap/slices/slice-66c.md) | Gated: first public release outside Steam | Signing, Notarization, .dmg, And Linux AppImage — after 66A |
| [**66D**](roadmap/slices/slice-66d.md) | Gated: a Steamworks app ID | SteamPipe Upload Automation — after 66A |
| [**66E**](roadmap/slices/slice-66e.md) | Gated: first release-candidate tag | Authoritative Perf Runner — after 52C |
| [**66F**](roadmap/slices/slice-66f.md) | Gated: a Steamworks app ID | Steamworks Runtime Integration — after 66D and the VoidLight port slices |
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
| [**71B**](roadmap/slices/slice-71b.md) | In progress | Static Collider Index And Group-Field Prewarm — after 64G, 62, 71A |
| [**71C**](roadmap/slices/slice-71c.md) | Not started | Cover-Aware Flee And Ranged Pursue (`cover` Interest Markers) — after 73, 56B |
| [**71D**](roadmap/slices/slice-71d.md) | Not started | AI Merchant Selling (Forage → Sell Loop) — after 73, 63, 61, 57, 56, 55, 71A |
| [**72**](roadmap/slices/slice-72.md) | In progress | Live Capacity Sizing Pass — F and G re-scoped after 64G |
| [**73**](roadmap/slices/slice-73.md) | Not started | Data-Driven Cognition — after 49 |
| [**74**](roadmap/slices/slice-74.md) | Not started | World Instances — after 64G, 49, 50, 75 |
| [**75**](roadmap/slices/slice-75.md) | Not started | Far Simulation — after 64G, 73 |
| [**76**](roadmap/slices/slice-76.md) | Not started | Cave-Ins — after 64G, 88 |
| [**77**](roadmap/slices/slice-77.md) | Not started | Explosions — after 64G, 76, 88 |
| [**78**](roadmap/slices/slice-78.md) | Not started | Comptime Assessment — independent |
| [**79**](roadmap/slices/slice-79.md) | Not started | Fixed-Step Input Edges, Frame-Time Snapping, And TimeLoop Cap Invariant — independent |
| [**80**](roadmap/slices/slice-80.md) | Not started | Observer And Optional Player Character — before 75 and 74 bind the observer |
| [**85**](roadmap/slices/slice-85.md) | Not started | Steering On The Shared Neighbor Index — after 84, 86 |
| [**86**](roadmap/slices/slice-86.md) | Not started | Collision Subsystem Pass — after 83, 84 |
| [**87**](roadmap/slices/slice-87.md) | Not started | Render Collect By Visible Chunks — after 83, 85, 35's `world_gate` items |
| [**88**](roadmap/slices/slice-88.md) | Not started | DataSystem, Step Contracts, Pipeline, And Core Kernels Pass — after 87 |

**Recently settled (archive only):** 82, 81, 37, 48, 47, 45, 40, 39, 41, 32, 8, 18–25E, 26–31, 34, 36 (plus 0–7, 9–17).

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
| **Determinism & threading** | **49** → **50** → **52A–52D** → **64A** → **51** → **65A** → **64B** → **64C** → **65B** (65C after 58 and 74; 64D gated) | Seeded sessions, checksum over every world, serial == threaded results, and lane consumers. |
| **Perf** | **72**, **55**, **35**, **70A**, **71B**, **68A** | Behavior independent of physical capacity, decision cadence, AI/steering math, sprite bandwidth, shared entity tables, static fast paths. |
| **Release & platform** | **52A** → **52B** → **52C** → **66A**; **52D** after 52A; **66B–66E** gated | Pinned baseline, packaging, CI, crash triage; 52A before games fork, 66A before any build leaves the team. |
| **Shipping UI / settings / input / persistence** | **53A** → **53B** → **54** → **44** → **46** → **67A** / **67B** → (60) → **67C** → **67E** | UI, settings, rebinding, and saves; bindings live in settings, never saves; no 67 work touches simulation or the checksum. |
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

## Engine-Core Overhaul

Owner direction 2026-10-11. The cost-model rules added since the 2026-10-07
branch review (`engine-design.md` § Cost model: results are stored at the unit
they cover and shared; a population's per-step load is O(1) per requester
plus the distinct work, summed over worlds) drove the 64G terrain/nav rework.
The rest of the engine gets the same pass, one area per branch, in this order.
The owner merges each sealed branch to main before the next starts. Normal
roadmap flow (Suggested Order) resumes after the AI branch.

1. **Pathfinding (`engine_scale`, sealed 2026-10-14):** [64G](roadmap/slices/slice-64g.md).
   Landed: maintained reachability (connectivity IDs and the one-way closure:
   O(1) per request, never a failed search), the dense-dig main-thread split,
   the cross-level heuristic at scale with partial hops for far goals, and the
   combined review since the 2026-10-07 branch review; every acceptance check
   passes, with three follow-ups open in the slice. Then one short branch of
   file moves, merged before the core branch opens (`module_layout`, sealed
   2026-10-15): [82](roadmap/archive/slice-82.md) moved and split the world
   module, then [81](roadmap/archive/slice-81.md) split the pathfinding module, so
   the core and AI branches plan against the final file layout.
2. **Core systems:** opens with [50](roadmap/slices/slice-50.md) (owner
   2026-10-12), so the branch's threaded rework runs under the race
   detector. Slice 50 landed on `core_systems` (`e56e37b`..`987b342`); TSan
   and `verify` pass. Its ReleaseFast test and the owner's Windows run are
   still open. Mac runs and compiles. The measuring landing (`5d5a089`) benched today's code; each
   finding, with its `file:line` re-checked there, its measured number, and
   its pass shape, lives in its slice. 83 landed (`3c42b4f`, `176ed03`,
   `13e88ad`; `verify` passes); 84's programming landed (`c52a5ff`,
   `08e4799`, `3efa1e4`, `320023a`). Order:
   [83](roadmap/archive/slice-83.md) prep →
   [84](roadmap/archive/slice-84.md) spatial index →
   [86](roadmap/slices/slice-86.md) collision →
   [85](roadmap/slices/slice-85.md) steering → tile gate
   ([35](roadmap/slices/slice-35.md)'s `world_gate` items) →
   [87](roadmap/slices/slice-87.md) render prep →
   [88](roadmap/slices/slice-88.md) DataSystem, contracts, pipeline, kernels →
   inert rows (86's and 75's items) → [75](roadmap/slices/slice-75.md)'s tier mechanics; 87's render
   backend pass closes the branch (owner 2026-10-16). Items the 64G combined
   review routed here (refs at `e2b9b2c`):
   - Tile gate on main (area D H1): 35.
   - Halo agents sorted twice (M1): 84, then 85.
   - Missing SIMD verdicts (M4): agent avoidance 85, response gather 86.
   - Commit-seam order in the demo state (L5): 74.
   - Any create re-resolves every steering row (L10): 85.
   - File splits (L11) and per-system tuner fields: 83 (landed).
   - Render collect and GPU sync copying (area C): 87.
   - Movement intent order: 85.
   - World creation and worldgen: measured; its findings are in 74.
   - Collision, whole subsystem: 86.
   - Render backend pass: 87, last.

   Items the 2026-10-16 audits and the 84 chunk-index review routed here
   (tags name findings in the local `.claude/reports/` audit files). Every
   ref is re-checked right before implementation
   (`.claude/rules/engine-design.md` § Cost model).
   - 84: index order and its fragment paths (code H1, review 1 and 8);
     cohere's check budget (code H1); TSan before merge (review open
     question); carried stage inputs (code M1); the vectorized separation
     accumulate, moved from 35 (code M4); scalar reasons (code L7, review 6);
     query group doc and off-main asserts (review 2 and 3, code L2); comments
     and module doc (code L9, review 4 and 9); cell-radius overflow (review
     5); empty-build tail (review 7); the docs commit's foundation,
     changelog, 68A cross-edit, one place per explanation, and DW fields
     (docs M3, M12, L3, L4, L12, L13, code L10); done in the tree (code L1, L6).
   - 86: sweep order and proxy gather (contiguity H2); static-collider lists
     (contiguity H3); path registry lists (contiguity L1).
   - 85: steering grid level key (contiguity H1, code H2); the vectorized
     avoidance accumulate, moved from 35 (docs M9); intent order
     (contiguity M3).
   - 87: visible-chunk source (contiguity H4); sparse tile lists (contiguity
     M1); submit reads in sort order (contiguity M2); bench review tags
     (code L9).
   - 88: stagger phase overwritten at spawn (roadmap verify); DataSystem
     hot-pass data layout (contiguity H5); structural-share
     deferral (docs M7); index and AI scratch sized by AI rows (code M2);
     perf-log policy (code L1); `production-step` OOM leak (code L3);
     `hotStoreCapacity` copies (code L8).
   - 74: the steering seam copy (code M3); `production-step` spawn path (code
     L4).
   - 68A: think-set compact on main (contiguity audit, noticed in passing;
     closed by 84).
   - 52A: `build.zig` doc pointer (code L9, docs L14).
   - 75: census timers (docs L18).

   Coverage (owner 2026-10-16: every system gets a whole-subsystem pass
   against the cost model and the rules, not only its measured findings):
   - Core branch:
     - 84: spatial index;
     - 86: collision, response, static colliders, destructibles;
     - 85: steering, movement, particles;
     - 35: tile gate;
     - 87: render prep, GPU tile sync, world render, and the render backend;
     - 88: `DataSystem`, step contracts, pipeline, `src/core` kernels;
     - 75: simulation scope;
     - 50 (landed): `ThreadSystem`.
   - World creation (`world/system.zig`, `worldgen.zig`): 74.
   - Pathfinding branch (sealed, combined-reviewed): `systems/pathfinding/`,
     `plane_entry`, `chunk_list_map`, `stamped_table`, `world/edit`,
     `world/terrain`, `dig_controller`.
   - AI branch: `ai`, `ai_memory`, `affect`, `perception`, `arbitration`,
     `sensory_bus`, `ai_archetypes`, `ai_debug_overlay`, `world/interest`, and
     the AI stores.
   - Item 4: states and menus, `audio_controller`, `player`, `src/app` apart
     from `ThreadSystem`, `src/assets`, `src/platform`.

   Coverage gaps (docs audit L5): `src/render/camera.zig`,
   `debug_overlay.zig`, `fps_counter.zig`, and `resources.zig` go to 87's
   backend pass, and `src/core/logging.zig` to 88's kernels item.
3. **AI:** cognition, perception, memory, affect, sensory bus and interest
   markers, built on the core branch's final form.
4. **Remaining layers, when normal roadmap flow resumes after the AI branch:**
   the app layer (state stack, input), assets, audio, and platform get one
   best-practices pass (`zig-best-practices-review`). They are setup-time or
   bounded per frame, so they get no branch of their own, and neither the core
   nor the AI branch touches their files.

Each branch opens by measuring first (bench-only landing on today's code), then
writes the findings into slice checklists or new slice files.

**Core findings** (measured at `5d5a089`; detail in each slice):
- **High:** spatial index and perception check budget (84, landed); collision
  broadphase (86); tile gate (35); render collect (87); inert rows (86 for
  collision, 75 for movement and tiers, 87 for render collect).
- **Medium:** destructible resolve (72 D1); structural commands past the
  fixed share (88's deferral; 56, 57, 61, 62, 76, 77 use it).
- **Already owned:** far-tier freeze (75); GPU per-edit sync (64G measured,
  `639f55d`; its main-thread copying is 87).

**AI findings** (derived from code, 2026-10-11; benches to confirm):
- **Critical:** far AI stops advancing (no thinking outside the halo, dormant
  past 48 chunks or 4 levels; memory and affect freeze), against
  `engine-design.md` § Target scale. Owned by 75; its tier mechanics land in
  the core branch.
- **High:**
  - **Per-row gathers on main:** 84 moved the perception, decide, memory, and
    stagger-filter walks to workers; affect's gather is 88's item.
  - **Perception's hostile cap** keeps the first 16 candidates in scan order,
    not the nearest, so in a crowd of more than 16 hostiles in range the
    nearest visible one can be missed (derived).
  - **Sensory bus** (new slice):
    - fixed caps drop stimuli simulation reads;
    - a dig can in principle be refused when the bus is full;
    - linger is tied to the stagger, so slower thinkers miss one-shot sounds;
    - hearing is every observer × every stimulus;
    - the fix: per-chunk buckets, no caps.
  - **Decide:** scans every marker per think and ignores level; with no player
    it steers to a demo constant.
- **Medium:**
  - **Interest markers:** a flat 128-slot store that refuses adds and is
    scanned per think; moves to chunk-owned storage (58).
  - **Affect decay:** counted per think, not per elapsed step (73).
- **Open question:** whether crowds converging on one goal share path work
  through the goal-keyed cache or need the group field (73).

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
The [Engine-Core Overhaul](#engine-core-overhaul) branches run before this
order resumes.

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
- **Game-loop input and timing:** [79](roadmap/slices/slice-79.md), any time.
- **Observer and optional player:** [80](roadmap/slices/slice-80.md), before
  75 and 74 bind the observer; 60's rig drives it once landed.

1. **64G** Chunk-Owned Terrain And Nav.
2. **82** Split The World Module — landed (archived).
3. **81** Split The Pathfinding Module — landed (archived).
4. **50** Thread System Hardening (opens the core-systems branch) — landed on `core_systems`.
5. **83** Core-Branch Prep — Steering And Pipeline Splits, Stage-Owned Tuners — landed on `core_systems` (archived).
6. **84** Level-Aware Shared Neighbor Index — after 83 (core-systems branch).
7. **86** Collision Subsystem Pass — after 83, 84 (core-systems branch).
8. **85** Steering On The Shared Neighbor Index — after 84, 86 (core-systems branch).
8a. **35's `world_gate` items** — after 85 (core-systems branch; the rest of 35 is line 22).
9. **87** Render Collect By Visible Chunks — after 83, 85, 35's `world_gate` items (core-systems branch).
9a. **88** DataSystem, Step Contracts, Pipeline, And Core Kernels Pass — after 87's collect items (core-systems branch).
9b. **Inert rows** (86's and 75's items), then **75's tier mechanics** — after 88 (core-systems branch; the rest of 75 is line 14).
9c. **87's render backend pass** — after 9b; closes the core-systems branch.
10. **76** Cave-Ins — after 64G, 88.
11. **77** Explosions — after 64G, 76, 88.
12. **49** Session Seed And Determinism Checksum Harness — after 64G.
13. **73** Data-Driven Cognition — after 49.
14. **75** Far Simulation — after 64G, 73 (its core-branch items are line 9b).
15. **74** World Instances — after 64G, 49, 50, 75.
16. **52A** Release CPU Baseline, Toolchain Pins, Pinned SDL, Committed Shaders.
17. **52B** Platform Packaging Layouts — after 52A.
18. **52C** CI Workflows And Release Performance Baseline — after 52A, 49, 50, 52B.
19. **52D** SIMD Layer Codegen For The v2 Release Baseline — after 52A.
20. **64A** Simulation-Invisible Pause, Float Min/Max Policy, And FP Environment Assertion — after 49, 52D.
21. **55** Cognition Think-Interval Coasting (Decision LOD) — after 73.
22. **35** AI Decision Math And World-Gate SIMD Restructure — after 55, 52D.
23. **51** Background Job Lane With Deterministic Step Handoff — after 49, 50, 64A.
24. **65A** Thread-Shared Layout Consolidation And Background-Lane OS Priority — after 50, 51.
25. **64B** Simulation Checksum v2 — NaN-Canonical, Sectioned, Threaded, Pipeline-History Coverage — after 49, 50, 64A, 64G, 74.
26. **53A** Scalable GPU Text Labels.
27. **53B** UI Widget Toolkit, Menu Migration, And HUD Primitives — after 53A.
28. **54** Persistent Settings — after 53B, 52B.
29. **66A** Shipped-Build Crash Triage — Split Symbols, Symbol Store, Crash Reports, Linux Window Icon — after 52B, 52C, 54.
30. **44** Input Rebinding And Extended Gamepad Controls — after 53B, 54.
31. **64C** Session Descriptor And New Game Seed Flow — after 49, 53B, 74.
32. **65B** Deferred Nav Rebuild On The Background Lane — after 51, 65A, 64G, 49, 64B.
33. **46** Save/Load Persistence — after 49, 51, 53B, 54, 64B, 64G, 74.
34. **70A** Sprite Vertex Compaction (Indexed Quads, Packed Color).
35. **60** Camera Behavior And Scene Composite Pass — after 49, 54, 70A.
36. **67A** Pointer Input, Menu Hold-To-Repeat, And Scancode Bindings — after 53B, 54, 44.
37. **67B** Debug Text Migration, Event Log, Text Atlas Telemetry, And UI Sound Cues — after 53A, 53B, 44.
38. **67C** Save Slot Presentation — Thumbnails, Named Saves, And The Text-Input Widget — after 46, 60, 67A.
39. **67E** Localization Roots — after 53B.
40. **70B** Presentation Polish (Runtime Scene Resolution, Pad Zoom, Fade-Out, Sharp-Bilinear, Zoom Tween) — after 60, 54, 44.
41. **56** Health, Damage, And Combat Domain Controller — after 88, 49, 73.
42. **56B** Projectiles And Ranged Combat — after 56.
43. **59** Game Time, Day/Night Cycle, Seasons, And Weather — after 49, 60.
44. **57** Items, Inventory, And Equipment — after 88, 56, 49, 59.
45. **57B** Inventory And Equipment UI — after 53A, 53B, 57, 49.
46. **69C** Time Skip — after 59, 49, 75, 64B, 67B, 67E, 57B.
47. **38** Elevation Above The Surface — after 64G.
48. **61** Harvesting And World Resource Nodes — after 88, 73, 56, 57, 49.
49. **58** Seeded Procedural World Generation — after 49, 57, 61, 64G.
50. **65C** Streaming Worldgen On The Background Lane — after 58, 53B, 51, 74.
51. **69B** Regional (Biome) Weather — after 58, 59, 60.
52. **63** Social Relationships And Trade — after 73, 53B, 56, 57, 57B, 61.
53. **62** NPC Population, Spawning, And Spawn Tables — after 88, 49, 57, 58, 59, 63, 64G, 75.
54. **71A** AI Behavior Parity — Patrol, Follow, Guard — after 73, 55, 56, 61, 62, 63.
55. **71B** Static Collider Index And Group-Field Prewarm — after 64G, 62, 71A.
56. **71C** Cover-Aware Flee And Ranged Pursue (`cover` Interest Markers) — after 73, 56B.
57. **71D** AI Merchant Selling (Forage → Sell Loop) — after 73, 63, 61, 57, 56, 55, 71A.
58. **69A** Worldgen Breadth — Caves, Structures And Villages, Autotile Edge Sets — after 58, 61, 62, 65C, 64G.
59. **42** Affect Expansion — More Feelings, Coupling, And Mood — after 73, 56, 61, 59.
60. **68A** Battle-Scale Hardening — Shared Entity Table, Action-Bus Fairness, Control Re-Baseline — after 55, 56, 75.
61. **68B** Knockback Impulses And Retaliation Memory — after 73, 55, 56, 56B, 49.
62. **68C** Carried-Inventory Death Drop And Ranged Ammo — after 56B, 57, 61.
63. **Gated** (each lands when its trigger trips; see its Status line):
    - **64D:** first simulation `atan2` consumer — after 52D.
    - **66B:** per target — after 66A, 52A.
    - **66C:** first public release outside Steam — after 66A.
    - **66D:** a Steamworks app ID — after 66A.
    - **66E:** first release-candidate tag — after 52C.
    - **66F:** a Steamworks app ID, after the VoidLight port slices (owner
      2026-10-16) — after 66D.
    - **69D:** first scripted-weather consumer — after 59, 69B.
    - **69E:** benches show off-view weather is a measurable cost share — after 59, 60.
    - **69F:** worlds that cannot hold every chunk expanded in memory — after 64G, 58, 46, 74, 75.

Umbrellas (52, 65, 66, 67, 69, 70, 71) close when their sub-slices do.

## Roadmap Files

- Open slices: [`roadmap/slices/`](roadmap/slices/).
- Settled slices: [`roadmap/archive/`](roadmap/archive/), index
  [framework-implementation-slices-archive.md](framework-implementation-slices-archive.md).
- Tracks: [VoidLight port](roadmap/tracks/voidlight-port.md) (Tables T1–T6),
  [Emergent AI](roadmap/tracks/emergent-ai.md),
  [Long-term gameplay direction](roadmap/tracks/gameplay-direction.md).
- Measured pressure points: [Scaling Gaps](roadmap/scaling-gaps.md).
