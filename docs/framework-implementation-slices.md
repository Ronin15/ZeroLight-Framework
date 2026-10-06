# Framework Implementation Slices

This roadmap is the agent implementation contract for the project frontier.
Work is organized as **numbered slices**: each slice is one complete,
verifiable feature chunk with a **Goal**, **Checklist**, and **Acceptance
checks**. Agents implement by opening a slice file, checking items off only
when integrated, and running `zig build verify` before marking the slice
complete.

**Layout.** This file is the index only: rules, workflow, the open slice
table, priorities, and the Suggested Order. Each open slice or sub-slice is
one file under [`roadmap/slices/`](roadmap/slices/); settled slices are one
file each under [`roadmap/archive/`](roadmap/archive/) (index:
[framework-implementation-slices-archive.md](framework-implementation-slices-archive.md)).
Shared context lives in [`roadmap/tracks/`](roadmap/tracks/) —
[VoidLight port](roadmap/tracks/voidlight-port.md) (shared contracts and the
authoritative cross-slice tables T1–T6), [Emergent AI](roadmap/tracks/emergent-ai.md),
[Long-term gameplay direction](roadmap/tracks/gameplay-direction.md) — and
measured pressure points live in [Scaling Gaps](roadmap/scaling-gaps.md).

**Reading rule.** To implement a slice, read this index, the one slice file,
and only the track/contract files that slice links. Do not load the whole
roadmap. Each slice file starts with a header line naming its dependencies and
track.

Landed slices that still need manual/`gpu-smoke` confirmation (33, 43) stay
open until that residual is closed.

## Ground Rules

- Preserve runnable defaults: `zig build`, `zig build run`, and installed assets
  should keep working after every slice.
- **A slice is not complete until every Checklist and Acceptance check in its
  slice file is `[x]`** and runtime behavior, owning-module docs, and tests are
  integrated. Partial wiring stays `[ ]` with explicit remaining notes in the
  slice file — never implied complete elsewhere.
- **One file per slice or sub-slice** under `docs/roadmap/slices/`
  (`slice-<id>.md`, lowercase id; umbrellas such as `slice-64.md` summarize
  their sub-slices). Every open slice file has exactly one row in the Open
  Frontier Slice Index below, and every row links to its file.
- **Completed slices move to the archive.** When every item is `[x]`, `git mv`
  the file to `docs/roadmap/archive/`, move its index row from this file to
  the [archive index](framework-implementation-slices-archive.md) table, and
  update the Suggested Order annotation. Do not delete acceptance history.
- **No backlog dumping.** Design and review work never parks discovered
  follow-ups as bare Scaling Gaps/backlog lines. Each one becomes a Checklist
  item in its owning slice or a decision-complete new slice (Status may be
  "gated on <trigger>"). Scaling Gaps holds only measured pressure points
  awaiting a benchmark. "Out of scope" text must name the slice that owns the
  work. Exception: items the owner explicitly defers go in
  [**Deferred By Owner**](#deferred-by-owner) with their trigger; agents
  never add entries there on their own.
- Keep hot paths simple: prefer enums, bitsets, arrays, and generational slot IDs
  over dynamic dispatch, string lookup, or hash maps during input/update/draw.
- If a dependent system does not exist yet, label the work as foundation or
  preparation and leave the slice checklist incomplete.
- Avoid half-wired states; either finish the slice end to end or keep every open
  item visible in that slice's Checklist or Acceptance checks.
- Keep `src/root.zig` minimal; feature modules should live in their matching
  `src/` area and import each other directly when needed.
- Read [architecture.md](architecture.md) and the owning live modules before
  editing; code wins over stale slice prose when they disagree.
- A new fixed-step system lands in `SimulationPipeline` as one `StageId`, one
  `stage_order` entry, a complete `stageContract` (reads, writes, and carried
  resources), and one `runStage` arm. The comptime stage-order checks are the
  dependency gate. Do not add a scheduler beside the pipeline. The planned
  merged order is Table T4.
- Every new work budget or capacity cap is a fixed constant. A world, level
  count, cell count, portal count, or dense-band count that does not fit is
  refused or deferred. Do not size a cap to one map, and do not replace a cap
  with a window computed from that world's level or band counts.
- Do not promote threaded stage overlap, nav-remask cost changes, render-collect
  scan changes, or persistence beyond Slice 46's written stable-ID boundary
  into a checklist until those behaviors are confirmed in the live modules.
  Slice 46 remains the save/load slice as its file specifies. Slice 54
  settings are app preferences, never save data. A later slice that adds
  persistent `DataSystem`/`WorldSystem` state classifies it in Slice 49's
  checksum completeness lists (and 64B's classification) and adds its Slice 46
  save section in the same change; that stays inside Slice 46's stable-ID
  boundary.
- Version numbers (replay format and flag bits, settings schema, save format,
  checksum tag), `stage_order` positions, and component tags follow the
  authoritative Tables T1–T6 in the
  [VoidLight port track](roadmap/tracks/voidlight-port.md). Every bump is
  relative (live value + 1); a slice that changes one updates the table in
  the same change.
- Run `zig build verify` before considering a slice complete.

## Agent Workflow: Implementing A Slice

1. **Pick a slice** from the **Open Frontier Slice Index** (below) or the
   **Suggested Order** when dependencies matter. Confirm the prerequisites
   named in the slice file's header line are settled (archive files and/or
   live Status) before starting.
2. **Open the slice file** (`docs/roadmap/slices/slice-<id>.md`), or the
   archive file if you need a landed prerequisite's acceptance record. Read
   **Goal**, **Current foundation**, and **Architecture notes**; cross-read
   [architecture.md](architecture.md), the track file in the header line, and
   any doc linked in the slice. Do not read other slice files unless the slice
   links them.
3. **Implement only that slice's scope** in the owning `src/` modules. Do not
   expand into unrelated refactors.
4. **Check off items** in the slice file's **Checklist** as each integration
   lands (runtime behavior + tests for that item). Items marked "(added by
   Slice N)" came from another slice's design and are part of this slice's
   scope.
5. **Satisfy Acceptance checks** — each must pass before the slice is done.
6. **Update durable docs** the slice touches (`architecture.md`, rendering/sim
   docs) when contracts change, and the T1–T6 tables when a number moves.
7. **Set slice Status** and run `zig build verify`.
8. **When complete,** move the file to `docs/roadmap/archive/` and its row to
   the archive index (Ground Rules). Follow-ups go into a slice Checklist or a
   new slice file, never into Scaling Gaps.

### Standard slice file shape

Every slice file contains (some fields optional for early foundation slices):

| Block | Agent use |
| --- | --- |
| Header line | Roadmap index link · Depends on (linked slices) · Track |
| **Goal** | What "done" means for this chunk |
| **Current foundation** | What already exists — do not rebuild |
| **Architecture notes** / **Problem** | Constraints and ownership boundaries |
| **Checklist** | `[ ]` / `[x]` implementation steps — check off as you land each |
| **Acceptance checks** | `[ ]` / `[x]` verification gates — all required before complete |
| **Status** | Open/partial note, or one-line completion record before the archive move |

## Open Frontier Slice Index

Use this index to choose the next slice; **implement from that slice's file**
(checklists live there, not here). Settled acceptance history is in the
[archive](framework-implementation-slices-archive.md).

| Slice | Status | Open work (see the slice file for the full Checklist) |
| --- | --- | --- |
| [**33**](roadmap/slices/slice-33.md) | Landed (visual/GPU-smoke verification pending) | Data-driven AI archetypes (JSON→enum bundle table) + debug introspection overlay — implemented and unit-tested; on-screen viz (F2) confirmed only via `gpu-smoke`/manual run |
| [**35**](roadmap/slices/slice-35.md) | Not started | AI/steering hot-loop SIMD restructure — unblocked (Slice 32 landed); measure at battle scale after Slice 55 coasting and 52D codegen (the two compose) |
| [**38**](roadmap/slices/slice-38.md) | Not started | Elevation above the surface (prerequisite Slice 37 landed); derives `level_sky_exposed` from elevation and gives `addLevel` an implicit one-below-lowest elevation (Slice 69 addition) |
| [**42**](roadmap/slices/slice-42.md) | Not started | Affect expansion — data-driven appraisal gains, cross-drive coupling, optional mood, optional `pain` drive on Slice 56's damage watermark, environment caution as a per-entity fear gain (needs 59); the first new drive (`need`) lands in Slice 61 — after 56, 61 |
| [**43**](roadmap/slices/slice-43.md) | Landed (manual HW verification pending) | SDL3 gamepad/controller support — single active device, analog movement, default button bindings (app/input layer; independent of AI/render tracks) |
| [**44**](roadmap/slices/slice-44.md) | Not started | Input rebinding: Controls screen + press-any-key capture on 53B (`list` widget), persisted via Slice 54 settings (next schema version), gamepad family + button labels, right stick/triggers; later-slice actions become rows automatically — after 43, 53B, 54 |
| [**46**](roadmap/slices/slice-46.md) | Not started | Save/load: 8 stable-ID binary slots, `seed_root` + build-gated checksum parity + N-step trace test (normalized reference), content fingerprint, `world_environment` + `pipeline_history` sections, load-time link-slot validation, `buildFingerprint()` from 64B, Slice 51 lane via `isDone` (inline fallback), Save/Load menu on 53B; settings excluded — after 49, 51, 53B, 54, 64B, 64E |
| [**49**](roadmap/slices/slice-49.md) | In progress (render→sim decoupling landed) | Session `SimulationSeed` + `SeedDomain` registry, `SimulationChecksum` oracle, `StepIndex = u64`, render→sim scope decoupling via `sim_view`/`simViewRegion` (live determinism defect), replay format (u16 action bits) + recorder/verifier, repeat/partition/seed determinism tests, `simulation-checksum` bench |
| [**50**](roadmap/slices/slice-50.md) | Not started | ThreadSystem hardening: release-safe forced-inline reentrancy + foreign-thread panic, claim-counter cache-line isolation, self-named workers, `-Dsanitize-thread` + TSan workflow, `thread-dispatch` bench |
| [**51**](roadmap/slices/slice-51.md) | Not started | Background lane (1 thread, 32 slots) with step-keyed handoff at `submit + k` and app-layer `isDone`; first consumer live replay capture; lane-start FP assertion (64A) — after 49, 50 |
| [**52**](roadmap/slices/slice-52.md) | Not started (umbrella) | Release build baseline, pinned dependencies, and CI: 52A → 52B → 52C, 52D after 52A |
| [**52A**](roadmap/slices/slice-52a.md) | Not started | Release build baseline: `-Dcpu-baseline` (ship = `x86_64_v2`/`apple_m1`, compat = `x86_64` SSE2, Debug native; `native`/`-Dcpu` never packaged; one shipped baseline per game; 52D SIMD codegen depends on it), Zig pin guard + `mise.toml` + upgrade policy, Windows LTO off under Zig 0.17, SDL 3.4.18 / ttf 3.2.2 / mixer 3.2.4 pinned on every OS (Windows prebuilt, Linux/macOS upstream-CMake source build, floor-checked `-Dsystem-sdl`), committed + `verify`-gated shader artifacts |
| [**52B**](roadmap/slices/slice-52b.md) | Not started (after 52A) | Per-OS `package` staging: Linux tarball dir (`$ORIGIN/lib`, `.desktop`, 256×256 icon), Windows icon/VERSIONINFO/GUI subsystem, macOS `.app` (Info.plist, icns, Frameworks, ad-hoc sign, package-time `dsymutil`) + AssetStore bundle fallback; Windows PDB to `zig-out/package-symbols/`; derived `-Dbundle-id` + App identity table (54 adds `-Dorg-name`); refuses Debug/system-SDL/native packages |
| [**52C**](roadmap/slices/slice-52c.md) | Not started (after 52A and 49; tag job after 52B) | GitHub Actions: verify matrix (Linux, Windows native + cross, macOS arm64), Slice 50 TSan job, Xvfb/lavapipe gpu-smoke, shader-artifact regeneration, tag packaging (sniper SDK container) + `symbols-windows`/`symbols-macos`, ReleaseSafe soak + bench artifacts (cron after a recorded duration); `frame-battle` release full-frame bench with `simulationChecksum()` serial/threaded + cross-baseline digest parity and `state_nan_values` |
| [**52D**](roadmap/slices/slice-52d.md) | Not started (after 52A) | SIMD layer codegen for the v2 release baseline: `inline` Mask4 helpers (removes a ~6-op x86 mask round-trip; upstream Zig issue filed), libcall-free `floorToI4` on SSE2, select-form float min/max/clamp (±0/NaN pinned across x86/arm64/comptime), exact `UniformDivisor` replacing the scalarized `divInt4`, deterministic polynomial sin/cos (`math.sinCos` delegates; closes 49's trig gap), `LIBM_BUILTIN` + `MASK_FN_NOT_INLINE` lint rules, `zig build simd-asm-check` in `verify`, `simd-*` bench groups |
| [**53A**](roadmap/slices/slice-53a.md) | Not started | Scalable GPU text: SDL_ttf GPU text engine behind a fixed-capacity `TextLabelSystem` (`u32`-generation ids, idle reclaim), glyph quads cached at realize in a fixed slab so `draw` makes no SDL_ttf/backend call, rasterized at the exact committed presentation scale (1/64 rounding for settle only), color as tint, CPU clip helper; `LoadingState` is the first consumer |
| [**53B**](roadmap/slices/slice-53b.md) | Not started | UI widget toolkit (retained enum-indexed `UiScreen`, anchor/stack layout, Action focus via `EventContext`, `theme.zon`, scroll clipping), migration of main/settings/pause/loading menus + confirm dialog, HUD primitives (progress/image/label) — after 53A |
| [**54**](roadmap/slices/slice-54.md) | Not started | Persistent settings: Engine-owned `SettingsStore`, versioned ZON at `SDL_GetPrefPath`, atomic write, defaults + backup on corrupt, apply before window/audio/renderer, live apply, upgrade freeze rule; settings + pause menu on 53B (toggle/choice widgets); `-Dorg-name` + derived `-Dbundle-id` default; later slices append fields by schema bump (Table T2) — after 53B |
| [**55**](roadmap/slices/slice-55.md) | Not started | Cognition decision coasting: idle agents decide every 8/32 steps, same-step wake from sensing, new scope-owned `ai_decide_gather` stage on Slice 49's `simViewRegion`; sensing never coasts; no new persistent columns — after 49 |
| [**56**](roadmap/slices/slice-56.md) | Not started | Health/damage/combat: `health` + `combat_stats`, generic threaded `ai_action_select` emitter (rotating deferral; deferral-age priority from Slice 68A), `ActionClaimSet`, simultaneous `combat_resolve` rolls on `seed.derive(.combat)`, deferred death, damage→affect watermark, `stepAfter`/`stepReached` on `StepIndex`, `attack_held_last` hashed — after 49 |
| [**56B**](roadmap/slices/slice-56b.md) | Not started | Projectiles and ranged combat: `projectile` component, `projectile_update` stage, collision-trigger hits (one per projectile per step) resolved in `combat_resolve`, fixed live/spawn/hit caps resized through `combat_max_hits_per_step` — after 56 |
| [**57**](roadmap/slices/slice-57.md) | Not started | Items/inventory/equipment: stable `ItemId` keys, pooled size-class slot runs (fixed arena cap, logical checksum), equipment modifiers, world items + single-winner overlap pickup, loot on `seed.derive(.loot)`, `inventory_update` stage + `TransferBatch`/`canAccept`/`canRemove`/`canRemoveCoins` transfer substrate — after 56 |
| [**57B**](roadmap/slices/slice-57b.md) | Not started | Inventory/equipment UI on 53B, `drop`/`unequip` kinds, `PendingPlayerActions`, `live_modal_overlay`, toasts, replay format v3 action records — after 53B, 57, 64C |
| [**58**](roadmap/slices/slice-58.md) | Not started | Seeded data-driven worldgen (`worldgen.json`: biomes, strata, veins, nodes, spawns, resource interest markers), integer noise, golden hashes, load-time only, `uniform_blocking` enum, `chunk_biomes`, dig yields on `seed.derive(.dig_yield)` — after 49, 57, 61 |
| [**59**](roadmap/slices/slice-59.md) | Not started | Game clock (`WorldSystem.clock.game_ms`), calendar/seasons/day phase, weather on `seed.derive(.environment)`, environment modifiers → perception range + AI speed, weather particles, `environment_transition` events, env → `SceneGrade` (visuals need 60) — after 49 |
| [**60**](roadmap/slices/slice-60.md) | Not started | Deterministic fixed-step camera rig (lag, dead zone, catch-up, clamp, integer zoom, presentation shake) whose zoom-1 `anchorRect()` feeds Slice 49's `sim_view`; scene-texture composite pass (`drawable`/`world_pixel`, grade); screen fade-in; zoom setting; pause does not resync the rig (64A) — after 49 (zoom setting on 54) |
| [**61**](roadmap/slices/slice-61.md) | Not started | Harvesting + resource nodes: `resource_node` (fixed 4096 cap), kind catalog, commit-rebuilt node index, `HarvestController` in `action_react` claims, step-scheduled regrowth, yields via 57 transfers (lands the `inventory_transfers` wiring), `need` drive + `AffectImpulse` substrate (commit-seam drain), `forage` + `.harvest` arm in `ai_action_select` — after 56, 57 |
| [**62**](roadmap/slices/slice-62.md) | Not started | NPC population: `SpawnAnchorStore` (256) on `WorldSystem`, `spawn_origin`, weighted/roster tables, `population_update` stage on `simViewRegion`, spawn band + despawn hysteresis, fixed caps (512), worldgen anchor placement — after 49, 58, 59, 63 |
| [**63**](roadmap/slices/slice-63.md) | Not started | Social + trade: `FactionRelations` runtime stance, 4-slot `social_ledger`, `merchant` profiles, integer pricing, buy/sell/give via 57 transfer batches (`canRemoveCoins` funds preflight), `social_react` stage, trade screen on 53B/57B overlay, replay v4 — after 53B, 57, 57B, 61 (combat rows need 56) |
| [**64**](roadmap/slices/slice-64.md) | Not started (umbrella) | Cross-machine determinism completion and replay tooling: 64A–64E; closes when 64A, 64B, 64C, 64E are archived (64D consumer-gated) |
| [**64A**](roadmap/slices/slice-64a.md) | Not started | Pause becomes simulation-invisible (presentation alpha hold); `math.min`/`max`/`clamp` select forms plus `RAW_MINMAX_GAME`/`STD_MATH_CLAMP_GAME`/`STD_MATH_TRANSCENDENTAL` lint; `math.floatKeyBits`; `core/fp_env.zig` assertion at step entry, worker start, and lane start — after 49, 52D |
| [**64B**](roadmap/slices/slice-64b.md) | Not started | Checksum v2: NaN-canonical, fixed sections + threaded 64 KiB dense blocks, comptime field classification, `"pipeline_history"`, `normalizeDerivedState` (pathfinding incl. 64E cursor, 65B deferred job, dirty marks, 71B.3 prewarm) as the load-parity reference — saves never normalize the live session; `buildFingerprint()` owner — after 49, 50, 64A; before 46 |
| [**64C**](roadmap/slices/slice-64c.md) | Not started | `zig build replay` headless runner (`HeadlessSession`), replay v2 80-byte header (`GameSessionDescriptor`, `build_fingerprint`), New Game random seed (`SessionSeedSource`, `-Dsession-seed`) — after 49, 51, 53B, 64B; before 57B |
| [**64D**](roadmap/slices/slice-64d.md) | Not started — gated on the first sim `atan2` consumer | Deterministic `simd.atan2Float4`, `math.atan2` delegates — after 52D |
| [**64E**](roadmap/slices/slice-64e.md) | Implemented 2026-10-05 (display-gated manual check open) | Live defect: runtime ramps routable the same step (8 fixed interior link slots per chunk, both-level dirtying, ≤ 8 links/step deferral, dig-time refusal of a ninth interior ramp per chunk), incremental == full parity, `nav-update-links` bench — no prerequisite |
| [**65**](roadmap/slices/slice-65.md) | Not started (umbrella) | Threading layout cleanup and background-lane heavy consumers: 65A, 65B, 65C |
| [**65A**](roadmap/slices/slice-65a.md) | Not started | One `thread_shared_record_alignment` (+ `assertThreadSharedRecord`, lint), padded `WorkerRecord`, per-OS lane priority (`src/platform/thread_priority.zig`; terminating fallback ladder), fixed pool `cpu_count − 1` — after 50, 51 |
| [**65B**](roadmap/slices/slice-65b.md) | Not started | Deferred nav rebuild on the lane (classification, frozen front + fence incl. 64E link cursor, back-graph patch over the processed link prefix, swap at `submit + 30` via the shared cache-reaction helper); saves never persist or disturb it (64B `normalize` abandons the job); Slice 51 frozen-borrow clause; `nav-update-deferred` bench — after 51, 65A, 64E |
| [**65C**](roadmap/slices/slice-65c.md) | Not started | Streaming worldgen via `WorldGenStream` lane batches, ≤ 512 commits per step (terminating ladder to 64), golden parity across lane speeds — after 58, 53B, 65B |
| [**66**](roadmap/slices/slice-66.md) | Not started (umbrella) | Distribution, signing, symbols, and store delivery: 66A ungated, 66B–66E gated |
| [**66A**](roadmap/slices/slice-66a.md) | Not started | Shipped-build crash triage: split symbols (ELF build-id + `.debug`, macOS `strip -S` after 52B's `dsymutil`, Windows PDBs), symbols archives on every GitHub Release, `tools/symbols.py`, `src/platform/crash_report*.zig` v1 reports in `<pref>/crashes/`, `crash-probe` + CI crash matrix, Linux runtime window icon — after 52B, 52C, 54 |
| [**66B**](roadmap/slices/slice-66b.md) | Not started — gated per target | macOS universal2 (with a cross-arch `zl-replay` CI check), aarch64-linux, aarch64-windows — after 66A, 64C |
| [**66C**](roadmap/slices/slice-66c.md) | Not started — gated on the first public non-Steam release | Authenticode (jsign + Azure Artifact Signing), Developer ID + notarization + `.dmg`, AppImage; Flatpak rejected — after 66A |
| [**66D**](roadmap/slices/slice-66d.md) | Not started — gated on a Steamworks app ID | SteamPipe upload automation (`platforms/steam/steam.json`, prerelease → `beta`, release → `staging`) — after 66A |
| [**66E**](roadmap/slices/slice-66e.md) | Not started — gated on the first RC tag | Authoritative perf runner (`tools/perf_gate.py`, self-hosted `zl-perf-ref`, committed baselines; thresholds never raised) — after 52C |
| [**67**](roadmap/slices/slice-67.md) | Not started (umbrella) | UI, input, and text completion: 67A, 67B, 67C, 67E (full localization is [Deferred By Owner](#deferred-by-owner)) |
| [**67A**](roadmap/slices/slice-67a.md) | Not started | Pointer input, HUD tooltips, pad menu hold-to-repeat, scancode bindings (settings v4, keymap-ready migration, freeze rule) — after 53B, 54, 44 |
| [**67B**](roadmap/slices/slice-67b.md) | Not started | Debug overlays on labels + `PreparedText` deletion, HUD event log, text-atlas telemetry + Western-corpus probe, UI navigation SFX — after 53A, 53B, 44 |
| [**67C**](roadmap/slices/slice-67c.md) | Not started | Offscreen world thumbnails, save header v2 (relative bump, header-only), named saves, `text_field` + IME — after 46, 60, 67A |
| [**67E**](roadmap/slices/slice-67e.md) | Not started | Localization roots: comptime `StringId` registry, compiled-in English table, `text(id)` + English-only `format`, existing UI strings migrated (byte-identical); no settings change — after 53B (merged order: after 67C); preferred before 56 |
| [**68A**](roadmap/slices/slice-68a.md) | Not started | Shared halo table (removes perception/AI main-thread O(halo) walks), deferral-age action-bus fairness on the fixed 64/48 bus (amends 56's rotation), normative 3×60 s ReleaseSafe re-baseline procedure + row schema, `halo-consumers` bench — after 55, 56 |
| [**68B**](roadmap/slices/slice-68b.md) | Not started | Knockback column + `knockback_apply` stage (after `movement_integrate`); retaliation memory slot from `Health.last_attacker` — after 55, 56, 56B |
| [**68C**](roadmap/slices/slice-68c.md) | Not started | Lossless carried death drop: admission-gated `pending_drops` FIFO (512, 32/step), kill deferral when not admissible, coin piles; ammo via 57's `TransferBatch.consume` — after 56B, 57, 61 |
| [**69**](roadmap/slices/slice-69.md) | Not started (umbrella) | World generation breadth and regional environment: 69A–69C ungated, 69D–69F gated |
| [**69A**](roadmap/slices/slice-69a.md) | Not started | Caves, structures/villages, autotile edge sets as 65C jobs; own-level AI goals; entrances respect nav link slots — after 58, 61, 62, 65C |
| [**69B**](roadmap/slices/slice-69b.md) | Not started | Regional weather (≤ 8 biome-mapped regions, `forPosition` lookup, player-region presentation); no new persistent state — after 58, 59 |
| [**69C**](roadmap/slices/slice-69c.md) | Not started | Rest/time skip (`Action.rest`, `SDL_SCANCODE_T`, replay bit 12, hashed `rest_held_last`) — after 59 |
| [**69D**](roadmap/slices/slice-69d.md) | Not started — gated on the first scripted weather consumer | Per-region weather override window (commit-seam requests, hashed and saved) — after 59 |
| [**69E**](roadmap/slices/slice-69e.md) | Not started — gated on weather cost > 0.25 ms | Per-zoom weather spawn rect from `CameraRig.presentationViewRect()`, area-scaled counts, zoom-out prefill — after 59, 60 |
| [**69F**](roadmap/slices/slice-69f.md) | Not started — gated on a world exceeding the bounded budgets | Paged regions (seamless streaming rejected); replay v5 header and flag bit1 `normalized_before_step`, save header `region_x/y` @122 — after 46, 51, 58, 64B, 65C |
| [**70**](roadmap/slices/slice-70.md) | Not started (umbrella) | Presentation polish and sprite vertex compaction: 70A independent, 70B after 60/54/44 |
| [**70A**](roadmap/slices/slice-70a.md) | Not started | Indexed `u16` quads + `UBYTE4_NORM` color, 192 → 80 B/sprite — independent |
| [**70B**](roadmap/slices/slice-70b.md) | Not started | Runtime scene resolution (settings v5), pad zoom/trigger defaults, fade-out hold, sharp-bilinear, zoom tween — after 60, 54, 44 |
| [**71**](roadmap/slices/slice-71.md) | Not started (umbrella) | AI behavior parity and navigation/collision static fast paths: 71A, 71B, 71C, 71D |
| [**71A**](roadmap/slices/slice-71a.md) | Not started | Patrol/follow/guard (`ai_post` tag → 25 of 32), `guard_alarm` stage, post goals carry the row level — after 55, 56, 61, 62, 63 |
| [**71B**](roadmap/slices/slice-71b.md) | In progress: fixed group-field threshold landed 2026-10-05 (rest of 71B.1 ungated; 71B.2 bench-gated; 71B.3 after 62 + 71A) | Fixed group-field threshold (live rule fix, first), `StaticColliderIndex` (cache class; steering level-gate fix), collision static split, group-field prewarm (normalized class) |
| [**71C**](roadmap/slices/slice-71c.md) | Not started | Cover-aware flee and ranged pursue (`cover` markers) — after 56B |
| [**71D**](roadmap/slices/slice-71d.md) | Not started | AI merchant selling (`trade` behavior + `.sell` arm; closes forage → sell) — after 63, 61, 71A |

**Recently settled (archive only):** 37, 48, 47, 45, 40, 39, 41, 32, 8, 18–25E, 26–31, 34, 36 (plus 0–7, 9–17).
**Residual non-slice notes:** optional render micro-opts (e.g. an O(n) linear
`mergeDrawList`) are measure-first notes in [Scaling Gaps](roadmap/scaling-gaps.md),
not a live slice body. (The 23A `expand2`→`world` merge is settled.)

**Bench policy:** 50k bench scales are throughput ceilings, not per-frame targets.
`frame-battle` (Slice 52C: 2048-mover production demo, full fixed step plus CPU
render-prep) is the release full-frame baseline; 66E adds the authoritative
self-hosted perf runner.

## Next Priority Tracks

Sequencing hints only — **does not replace slice Checklists**. When in doubt,
follow **Suggested Order** and the open items in the target slice file.

**Locomotion emergence is closed** (archive 26–32, 39, 41, 47, 48; frontier residual 33
visual only). Multi-source investigate (stimuli + world markers + memory) and
table-driven affect→behavior are in place. Open work grows *beside* that loop.

| Track | Slices | Notes |
| --- | --- | --- |
| **Primary — action/interaction** | archive **40** + **45** → **56** | Action-intent substrate + first domain controller (destructibles) landed. Combat (56) is the second action-intent consumer: `ai_action_select` is the single AI emitter, and `action_claims` enforces one consumer per intent in the fixed order trade → harvest → destructible, with `combat_resolve` taking unclaimed `.attack` intents. Slice 68A owns the bus fairness policy. |
| **Pipeline composer** | archive **48** | Thin-composer restoration landed. `world_gate` SIMD is a Scaling Gap. |
| **Feelings growth** | **42** (after 56, 61; caution needs 59) | The first new drive (`need`) lands in Slice 61; Slice 56's damage watermark supplies the signal for an optional `pain` drive; night/storm caution is a per-entity fear gain on Slice 59's environment. 42 keeps gains-as-data, coupling, and optional mood — no dead enum tags. |
| **World / render verticality** | archive **37** → **38** | Fixed submit cap, shader/host sync, and fixed byte budget landed; next is elevation semantics inside the existing submit cap, which also derives `level_sky_exposed` from elevation. Independent of AI. |
| **Perf** | **55** + **35** + **70A** → **68A** → **71B** + Scaling Gaps | 55 (after 49's `simViewRegion`) cuts how many rows reach AI decide and steering (idle coasting, scope-owned, sensing untouched); 35 cuts per-row SIMD math when the battle soak says math dominates. 70A is a render upload-bandwidth win (192 → 80 B/sprite; its `render-prep` bench must show `vertex_emit_ns` below baseline). 68A (after 55's soak) removes the remaining O(halo) main-thread AI/perception walks, makes the fixed bus fair, and owns the re-baseline procedure. 71B moves static colliders out of the collision sort and prewarms authored goals; 71B.1 also fixes the multi-level steering avoidance defect and the world-scaled group-field threshold. None reshapes arbitration contracts. |
| **Determinism & threading** | **64E** → **49** → **50** → **52A–52D** → **64A** → **55** → **51** → **65A** → **64B** → … → **64C** → **65B** (65C after 58; 64D consumer-gated) | **64E** first, as soon as possible: runtime ramps are inert for NPC pathing today. Seeded sessions and a checksum/replay oracle come next; 49 also fixes the render-window→sim-scope coupling, types steps as `StepIndex = u64`, and publishes the `SeedDomain` registry and `simViewRegion` that 55–63 consume. 64 extends 49's same-binary guarantee to every supported target from one source + toolchain: pause is simulation-invisible (64A), float min/max/keys/FP env are pinned (64A, including the lane thread), the checksum is NaN-canonical and covers pipeline history (64B), and `zig build replay` proves cross-machine identity (64C). 46 lands after 64B because it saves exactly 64B's hashed set and writes 64B's `buildFingerprint()`; a save never changes the continuing session (64B B5). 65A settles lane priority (per-OS helper; every fallback ladder ends in a recorded outcome) and keeps the pool at `cpu_count − 1`; 65B makes large nav patches and full relabels the first step-keyed simulation consumer of the lane (front frozen, swap at `submit + 30`); 65C streams load-time worldgen through the lane with a fixed per-step commit budget. |
| **Release & platform** | **52A** → **52B** → **52C** → **66A**; **52D** after 52A; **66B–66E** gated | Pinned CPU (`x86_64_v2` / `apple_m1`), toolchain, SDL, and shader baseline; per-OS packaging; CI + reproducible `frame-battle` release perf baseline; SIMD layer codegen for the `x86_64_v2` baseline (52D). 52A/52B are independent of the AI/render/input tracks; 52C needs Slice 49's checksum. Land 52A before games fork from the framework. 66A is the ungated release follow-up: it lands after Slice 54 (pref dir) and before any build leaves the team, because crash reports and symbols cannot be added retroactively to a shipped build. 66B–66E are fully specified but wait for their storefront, platform, or release-candidate triggers. |
| **Shipping UI / settings / input / persistence** | **53A** → **53B** → **54** → **44** → **46** → **67A** / **67B** → (60) → **67C** → **67E** (full localization: [Deferred By Owner](#deferred-by-owner)) | Ports VoidLight's shipping UI, settings, rebinding, and save features onto ZL contracts: tint-not-rerender GPU text, retained enum-indexed screens, Action-driven focus, Engine-owned versioned settings, stable-ID binary saves. Bindings (44) persist in Slice 54 settings, never in saves; saves (46) are binary, stable-ID, same-build checksum parity, on the Slice 51 lane. 67 finishes the track: mouse, pad repeat, physical-key bindings, one text pipeline (labels only), event log, UI SFX, save thumbnails and names, and localization roots (string IDs and the English table). No 67 work touches simulation state, replay, or the checksum. |
| **Gameplay domains** | **56** → **56B** → **57** → **57B** → **61** → **58** → **63** → **62** → **71A** → **71C** / **71D** → **69A**; **68B** → **68C** | Combat, ranged combat, items + UI, harvesting, worldgen, social/trade, and population ported onto `DataSystem` + `SimulationPipeline`. Every roll and placement keys off `seed.derive(.<domain>)` (worldgen off `WorldBuildConfig.seed`). Reuse `action_intents`, `ai_action_select`, `ActionClaimSet`, 57's transfer substrate, 61's `AffectImpulse` queue, and 57B's `PendingPlayerActions`; never add a second bus, emitter, claim set, impulse queue, or inventory-delta path. Population (62) is scoped by Slice 49's sim view, places anchors through 58's spec, and takes merchants from 63. 71A adds posts (patrol / follow / guard, help call), 71C cover-aware flee and ranged pursue, and 71D AI selling (closes forage → sell); worldgen breadth (69A) follows 62. 68B adds the knockback column + retaliation memory and 68C the carried death drop + ammo through the 57 transfer substrate. |
| **World presentation** | **60** → **59** → **69B** / **69C** → **70B** (69D–69F gated) | Camera rig + scene composite first; the rig's zoom-1 `anchorRect()` feeds Slice 49's `sim_view`. Environment sim (clock, weather, modifiers) can land beside it; its tint/haze/flash and weather visuals consume 60's `SceneGrade`. Weather becomes regional through 58's `chunk_biomes` with no new persistent state; rest (69C) moves only the calendar clock, inside its single writer. 70B closes 60's deferred presentation items (runtime scene resolution, pad zoom, fade-out, sharp-bilinear, zoom tween) and also needs 54 and 44. |

- **Slice 32 contract (standing rule):** `scoreBehaviors` / `selectSticky` /
  `resolveGoal` stay the expandable path. Emotion → behavior is **table-driven
  over `AiAffectDrive`**, not a permanent `if (fear) flee` tree. Goals stay
  per-agent and multi-source (not broadcast player-only). Utility + sticky
  select over exclusive FSMs. No test-only production API tags.
- **Component headroom:** 14 of 32 `Component` tags used (`enum(u5)` +
  `ComponentMask = u32`). Slice 45 added `destructible`. Slice 41 used
  `WorldSystem` interest markers, not a new tag. The VoidLight port track
  projects 10 more and Slice 71A one (`ai_post`): **25 of 32** (Table T5).
- **Interest kinds:** all reserved kinds are wired once 71C lands
  (investigate 41, resource 61, patrol 71A, cover 71C).
- Guard CPU paths with existing benches; keep SDL_GPU submit on the render
  thread. Reuse state-owned `SimulationPipeline`; persistent data in
  `DataSystem`; structural changes through `SimulationFrame`.

## Deferred By Owner

Product work the owner explicitly deferred. These are not slices and carry no
design: when an entry's trigger trips, design a decision-complete slice for it
and remove the entry. Only the owner adds entries here (Ground Rules, "No
backlog dumping").

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

### Historical order (settled foundation)

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
38, 43) are placed in the merged order below.

### Open slices — merged order

Dependency order for every open slice (VoidLight port track + 64–71). Each
line names its hard prerequisites; every prerequisite appears on an earlier
line or is landed. Position numbers are referenced by slice text ("merged-order
position N") and by the planned version numbers in Tables T1–T6.

- **Residual verification (any time):** [33](roadmap/slices/slice-33.md)
  (visual/`gpu-smoke`), [43](roadmap/slices/slice-43.md) (hardware).

1. **64E.** Incremental nav patch ramp/link parity (live defect; no
   prerequisite). Right after 48, before 49.
2. **49.** Session seed, determinism checksum/replay harness, `StepIndex = u64`,
   and render→sim scope decoupling (live defect; every gameplay slice derives
   its seed and scope band from it).
3. **50.** Thread system hardening (independent; before 51; rebases with 49 on
   `thread_system.zig` and with 52A on `build.zig`).
4. **52A → 52B → 52C → 52D.** Release build baseline: CPU baseline
   (`x86_64_v2` ship), Zig pin, unified pinned SDL, committed shader artifacts
   (land before the first game forks; rebases on Slice 50's `build.zig`
   edits); platform packaging (after 52A); CI and `frame-battle` (after 52A
   and 49 — digest is `simulationChecksum()`; tag job after 52B); SIMD layer
   codegen (after 52A's `-Dcpu-baseline`; land before 35 and before 52C
   records its first cross-baseline digests; if 49 lands first, re-baseline
   49's checksum goldens in 52D's sin/cos commit).
5. **64A.** Simulation-invisible pause, float min/max/clamp policy + lint,
   float key bits, FP environment assertion (after 49, 50, and 52D; rebases
   with 50 on `thread_system.zig` `workerMain`; 51 adds the lane-thread call).
6. **55.** Cognition think-interval coasting / decision LOD (after 49 for
   `simViewRegion`; 24/32/47 landed; composes with 35; before raising
   cognition population).
   - **35.** AI and steering hot-loop SIMD restructure (after 55 and 52D;
     measure at battle scale — do not reshape arbitration contracts).
7. **51.** Background job lane with deterministic step handoff + app-layer
   `isDone` (after 49, 50, and 64A). 46 becomes an app-layer consumer in its
   own slice.
8. **65A.** Thread-shared layout consolidation, `WorkerRecord` padding, lane OS
   priority, fixed pool rule (after 50 and 51; the alignment consolidation
   item may land any time as its own commit).
9. **64B.** Simulation checksum (tag live + 1), NaN-canonical, sectioned,
   threaded dense blocks, pipeline-history classification,
   `normalizeDerivedState`, `buildFingerprint()` (after 49, 50, 64A; before
   46, which saves exactly the hashed set and writes `buildFingerprint()`).
10. **53A → 53B → 54.** Scalable GPU text labels (render layer); UI widget
    toolkit, menu migration, HUD primitives (after 53A); persistent settings
    (after 53B).
11. **66A.** Shipped-build crash triage: split symbols, symbol store, crash
    reports, Linux runtime window icon (after 52B, 52C, 54; before the first
    build leaves the developer's machines).
12. **44.** Input rebinding UI + extended gamepad controls (after 43 residual,
    53B, 54; bindings persist in 54 settings).
13. **64C.** Headless replay runner, session descriptor header (replay v2), New
    Game random seed (after 49, 51, 53B, 64B; before 57B, which takes replay
    v3).
14. **65B.** Deferred nav rebuild on the background lane (after 51, 65A, and
    64E; uses 49's checksum stepper and 64B's normalize; no longer gates 46,
    which follows it and adds 65B's mid-job trace test; before any other
    in-game CPU-heavy lane consumer).
15. **46.** Save/load persistence (after 49, 51, 53B, 54, 64B, 64E; save v1;
    every later persistent-state slice adds its save section with its
    checksum classification).
16. **70A.** Sprite vertex compaction: indexed `u16` quads + `UBYTE4_NORM`
    color, 192 → 80 B/sprite (independent; before 60 so 60's
    `drawGroupRange` inherits the index bind — either order works).
17. **60.** Camera rig and scene composite pass (after 49; supplies 49's
    `sim_view` from the rig; lands the neutral-bypass composite path; zoom
    setting on 54; after 52A regenerate committed shader artifacts).
18. **67A.** Pointer input, menu hold-to-repeat, scancode bindings with
    keymap-ready migration (settings v4) (after 53B, 54, 44).
19. **67B.** Debug text migration onto labels + `PreparedText` deletion, HUD
    event log, text atlas telemetry, UI navigation SFX (after 53A, 53B, 44;
    independent of 67A).
20. **67C.** Save thumbnails (world-domain replay), header-only save format
    bump (v2) + named saves, `text_field` + IME (after 46, 60, 67A).
21. **67E.** Localization roots: `StringId` registry, compiled-in English
    table, `text(id)` + English-only `format`, migration of every existing
    UI string; no settings version (hard prerequisite 53B; placed after
    67A–67C so one change migrates their literals, and may land earlier;
    preferred before 56. If any of 56–63 land first, 67E also migrates
    their UI and event-log strings in the same change). Full localization
    is not in this order: it is [Deferred By Owner](#deferred-by-owner).
22. **70B.** Presentation polish: runtime scene resolution, pad zoom defaults +
    trigger layout, fade-out hold, sharp-bilinear `world_pixel`, drawable zoom
    tween (after 60, 54, 44; settings v5; regenerate composite artifacts per
    52A).
23. **56.** Health, damage, and combat; generic `ai_action_select` stage and
    `ActionClaimSet` (after 49; save v3).
24. **56B.** Projectiles and ranged combat (after 56).
25. **57.** Items, inventory, equipment, and the inventory-transfer substrate
    (after 56).
26. **57B.** Inventory/equipment UI, `PendingPlayerActions`,
    `live_modal_overlay`, toasts, replay format v3 action records (after 53B,
    57, and 64C).
27. **59.** Game time, day/night, seasons, weather (after 49; grade/weather
    visuals after 60).
28. **69C.** Time skip / rest (after 59; independent of 58; Slice 62's time
    filter consumes the jump when present).
    - **38.** Elevation above the surface (after 37, landed; derives
      `level_sky_exposed` from elevation and changes `addLevel`'s implicit
      elevation to one tier below the lowest, so it follows 59; Slice 58
      strata depth rebinds when it lands).
29. **61.** Harvesting, resource nodes, `need` drive, `AffectImpulse`
    substrate (after 56 and 57).
30. **58.** Seeded procedural worldgen incl. resource-node placement, resource
    interest markers, and chunk biomes (after 49, 57, 61 — it calls 61's
    `resourceNodeTemplate`).
31. **65C.** Streaming worldgen on the background lane (after 58, 53B, and
    65B's frozen-borrow clause).
32. **69B.** Regional (biome) weather (after 58 and 59; grade and weather
    visuals after 60; migrates Slice 42's caution call to `forPosition` if 42
    landed first).
33. **63.** Social relationships and trade (after 53B, 57, 57B, 61; combat rows
    need 56; replay v4).
34. **62.** NPC population, spawn anchors/tables, worldgen anchor placement
    (after 49, 58, 59, 63).
35. **71A.** Patrol / follow / guard posts (after 55, 56, 61, 62, 63, and the
    68A/68B composition rules if those landed).
36. **71B.** 71B.1 any time; its fixed-threshold item first and
    unconditionally (it may land before every other slice in this list).
    71B.2 when its bench gate trips. 71B.3 after 62 and 71A.
37. **71C.** Cover-aware flee and ranged pursue (after 56B; independent of
    71A/71B/71D).
38. **71D.** AI merchant selling (after 63, 61, 71A).
39. **69A.** Worldgen breadth: caves, structures and villages, autotile edge
    sets (after 58, 61, 62, and 65C; after 71A when both are planned, which
    generalizes 71A's own-level post goals).
40. **42.** Affect expansion: gains as data, coupling, optional mood (after 56
    and 61). The first new drive (`need`) lands in 61. An optional `pain`
    drive reads Slice 56's `damage_taken_total` watermark. Environment
    caution (night and storm → per-entity `gain_fear_caution`) needs 59.
41. **68A.** Battle-scale hardening: shared halo table, action-bus
    deferral-age fairness, control re-baseline procedure (after 55 and 56; its
    §3 procedure text is used by 56/56B/57/58/61/62 soaks even before it
    lands).
42. **68B.** Knockback impulses and retaliation memory (after 55, 56, 56B).
43. **68C.** Carried-inventory death drop and ranged ammo (after 56B, 57, 61).
44. **Gated** (each lands when its trigger trips; see its Status line):
    - **64D:** the first simulation `atan2` consumer (after 52D).
    - **66B:** per target (after 66A, 64C, and 52A's Windows LTO amendment).
    - **66C:** the first non-prerelease public release outside Steam (after
      66A).
    - **66D:** a Steamworks app ID (after 66A).
    - **66E:** the first release-candidate tag (after 52C).
    - **69D:** the first scripted-weather consumer (after 59).
    - **69E:** weather cost > 0.25 ms (after 59, 60).
    - **69F:** a world exceeding the bounded budgets (after 46, 51, 58, 64B,
      65C, and 69A if structures are used).

Cycle check: every edge points to an earlier line. The added edges beyond the
VoidLight port order are 64C → 57B (replay numbering), 64B → 46
(`buildFingerprint`), and 65C → 69A/69F; none closes a loop.

## Roadmap Files

- Open slices: [`roadmap/slices/`](roadmap/slices/) (one file per slice or
  sub-slice; header line names dependencies and track).
- Settled slices: [`roadmap/archive/`](roadmap/archive/) — index:
  [framework-implementation-slices-archive.md](framework-implementation-slices-archive.md).
- Tracks: [VoidLight port](roadmap/tracks/voidlight-port.md) (shared contracts,
  Tables T1–T6), [Emergent AI](roadmap/tracks/emergent-ai.md),
  [Long-term gameplay direction](roadmap/tracks/gameplay-direction.md).
- Measured pressure points: [Scaling Gaps](roadmap/scaling-gaps.md).
