# Engine Design

Rules live only in `.claude/rules/`; docs describe and cite them. No two rules
conflict. The rules and `docs/architecture.md` win over code: code that
disagrees with them is wrong and is fixed. When a rule blocks a sound design,
propose the edit with its reason; it changes in its rule file in the same
change, never by loosening a rule to ease work. Owner decisions are not
reopened.

## Target scale

- This is engine core for a fully simulated, growing, multi-world colony
  simulator; a player entity is optional (one observer is targeted: the camera
  focus, or a player when a game has one). The demo is a test harness; its
  sizes, populations, and counts are never design, sizing, or acceptance
  inputs.
- Everything that exists keeps advancing, in every world. Distance from the
  observer lowers fidelity, never stops progress: far-off AI thinks on slower
  ticks while cheap processors such as movement stay near full rate. Dormant is
  for inert things only (items at rest), which still change slowly (decay
  outdoors).
- Population that matters (villagers, people, NPCs) persists and keeps
  advancing wherever it is; only unimportant ambient spawns (stray monsters,
  animals) may be recycled far from the observer.
- The chunk `(level, cx, cy)` is the unit of terrain and nav storage, change,
  work, threading, and save. Nav covers the whole world; residency is a
  chunk's storage form, never whether it simulates.
- Worlds (persistent worlds, dungeons) are created and destroyed in play and
  own their storage.
- Target scale is a floor: 2048² levels, deep stacks that grow in play, several
  worlds, large populations.
- Dense multi-chunk terrain change in one step (cave-ins, explosions) is normal
  gameplay.

## Cost model (before code)

Every design, and every fix touching storage or per-change work, states:

- Work and memory as growth orders in what changed, what exists, and extent
  (level size, depth, world count) for a local change (one dig, ramp, chunk), a
  dense one-step change (an explosion region), and creating or destroying a
  world, level, or dungeon. Concrete sizes only illustrate an order.
- Pass: local-change cost depends only on what changed; memory follows what
  exists and is released with it; nothing is sized from demo constants;
  nothing stops advancing because the observer is far away.
- The serial and threaded paths (`threading.md`).
- Each order marked measured (bench group) or derived; a derived number is
  never presented as measured. Hot-path orders are measured
  (`tests-benchmarks.md`).
- Where code already partitions by a unit (chunk, level, world), the first
  design evaluated has that unit own its storage and work. A shared arena,
  global rebuild, or level-wide shift needs a cost model that beats it.
- If part of the existing structure cannot pass, redesign that part; never
  patch around it. Code, tests, and benches built on a failing part go with
  it and are never references or baselines.
- Default is keep: replace only the parts that fail the cost model; replacing
  a part that passes needs a concrete performance or efficiency benefit
  against its cost and risk.

## Ownership boundaries

- `main.zig` is entry and fixed-step timing only; `root.zig` stays minimal.
- App coordination lives in `src/app/`, SDL_GPU work in `src/render/`, gameplay
  in `src/game/`, math/SIMD/logging in `src/core/`, SDL wrappers in
  `src/platform/`. Never move a boundary for a local convenience.
- Gameplay logic lives in states, controllers, and processors, never in
  `main.zig` or `Engine` conditionals.
- App and game code use `Renderer`; never import `src/render/gpu/*` outside
  render/platform, and never call SDL_GPU, Vulkan, or Metal from game code.
- Engine services never keep pointers to sibling service fields; release paths
  take the live owner explicitly.
- State and gameplay teardown never receive renderer, text, audio, or GPU
  services to clean up escaped resources.
- Debug overlays and introspection are read-only over simulation.
- No new dependency unless stdlib or SDL3 cannot do it (PNG decode uses core
  SDL3; no `SDL3_image`); never vendor SDL binaries.
- Plan and build only confirmed features: no format, tool, or subsystem nobody
  asked for.

## Changes and docs

- Search the owning module for an existing utility before adding one; keep
  changes scoped; never reformat or refactor unrelated code.
- `README.md` is an overview (what it is, one-line feature bullets,
  requirements, quick start, commands, layout, doc links); how things work
  belongs in `docs/`.
