# Framework Implementation Slices — Archive

Completed, settled slices, one file per slice under
[`roadmap/archive/`](roadmap/archive/). Every slice here is done and verified;
each file keeps its full Checklist and Acceptance record as history. The live
roadmap index, [framework-implementation-slices.md](framework-implementation-slices.md),
owns current priorities, the open slice files under
[`roadmap/slices/`](roadmap/slices/), Suggested Order, and links to
[Scaling Gaps](roadmap/scaling-gaps.md) and the track overviews.

When an open slice is fully complete, `git mv` its file from
`roadmap/slices/` to `roadmap/archive/`, fix its relative links (both
directories sit at the same depth, so `../tracks/…` and `../../…` links keep
working; links to sibling open slices become `../slices/slice-<id>.md`), move
its row from the index's Open Frontier table to the table below, and keep its
acceptance history intact.

**Archived coverage:** Slices 0–7, 8, 9–17, 18–25E, 26–32, 34, 36, 37, 39–41, 45, 47, 48, 64E.

> Residual follow-ups from archived slices are never incomplete archive
> checklists. Where they live today: Slice 30's deferred `memory_expired`
> event is an optional item in [Slice 33](roadmap/slices/slice-33.md); the
> optional linear `mergeDrawList` micro-opt is a measure-first note in
> [Scaling Gaps](roadmap/scaling-gaps.md); interest-marker consumers beyond
> investigate are owned by Slices 61, 71A, and 71C. Slice 32's cohere `.group`
> upgrade and optional `behavior_changed` event have no consumer and are not
> planned; a slice that needs one adds it to its own Checklist. The Slice 23A
> `expand2`→`world` merge is settled.

## Archived Slice Index

| Slice | Title | Summary |
| --- | --- | --- |
| [0](roadmap/archive/slice-0.md) | Runtime Diagnostics Policy | Compile-time `std.log` filtering: debug diagnostics, quiet release builds. |
| [1](roadmap/archive/slice-1.md) | Input Routing | Policy-driven input routing between modal UI, gameplay, and debug commands. |
| [2](roadmap/archive/slice-2.md) | Logical Resolution And Viewport Policy | Deliberate logical resolution and viewport policy for UI, resize, and high-DPI. |
| [3](roadmap/archive/slice-3.md) | Render Resource Layer | Render resource layer replacing raw texture indices (caching, reload, ownership). |
| [4](roadmap/archive/slice-4.md) | Asset Cache | Explicit runtime asset ownership through an asset cache. |
| [5](roadmap/archive/slice-5.md) | Text And Font Service | Asset-backed SDL_ttf text rendering for menus, buttons, and UI. |
| [6](roadmap/archive/slice-6.md) | Renderer Composition | Renderer split into sprite/UI/shape/tilemap composition paths. |
| [7](roadmap/archive/slice-7.md) | Preallocated Thread System And Parallel Render Prep | Pre-spawned deterministic thread system and parallel render prep. |
| [8](roadmap/archive/slice-8.md) | Shader And Platform Expansion | Shader and platform expansion with reliable cross-platform shader builds. |
| [9](roadmap/archive/slice-9.md) | Platform-Neutral SIMD Helper Layer | Platform-neutral SIMD helper layer with project names. |
| [10](roadmap/archive/slice-10.md) | DataSystem And SoA Composition Foundation | `DataSystem` as the persistent SoA gameplay-data owner and save/load boundary. |
| [11](roadmap/archive/slice-11.md) | SIMD-Aware Data Processor Systems | SIMD-aware `DataSystem` processors on the thread system, deterministic fixed step. |
| [12](roadmap/archive/slice-12.md) | Simulation Contracts And Deferred Structural Changes | Simulation phase contracts and deferred structural changes. |
| [13](roadmap/archive/slice-13.md) | Spatial Queries And Collision Contacts | Spatial queries and collision contact foundations. |
| [14](roadmap/archive/slice-14.md) | First AI Intent Processor And Future Rule Contracts | First AI intent processor emitting movement intents through `SimulationFrame`. |
| [15](roadmap/archive/slice-15.md) | SDL3_mixer Audio Service | App-owned SDL3_mixer SFX and music service. |
| [16](roadmap/archive/slice-16.md) | Main Menu and Settings Menu | Main menu as the startup state plus a settings menu. |
| [17](roadmap/archive/slice-17.md) | Startup Runtime Asset Catalog | Startup runtime asset catalog with stable sprite/audio handles. |
| [18](roadmap/archive/slice-18.md) | Frame-Delayed Pathfinding System | Frame-delayed pathfinding (contract retained; core superseded by Slice 25). |
| [19](roadmap/archive/slice-19.md) | Steering And Local Avoidance | Steering, local avoidance, and stuck/replan policy above the pathfinder. |
| [20](roadmap/archive/slice-20.md) | Navigation Hardening And Hard-Path Budgets | Navigation hardening and hard-path node budgets (core superseded by Slice 25). |
| [21](roadmap/archive/slice-21.md) | Typed Simulation Event System And Domain Signals | Typed deterministic simulation event system and domain signals. |
| [22](roadmap/archive/slice-22.md) | Simulation Pipeline And Tier/Scope Scaffolding | State-owned `SimulationPipeline` with tier/scope scaffolding. |
| [23](roadmap/archive/slice-23.md) | Atlas-Backed World Rendering Addition | Atlas-backed world/tile rendering foundation. |
| [23A](roadmap/archive/slice-23a.md) | GPU Tilemap Render Hardening | GPU tilemap render hardening: depth order, partial uploads, batched staging. |
| [23B](roadmap/archive/slice-23b.md) | Multi-Depth Dense-Layer Render Scaling | Multi-depth dense-layer render scaling (~120 levels). |
| [24](roadmap/archive/slice-24.md) | Scoped Simulation Tiers And Chunk Policy | Scoped simulation tiers and chunk policy. |
| [24B](roadmap/archive/slice-24b.md) | Render Collect Hardening | Render collect hardening: movement-index collect and camera-only gates. |
| [25](roadmap/archive/slice-25.md) | Z-Aware Scalable Navigation Redesign | Z-aware scalable navigation redesign for multi-level worlds. |
| [25E](roadmap/archive/slice-25e.md) | Per-Entity NPC Level And Autonomous Z-Traversal | Per-entity NPC level and autonomous Z-traversal. |
| [26](roadmap/archive/slice-26.md) | Entity Faction And Classification Model | Entity faction and classification model (threat / ally / neutral). |
| [27](roadmap/archive/slice-27.md) | Deterministic Per-Entity RNG Facility | Deterministic per-entity RNG facility. |
| [28](roadmap/archive/slice-28.md) | Shared Spatial Index Service | Shared frame-level spatial index for AI separation and perception. |
| [29](roadmap/archive/slice-29.md) | AI Perception Substrate | AI perception substrate: vision, LOS, hearing, acquire/lose events. |
| [30](roadmap/archive/slice-30.md) | AI Memory And Scope-Aware AI State Policy | AI memory and scope-aware AI state policy. |
| [31](roadmap/archive/slice-31.md) | AI Affect And Emotion Drives | AI affect: appraisal-driven fear/curiosity/aggression/fatigue drives. |
| [32](roadmap/archive/slice-32.md) | AI Behavior Arbitration | AI behavior arbitration: utility + sticky selection over perception, memory, affect. |
| [34](roadmap/archive/slice-34.md) | Core SIMD Primitive Layer Expansion And Dense-Path Wins | Core SIMD primitive layer expansion and dense-path wins. |
| [36](roadmap/archive/slice-36.md) | Single-Pass Dense-Layer Depth Compositing | Single-pass dense-layer depth compositing. |
| [37](roadmap/archive/slice-37.md) | Dense Render-Window Fixed Cap And Shader/Host Sync Hardening | Fixed dense render-window cap (32) and shader/host sync hardening. |
| [39](roadmap/archive/slice-39.md) | Sensory Stimulus Ecosystem | Multi-producer sensory stimulus ecosystem feeding AI hearing. |
| [40](roadmap/archive/slice-40.md) | Action And Interaction Intent Substrate | Action and interaction intent substrate (non-locomotion intents). |
| [41](roadmap/archive/slice-41.md) | World Interest And Affordance Markers | World interest and affordance markers (investigate wired). |
| [45](roadmap/archive/slice-45.md) | First Action-Intent Consumer Domain Controller (Destructibles) | First action-intent consumer: destructibles controller. |
| [47](roadmap/archive/slice-47.md) | Un-Stagger The Shared Sensing Substrate | Un-staggered shared sensing substrate (perception defect fix). |
| [48](roadmap/archive/slice-48.md) | SimulationPipeline Thin-Composer Restoration | `SimulationPipeline` thin-composer restoration. |
| [64E](roadmap/archive/slice-64e.md) | Incremental Nav Patch Ramp/Link Parity | Runtime ramps routable the same step on both levels; incremental equals full rebuild. |

## Historical Order

The original dependency order, kept for history (all landed and archived
unless noted): 0 runtime diagnostics → 1 input routing → 2 logical resolution
→ 3 render resources → 4 asset cache → 5 text/fonts → 6 renderer composition →
7 thread system + parallel render prep → 8 shader/platform expansion → 9 SIMD
helpers → 10 `DataSystem` → 11 SIMD processors → 12 simulation contracts → 13
spatial queries/contacts → 14 first AI intent processor → 15 audio → 16
menus → 17 runtime asset catalog → 18 frame-delayed pathfinding → 19 steering
→ 20 nav hardening → 21 typed events → 22 pipeline + tier/scope scaffolding →
23 / 23A / 23B world rendering → 24 / 24B scoped tiers + render collect → 25 /
25E Z-aware navigation + per-entity levels → 26 factions → 27 RNG → 28 spatial
index → 34 core SIMD expansion → 29 perception → 30 memory → 31 affect → 32
arbitration → 33 archetypes + debug (visual residual open) → 39 stimuli → 41
interest markers → 40 action intents → 45 destructibles → 36 single-pass
compositing → 37 dense-window cap → 43 gamepad (HW residual open) → 47
un-staggered sensing → 48 thin composer. Open slices from that list (33, 35,
38, 43) are placed in the roadmap index's merged order.
