## Scaling Gaps And Hardening Frontier

> [Roadmap index](../framework-implementation-slices.md)

> **Scaling Gaps holds only measured pressure points awaiting a benchmark.**
> Unplanned or deferred work goes into a numbered slice file under
> [`slices/`](slices/) (a new slice or added Checklist items), never here. Do
> not add a "later" or "deferred" bullet to this file; a `[x] … promoted into
> Slice N` line records where a former backlog item now lives.

**Backlog, not a slice.** Items here are architectural pressure points waiting
to be **promoted into a numbered slice** (new section or added Checklist items).
Agents implement only from slice **Checklist** / **Acceptance checks**; use this
section for planning and to avoid duplicating gap lists inside landed slice
sections. When work starts, copy items into a slice Checklist and check off there.

Measure with `zig build bench` and scope stats before raising entity counts,
world depth, or cognition-track scope.

**Policy boundaries (settled — do not regress)**

- Simulation LOD (tier, halos, stagger, scope gathers) controls fixed-step
  processor participation only.
- Render visibility (camera chunk window, pixel AABB, render overscan margin)
  controls draw-record construction only.
- Scope pin metadata may keep an entity in a higher sim band off-camera; it must
  not bypass render visibility.

**Simulation scale**

- [x] **World-gate SIMD** — promoted into [Slice 35](slices/slice-35.md)
      (a `world-gate` bench item, then a SIMD + threading item gated on that
      bench's trigger).
- [x] **Interest marker consumers beyond investigate** — promoted into
      [Slice 61](slices/slice-61.md) (`resource`), [Slice 71A](slices/slice-71a.md)
      (`patrol`), and [Slice 71C](slices/slice-71c.md) (`cover`); closed.
- [ ] **Movement contiguous-path vs scoped LOD.** Any dormant movement row
      disables the contiguous SIMD movement fast path for the whole step. At
      steady-state LOD with routine off-camera sleepers, revisit compacted-dense
      movement iteration or a dormant-fraction threshold (Slice 24 follow-up).
- [x] **Per-entity depth axis.** Landed in archive Slice 25E (`world_level` /
      scope level / render cull alignment). Residual multi-floor chase policy
      is product work on open slices, not a missing column.
- [ ] **Component storage headroom.** `Component` is `enum(u5)` (32 tags) and
      `ComponentMask` is `u32` — **14 tags used today** (`movement_body`…`destructible`).
      Slice 45 added `destructible`; Slice 41 stored interest markers on
      `WorldSystem`, not a new tag. Planned appends from the VoidLight port
      track:
      - 56: `health`, `combat_stats`
      - 56B: `projectile`
      - 57: `inventory`, `equipment`, `world_item`
      - 61: `resource_node`
      - 62: `spawn_origin`
      - 63: `social_ledger`, `merchant`

      - 71A: `ai_post`

      That is **11 new, 25 of 32 when all land** (7 spare; Table T5 in the
      [VoidLight port track](tracks/voidlight-port.md)). Slices 49–55, 58,
      59, 60, and 64–71 other than 71A add none: worldgen, clock, and anchor
      state live on `WorldSystem`, and `FactionRelations` is a `DataSystem`
      field. Tags are appended in landing order and never pinned in slice
      text. Promote a widening slice only when the first new tag would exceed
      32.
- [ ] **Multi-world scope policy.** Inactive world instances stay out of
      pipeline scope; the active world uses chunk + halo rules (Slice 22
      deferred).

**Battle-scale perf watch (2048 movers)**

**How to use:** fix cycles in **Debug**; intentional soaks in **ReleaseSafe**
(`zig build run -Doptimize=ReleaseSafe`), **one** 60s dump after load (not
multi-minute dual cycles unless comparing load vs settle). Same pop
(`battle_scale_demo_mover_count = 2048`), similar play. Diff new dumps against
the control table below: if stage lines move while selected/observer counts
stay similar → suspect **net-new code**; if selected/observers jump → **scope
density of the feature**. Sub-stage lines `steering_setup` / `collision_setup`
separate setup from batch. Do not min-max sub-ms when gameplay stays in band.

**ReleaseSafe control baseline (post-load, ~60s, 2048 movers)**

| Metric | Control band |
|--------|----------------|
| gameplay avg | **1.6–1.9 ms** |
| frame (present-bound) | **~8.3 ms** (~120 FPS); cap_hits **0–1** |
| steering stage | **~0.65–0.70 ms** |
| steering select / snapshot / directions | **~0.03 / ~0.33–0.34 / ~0.17–0.20 ms** |
| steering batch | **~0.40 ms** |
| collision stage | **~0.21 ms** |
| collision gather / sort | **~0.09 / ~0.02 ms** |
| AI stage | **~0.15–0.20 ms** |
| perception stage | **~0.16–0.20 ms** |
| pathfinding avg (steady; ignore load max) | **~0.05–0.06 ms** |
| cognition selected / observers (per step) | **~330 / ~140** |
| movers (per step) | **~2000–2050** |

Known costs inside that band (document, don’t thrash unless denser cognition
forces a move): full agent snapshot every cognition step (~0.33 ms Safe);
avoidance batch (~0.40 ms → Slice 35); collision gather (~0.09 ms Safe).

After the Slice 55 soak, add control rows `ai decide / coast_skips (per step)`
and `ai_decide_gather stage`; from then on `ai_stage_entities` ("cognition
selected") counts decided rows, not the think set. Slices 56, 56B, 57, 58, 61,
and 62 change the soak population; each re-baselines with the normative
procedure and row schema in [Slice 68A](slices/slice-68a.md) §3.

- [x] **Steering main-thread setup + event-driven caches.** Instrumented
      select / snapshot / directions; select one-slot resolve; path start from
      `scope.level[mi]`; **steering→movement dense index cache** (rebuild only
      on structural create/destroy/steering|movement component change); agent
      cell bins via dense SIMD assign + pdqsort; static obstacle spatial
      retained until post-commit invalidation or cell-size change. Remaining:
      Slice 35 avoidance SIMD when batch math dominates (`steering.zig`).
- [ ] **Collision full-sort under melee density.** Mid-pack soaks saw
      `full_sorts` jump (e.g. 1→24) while stage avg stayed ~0.21ms; broadphase
      batch ~0.09ms. Use `collision_setup` gather/sort timings +
      `full_sort_disorder_percent` (default 12%) to decide if full sort is
      expected melee disorder or a retune. Do not change SAP order without
      measured parity. (`collision.zig`)
- [ ] **AI separation density.** Sep samples ~2–3× when running through the
      pack; scales with denser cognition. Confirm gather vs sep batch owner via
      existing ai_separation batch line; vectorize with Slice 35 when math
      dominates. Keep candidate/sample caps fixed (world-size independent).
      Slice 55 removes separation and cohere queries for coasting idle rows;
      per-row math stays with Slice 35. (`ai.zig`, Slice 35)
- [ ] **Path group fields + cache pressure.** `group_built=0` at 2048 is
      intentional: demo pins `min_group_field_agents = 2000` after measuring
      that pending-dedup/cache already serves shared-goal bursts (see
      `proceduralPathfindingCapacity`). Re-measure eviction rate (~20k/min)
      and group payoff only when simultaneous same-goal demand from
      relationships/ships exists — do not lower the pin without a fresh 60s
      capture. Shared-goal prewarm is [Slice 71B](slices/slice-71b.md) (71B.3,
      A/B acceptance; the pin is unchanged). (`game_demo_state.zig`,
      pathfinding capacity)
- [ ] **Perception tail.** Stage avg ~0.16ms, max ~2.4ms. Only if denser
      observers fill the tail; gather multi-lookup polish optional; FOV path
      already partially SIMD. (`perception.zig`)

**Branch / packaging residuals**

- [x] **Slice 23A merge — settled.** GPU tilemap hardening (archive Slice 23A)
      is merged into `main` (`expand2`/`world` are ancestors of HEAD). The only
      remaining item is the optional O(n) linear `mergeDrawList` micro-opt below,
      to do after measuring — not a merge task.

**Render scale**

- [ ] **Dynamic collect scan cost.** Collect walks every movement-body row;
      camera gates skip draw prep but not the scan. Hardening: warmed visible
      movement dense-index list parallel to scoped simulation gathers (Slice 22
      handoff; partial inline gating landed in 24B).
- [ ] **Dense floor submit vs camera.** Each dense composite draw (Slice 36) is
      still one full-world tilemap quad regardless of camera pan (GPU clips).
      Hardening: chunked dense submit if quad cost dominates at very large
      worlds.
- [ ] **On-screen record ordering.** `finalizeDepthBuckets` sorts collected
      dynamic records; replace with fixed-band or counting buckets when on-screen
      density rises (Slice 24B follow-up).
- [ ] **Bench phase isolation.** Split `render-game-prep` collect vs sparse/dynamic
      emit timers so regressions name the hot phase (Slice 24B follow-up).

**VoidLight port residuals**

Every residual the VoidLight port track (Slices 49–63) created is now owned by
a numbered slice (Slices 64–71, or a Checklist addition to an existing slice).
Nothing below is open backlog.

*Determinism and threading (49–51)*

- [x] **Deterministic trig for cross-machine determinism** — promoted into [Slice 52D](slices/slice-52d.md) (sin/cos) and [Slice 64D](slices/slice-64d.md) (vector `atan2`)
- [x] **Headless replay runner** — promoted into [Slice 64C](slices/slice-64c.md)
- [x] **Threaded per-dense-layer checksum hashing** — promoted into [Slice 64B](slices/slice-64b.md)
- [x] **Decouple render interpolation history from the simulation pre-step pose** — promoted into [Slice 64A](slices/slice-64a.md) (plus a Slice 60 Checklist addition)
- [x] **Background lane OS priority and core reservation** — promoted into [Slice 65A](slices/slice-65a.md)
- [x] **Nav large patch and full relabel on the background lane** — promoted into [Slice 65B](slices/slice-65b.md)
- [x] **Consolidate `thread_shared_record_alignment`** — promoted into [Slice 65A](slices/slice-65a.md)
- [x] **`WorkerRecord` wake-semaphore padding** — promoted into [Slice 65A](slices/slice-65a.md)
- [x] **Controller state in the checksum** — promoted into [Slice 64B](slices/slice-64b.md) (plus Slice 46/56/57 Checklist additions)
- [x] **Random per-session seed and New Game flow** — promoted into [Slice 64C](slices/slice-64c.md)
- [x] **Scalar float `@min`/`@max` in simulation code** — promoted into [Slice 64A](slices/slice-64a.md)
- [x] **NaN bit patterns differ between x86 and arm64** — promoted into [Slice 64B](slices/slice-64b.md) (float keys: [Slice 64A](slices/slice-64a.md))
- [x] **FP environment** — promoted into [Slice 64A](slices/slice-64a.md)
- [x] **Upstream Zig issue (`@Vector(N, bool)` lowering)** — promoted into [Slice 52D](slices/slice-52d.md) (Checklist addition)
- [x] **Vector `atan2`** — promoted into [Slice 64D](slices/slice-64d.md)

*Release and packaging (52A–52D)*

- [x] **Linux AppImage / Flatpak** — promoted into [Slice 66C](slices/slice-66c.md) (Flatpak rejected)
- [x] **macOS Developer ID signing, notarization, `.dmg`** — promoted into [Slice 66C](slices/slice-66c.md)
- [x] **Windows Authenticode signing** — promoted into [Slice 66C](slices/slice-66c.md)
- [x] **Split debug symbols** — promoted into [Slice 66A](slices/slice-66a.md)
- [x] **More package targets** — promoted into [Slice 66B](slices/slice-66b.md)
- [x] **Authoritative perf runner** — promoted into [Slice 66E](slices/slice-66e.md)
- [x] **Runtime X11 window icon** — promoted into [Slice 66A](slices/slice-66a.md)
- [x] **Steam depot / SteamPipe upload automation** — promoted into [Slice 66D](slices/slice-66d.md)

*UI, text, settings, and saves (53A, 53B, 54, 44, 46)*

- [x] **Debug overlay text migration** — promoted into [Slice 67B](slices/slice-67b.md)
- [x] **UI pointer input** — promoted into [Slice 67A](slices/slice-67a.md)
- [x] **Text input widget** — promoted into [Slice 67C](slices/slice-67c.md)
- [x] **Gamepad hold-to-repeat menu navigation** — promoted into [Slice 67A](slices/slice-67a.md)
- [x] **Event-log widget** — promoted into [Slice 67B](slices/slice-67b.md)
- [x] **Save thumbnails** — promoted into [Slice 67C](slices/slice-67c.md)
- [x] **Scancode keyboard bindings** — promoted into [Slice 67A](slices/slice-67a.md)
- [x] **Text atlas page cap vs CJK-scale glyph sets** — promoted into [Slice 67B](slices/slice-67b.md) (telemetry), [Slice 67E](slices/slice-67e.md) (localization roots), and [Deferred By Owner → Full localization](../framework-implementation-slices.md#deferred-by-owner) (locale font subsets; deferred)
- [x] **UI navigation SFX** — promoted into [Slice 67B](slices/slice-67b.md)

*Cognition decision LOD (55)*

- [x] **AI candidate side-table halo walk** — promoted into [Slice 68A](slices/slice-68a.md)

*Combat, items, and worldgen (56–58)*

- [x] **`step_count` width and wrap** — promoted into [Slice 49](slices/slice-49.md) (`StepIndex = u64`) and [Slice 56](slices/slice-56.md) (`stepAfter` / `stepReached`)
- [x] **Shared action bus under battle load** — promoted into [Slice 68A](slices/slice-68a.md)
- [x] **Knockback (movement impulses)** — promoted into [Slice 68B](slices/slice-68b.md)
- [x] **Retaliation memory** — promoted into [Slice 68B](slices/slice-68b.md)
- [x] **Carried-inventory drop and ammo** — promoted into [Slice 68C](slices/slice-68c.md)
- [x] **Worldgen off the main thread** — promoted into [Slice 65C](slices/slice-65c.md)
- [x] **Worldgen breadth** — promoted into [Slice 69A](slices/slice-69a.md) (caves, structures, autotile edges) and [Slice 69F](slices/slice-69f.md) (paged regions)
- [x] **Resource interest markers** — promoted into [Slice 58](slices/slice-58.md) (Checklist addition)
- [x] **Battle-scale control re-baseline** — promoted into [Slice 68A](slices/slice-68a.md) (§3 procedure)

*World presentation (59–60)*

- [x] **Environment caution → affect** — promoted into [Slice 42](slices/slice-42.md) (Checklist addition)
- [x] **Regional/biome weather** — promoted into [Slice 69B](slices/slice-69b.md)
- [x] **Scripted weather override / time skip (sleep)** — promoted into [Slice 69C](slices/slice-69c.md) (time skip) and [Slice 69D](slices/slice-69d.md) (weather override)
- [x] **Slice 46 must round-trip `WorldSystem.clock.game_ms` and `level_sky_exposed`** — promoted into [Slice 46](slices/slice-46.md) (Checklist addition)
- [x] **Slice 38: `addElevatedLevelStack` passes `level_sky_exposed = true`** — promoted into [Slice 38](slices/slice-38.md) (Checklist addition)
- [x] **Scene resolution as a runtime setting** — promoted into [Slice 70B](slices/slice-70b.md)
- [x] **Default gamepad zoom binding** — promoted into [Slice 70B](slices/slice-70b.md)
- [x] **Screen fade-out before a state swap** — promoted into [Slice 70B](slices/slice-70b.md)
- [x] **`world_pixel` on non-integer viewport scale** — promoted into [Slice 70B](slices/slice-70b.md)
- [x] **Zoom tween** — promoted into [Slice 70B](slices/slice-70b.md)
- [x] **Weather spawn rect at high zoom** — promoted into [Slice 69E](slices/slice-69e.md)

*Harvesting, population, and social (61–63)*

- [x] **AI behavior parity audit (VoidLight → ZeroLight)** — promoted into [Slice 71A](slices/slice-71a.md)
- [x] **Path prewarm for shared goals (fixed budget)** — promoted into [Slice 71B](slices/slice-71b.md) (71B.3)
- [x] **Static-collider split path** — promoted into [Slice 71B](slices/slice-71b.md) (71B.1 shared index, 71B.2 split)

**Sequencing guardrails**

- Raise entity stress counts and world depth only after `validateDenseRenderBudget`
  passes and scope stats show typical participation stays below bench ceilings.
- Per-entity depth alignment (archive 25E) is settled before multi-floor
  gameplay scenarios that depend on cross-level entity presence.
- Slice 32 (arbitration + per-agent goals) and multi-source investigate inputs
  (39, 41) are landed; Slice 33 authoring is landed (close the visual residual
  before shipping heavily data-tuned demo personalities as a product claim).
- Do not scale cognition population (archetype swarm stress) until arbitration
  is gated by the existing cognition-scope dense indices and benches report
  intent-selection cost separately from pathfinding, and Slice 55 decision
  coasting is landed and benched on an idle-heavy population.
- Keep locomotion emergence (32–33 + 39 + 41) independent of action/combat
  emergence (40+): `NavigationIntent` stays stable while action intents grow
  beside it, not inside it. (Historical: the reserved interest kinds are all
  wired after Slice 71C — investigate 41, resource 61, patrol 71A, cover 71C;
  none is half-wired into investigate scoring.)

