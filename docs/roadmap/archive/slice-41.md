## Slice 41: World Interest And Affordance Markers

**Status: landed.**

Goal: durable world-authored interest points so investigate goals are not
limited to entities, dig stimuli, and demo player fallback.

**Ownership:** `src/game/world_interest.zig` embedded in `WorldSystem`
(`interest_markers`). Markers ≠ ephemeral `WorldStimulus`; not `DataSystem`
components.

Checklist:

- [x] Marker storage + kind enum + add/remove; level isolation and capacity tests.
- [x] Bounded query API (`interest_query_max_k`, fixed `interest_marker_capacity`).
- [x] Investigate scoring/goal resolution: stimulus > marker > ring; null store
      preserves prior behavior.
- [x] Demo places surface investigate markers; pipeline passes read-only store to
      `AiConfig.interest_markers`.
- [x] `docs/architecture.md` records ownership and investigate priority.

Acceptance checks:

- [x] Agents investigate markers without entity targets (`ai.zig` serial test).
- [x] Queries allocation-free by construction (fixed inline arrays; hot add/query
      take no allocator — proven in `world_interest.zig` signature/layout tests).
- [x] `zig build verify` passes.

**Review follow-ups (landed with the store):** nearest-k public query, discovery
geometry = query radius only, faction filter restricted-unless-proven, null-store
preserves stimulus/ring, gain-gated AI gather.

