# Engine Design

Rules live only in `.claude/rules/` and never conflict; docs describe and cite
them. A rule states an actionable principle and names the owner modules,
boundaries, contract types, tools, and stable APIs it guards; implementation
detail (helper sets, fields, stages, benches, examples) lives in the doc it
cites, which docs commits keep current. The rules and `docs/architecture.md`
win over code: code that disagrees is wrong and is fixed, never a pattern to
copy or extend or an excuse for a departure. A rule that blocks a sound design gets a
proposed edit with its reason; once the owner approves it, it lands in its
rule file in the same change. Never loosen a rule to ease work. Owner decisions are not reopened.

## Target scale

- Engine core for a fully simulated, growing, multi-world colony simulator. A
  player entity is optional; one observer is targeted (the camera focus, or
  the player). The demo is a test harness: its sizes, populations, and counts
  are never design, sizing, or acceptance inputs.
- Everything that exists keeps advancing, in every world: distance from the
  observer lowers fidelity, never progress (far-off AI thinks on slower ticks;
  cheap processors such as movement stay near full rate). Dormant is only for
  inert things (items at rest), which still change slowly (decay outdoors).
  Only a pause stops progress, and a pause stops everything: every world and
  every system.
- Population that matters (villagers, people, NPCs) persists and advances
  wherever it is; only unimportant ambient spawns (stray monsters, animals)
  may be recycled far from the observer.
- The chunk `(level, cx, cy)` is the unit of terrain and nav storage, change,
  work, threading, and save. Nav covers the whole world; residency is a
  chunk's storage form, never whether it simulates.
- Worlds (persistent worlds, dungeons) and their levels are created and
  destroyed in play; each owns its storage, and its memory goes with it.
- Target scale is a floor: 2048² levels, deep stacks that grow in play, several
  worlds, large populations. Dense multi-chunk terrain change in one step
  (cave-ins, explosions) is normal gameplay.
- The bar is the target scale itself: what shipped games do is never a
  standard, a justification, or a reason to accept less.

## Cost model (before code)

Every design, and every fix touching storage or per-change work, states:

- Work and memory as growth orders in what changed, what exists, and extent
  (level size, depth, world count) for: a local change (one dig, ramp, chunk);
  a dense one-step change (an explosion region); creating or destroying a
  world, level, or dungeon; a population's per-step load (its requests,
  queries, and updates in every world). Concrete sizes only illustrate.
- Pass: local-change cost depends only on what changed, except reachability
  maintenance (`budgets-capacities.md`); a population's per-step load is O(1)
  per requester plus the distinct work requested (goals, regions, chunks),
  summed over worlds; memory follows what exists and is released with it;
  nothing is sized from demo constants; nothing stops advancing because the
  observer is far away.
- The serial and threaded paths (`threading.md`), and per hot loop SIMD via
  `src/core/simd.zig` or scalar with the reason (`memory-performance.md`
  § SIMD and core math), reusing the engine's proven SIMD and threaded SIMD
  patterns. Threading and SIMD are standard, never optional.
- Each order marked measured (bench group) or derived; a derived number is
  never presented as measured. Scaling benches measure each hot-path order at
  the worst-case shape its bound names (thin, long, deep, dense), not only
  typical fixtures.
- Start from the engine's proven patterns (the stage pattern, chunk-owned
  work, existing kernels and dispatch shapes), cited by `file:line`; new
  machinery needs a measured reason they cannot serve.
- Where code already partitions by a unit (chunk, level, world), the first
  design evaluated has that unit own its storage and work; a shared arena,
  global rebuild, or level-wide shift needs a cost model that beats it.
- A computed result (proof, region, path, summary) is stored at the unit it
  covers and shared by every requester it answers, never recomputed per
  requester; one keyed finer than what it proves fails. Intermediate work
  counts: a walk, gather, or candidate list requesters repeat identically is
  a shared result.
- A part of the existing structure that cannot pass is redesigned to the
  rules, never patched around; code, tests, and benches built on it go with
  it and are never design references or correctness baselines. The redesign
  is tuned within reason against the replaced code's timings, same mode: a
  gap the added correctness or rule compliance costs is reported, a gap from
  overhead is a regression (`tests-benchmarks.md`).
- Default is keep: replacing a part that passes needs a concrete performance
  or efficiency benefit against its cost and risk.
- Right before implementation, check the design against the live code it
  changes: the serial/inline path adds no growing work (a worse order or a new
  per-item scan) over the code it replaces, and no per-item growing work stays
  on the main thread (`threading.md`); a failure fixes the design before code.
  A constant per-item cost of nanoseconds is reported, never a reason to
  redesign. Earlier `file:line` refs are re-checked here, never trusted.

## Ownership boundaries

- `main.zig` is entry and fixed-step timing only; `root.zig` stays minimal.
- App coordination lives in `src/app/`, SDL_GPU work in `src/render/`, gameplay
  in `src/game/`, math/SIMD/logging in `src/core/`, SDL wrappers in
  `src/platform/`. Never move a boundary for a local convenience.
- Dependencies point down: `src/game/` may import `render/`, `assets/`,
  `core/`, `platform/`, and the `src/app/` services it runs on
  (`ThreadSystem`, the state and input interfaces, audio, the runtime perf
  log); `src/app/` imports game states only to construct them; `render/`,
  `assets/`, `core/`, and `platform/` never import `src/game/`; `core/`
  imports only `core/`, `platform/` only `core/`. Dev-tool roots
  (`gpu_smoke.zig`, `benchmark_runner.zig`, `tests.zig`) sit outside the
  layers and may import any; no layer imports them.
- Gameplay logic lives in states, controllers, and processors, never in
  `main.zig` or `Engine` conditionals.
- App and game code use `Renderer`, the only code that touches SDL_GPU; never
  import `src/render/gpu/*` outside render/platform, and never call SDL_GPU,
  Vulkan, or Metal from game code.
- Engine services never keep pointers to sibling service fields; release paths
  take the live owner explicitly. State and gameplay teardown never receive
  renderer, text, audio, or GPU services to clean up escaped resources.
- Debug overlays and introspection are read-only over simulation.
- No new dependency unless stdlib or SDL3 cannot do it (PNG decode uses core
  SDL3; no `SDL3_image`); never vendor SDL binaries.
- Plan and build only confirmed features: no format, tool, or subsystem nobody
  asked for; anything unconfirmed is an owner question.

## Changes and docs

- Search the owning module for an existing utility before adding one; keep
  changes scoped; never reformat or refactor unrelated code.
- A change lands complete: every piece it needs to be correct (fallbacks,
  keeping its inputs current, tests) is in the same landing, never half a
  mechanism with the rest offered later.
- A small local defect found in passing (a stale comment, a noisy test, dead
  code, a callerless `pub`) is fixed on the branch, in the landing that
  touches its file or its own commit, never only mentioned. This covers
  defects, not refactors.
- `README.md` is an overview (what it is, one-line feature bullets,
  requirements, quick start, commands, layout, doc links); how things work
  belongs in `docs/`.
