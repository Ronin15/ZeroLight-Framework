## Slice 10: DataSystem And SoA Composition Foundation

Goal: introduce `DataSystem` as the state-owned persistent gameplay data
container and save/load streaming boundary, with dense SoA storage designed for
fast systems, threading, and SIMD.

Current foundation:

- `StateStack` owns active state lifetimes.
- `UpdateContext` exposes `ThreadSystem` to states.
- `GameDemoState` owns a `DataSystem` for state-local persistent game-world data.
- `Player` remains a player-specific behavior facade, backed by entity data in
  `DataSystem`.

Architecture notes:

- `DataSystem` is intentionally the unique name for the persistent data
  container.
- `DataSystem` persists for the lifetime of the owning gameplay state, not as a
  global app singleton.
- Systems are processors that borrow or view `DataSystem`; they do not own
  persistent gameplay data.
- Save/load should stream `DataSystem`, not `Engine`, `StateStack`, renderer,
  thread system, input, or transient frame state.
- Composition comes from meaningful data membership in typed stores, not from a
  free-form component soup where arbitrary behavior combinations are implied.
- Per-entity component masks are the membership/query layer. Hot system data is
  still exposed through aligned scalar SoA slices, not joined dynamically in the
  update or render loop.

Checklist:

- [x] Add a game data module with `DataSystem` and an entity ID/generation
      registry.
- [x] Add dense scalar-column SoA stores for initial persistent gameplay data
      such as movement bodies and renderable primitive visual intent.
- [x] Use stable handles or dense indices so stores can remain compact while
      rejecting stale IDs.
- [x] Keep SDL handles, GPU handles, input frame state, renderer state,
      `ThreadSystem`, transient events, and scratch buffers outside `DataSystem`.
- [x] Store persistent asset references as stable IDs or relative paths, not
      live renderer texture handles.
- [x] Add explicit init/deinit and clear/reset behavior for state lifecycle and
      save/load preparation.

Acceptance checks:

- [x] Entity IDs reject stale generations after removal and reuse.
- [x] Dense SoA stores keep arrays length-aligned and compact after add/remove.
- [x] Movement-body columns can be loaded directly with `src/core/simd.zig`
      helpers and handle vector ranges plus scalar tails.
- [x] Component masks track entity membership for future system queries without
      replacing the SIMD-ready SoA storage.
- [x] `DataSystem` can be initialized and deinitialized without leaks.
- [x] Tests cover which data belongs inside `DataSystem` versus transient runtime
      services that must stay outside it.

Slice 10 landed as a state-owned data foundation. Update systems mutate
`DataSystem` slices, render systems read immutable slices and submit through
`Renderer`, and live engine/runtime services stay outside persistent data. The
movement-body store is SIMD-ready scalar SoA storage; threaded/SIMD processors
remain Slice 11 work.

