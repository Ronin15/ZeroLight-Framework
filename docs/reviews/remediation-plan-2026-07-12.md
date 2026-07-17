# Full Remediation Plan — Project-Wide Review Findings

Date: 2026-07-12  
Branch: `ai_update2`  
Source: multi-agent review + adversarial verification  
Gate: **hold `zig build check` / `zig build verify` until all waves complete**

## Goals

Remediate every confirmed finding (H1–H6, M1–M22, L1–L10) with production fixes +
tests grounded in `docs/coding-standards.md` and architecture docs. Prefer
existing patterns (Affect dual asserts, sparse reserve-then-commit, vertex
GPU-idle growth, `releaseGamepadInput`).

## Workstreams (file ownership — no cross-stream edits)

| ID | Owner files | Findings |
|----|-------------|----------|
| **W1 App input** | `src/app/input.zig`, `pause_controller.zig`, `engine.zig`, `input_router.zig`, `gamepad.zig`, `thread_system.zig` | H4, M6, L7 |
| **W2 World** | `src/game/world_system.zig` | H1, H2, M16 |
| **W3 Dig + pipeline** | `src/game/dig_controller.zig`, `simulation_pipeline.zig`, `simulation.zig` (events only if needed), docs simulation | H3, M1, M2, M3, M7, L4 |
| **W4 Render/GPU** | `src/render/sprite_batch.zig`, `renderer.zig`, `text.zig`, `fps_counter.zig`, `platform/gpu_smoke_impl.zig`, `game/render_prep.zig`, `ai_debug_overlay.zig` | H5, H6, M11, M21, M22 (render parts), L6, L10 |
| **W5 Collision** | `src/game/systems/collision.zig`, `collision_response.zig`, `game_demo_state.zig` (capacity comments only) | M4, M5, M9, M19, M20, L3 |
| **W6 Hotpath standards** | pathfinding/*, ai, perception, affect (ref only), steering, movement, particle, spatial_index, ai_memory | M8, M12, M13 (systems), M14, M15, L1, L2 |
| **W7 Data + audio + states** | `data_system/*`, `audio.zig`, `state.zig`, `loading_state.zig`, `settings_menu_state.zig`, `pause_state.zig` | M10, M13 (stores/audio/state), M17, M18, L5, L8, L9 |
| **W8 Final polish** | docs touch-ups, leftover Lows, any merge conflict residue | L remaining |

## Dependency order

```
W1 ─┐
W2 ─┼─ parallel (no shared files)
W4 ─┤
W5 ─┘
     └─► W3 (after W2 if dig uses world API changes; can parallel if only dig/pipeline)
     └─► W6 (after W5 collision patterns if copying assert style)
     └─► W7 (independent; can parallel with W6)
     └─► W8 + zig build fmt + zig build verify
```

## Per-finding acceptance (summary)

### High
- **H1** `writeDenseTileCell`: ensure edit capacity before CPU mutate; FailingAllocator OOM leaves tiles+queue unchanged.
- **H2** `addDenseLayer`: validate band headroom without commit; reserve both; then band+layer; rollback-safe on OOM.
- **H3** `player_last_cell` only after successful/no-op traversal.
- **H4** `releaseHeldGameplay()` (move+dig+stick); pause enter/exit + gameplay-context loss; prefer accept key/button **up** for held gameplay even under blocked context.
- **H5** Drop blanket `errdefer deinit` in `reserveStorage`; non-destructive grow fail.
- **H6** `WaitForGPUIdle` (or create-new-then-idle-then-release) before tile-edit transfer free; mirror vertex growth.

### Medium (contract)
- **M1** Reserve/preflight event before world mutate (or rollback) in dig/carve.
- **M2** Declare `world_tiles` reads on gate/plane/perception contracts; fix causal comments.
- **M3** Re-run tile gate after collision response (or move stage); causal test: push into solid → walkable end pose.
- **M4** Same-level gate on collision proxies/pairs; two-level XY-overlap → zero contacts.
- **M5** Honest capacity docs; fix demo “graceful drop” lie; prefer conservative warm or document grow.
- **M6** Filter gamepad events by `activeId()`.
- **M7** Batch plane-traversal tile events + one `finishWrite`.
- **M8** Non-assert cast safety in `applyBlockedDelta`.
- **M9** Tuner samples only final successful broadphase batch.
- **M10** Loading `.failed` phase; no process abort on build error; latch after full frame success.
- **M11** Idle before texture destroy/replace (and document/safe tile buffer release).
- **M12–M14** Dual worker asserts; multi-worker FailingAllocator; perception multi-kind+cap parity.
- **M15** Span-based world_obstacle dirty path.
- **M16** Shrink oversized world fixtures (non-scale tests).
- **M17** Un-pub or gate `commitStructuralCommands`.
- **M18–M22** Settings quit test; scope collision test; SIMD parity; text cache bound/evict; static/merge alloc proofs.

### Low
Implement when touching the file; do not block High waves.

## Validation (end only)

```sh
zig build fmt
zig build verify   # check + test + shaders + atlas + idiom-lint
```

Targeted benches only if a hot-path contract changed and a case already exists:
`zig build bench -- --group <name>`.

## Out of scope

- New features beyond finding remediations
- Roadmap slices unrelated to findings
- Generated `zig-out/` / `.zig-cache/`

## Execution status (2026-07-12)

| Stream | Status |
|--------|--------|
| W1 App input | Done (H4, M6, L7) |
| W2 World | Done (H1, H2, M16) |
| W3 Dig + pipeline | Done (H3, M1–M3, M7, L4) |
| W4 Render/GPU | Done (H5, H6, M11, M21, M22, L6, L10 + sprite prep asserts) |
| W5 Collision | Done (M4, M5, M9, M19, M20, L3 + dual asserts) |
| W6 Hotpath standards | Done (M8, M12–M15, L1, L2) |
| W7 Data/audio/states | Done (M10, M13, M17, M18, L5, L9) |
| L8 BenchmarkGroup rename | **Skipped** (high blast radius across all benches; naming-only) |
| End gate | `zig build fmt` + `zig build verify` — **990/990 tests passed** |

Post-merge compile fixes: `state.zig` field comma, `ai.zig` hex literal, `fps_counter` const, pipeline discard.
Test fixture fixes: loading log level, fall velocity, perception multi-range pad, steering intent batch + reserve, merge coalesce count.

## Review residual fix pass (same day)

Closed residual findings **R1–R17** + lows via 6 parallel zig-specialists:

| Finding | Fix |
|---------|-----|
| R1/R2/R4 | Player `world_level` pre-attach; pre-attach before carve; link capacity before ramp tile; stimulus preflight |
| R3 | `shouldDeliverEvent` before `handleEvent` in Engine |
| R5/R6/R17 | Scratch warm + FA proof; single-range M7 assert; 8×8 multi-level fixtures |
| R7/R16/L3/L4 | Pre-acquire tile-edit transfer; FPS prepareGlyphs tests; bulk idle; mid-list reserve fail |
| R8/R15/L5/L8 | Failed load → main menu; render latch tests; pause East; architecture stage order |
| R9–R11 | SIMD same-level test; spatial/collision `!ran_inline` FA/split honesty |
| R12–R14/L6/L7 | Multi-chunk M15; applyBlockedDelta test; nav_dirty_levels assumeCapacity + FA; rect clamp |
| L1/L2 | createTracks FA; ai_memory/perception FA non-inline on proof step |

End gate after residual pass: **`zig build verify` 1012/1012 tests, 29/29 steps.**
