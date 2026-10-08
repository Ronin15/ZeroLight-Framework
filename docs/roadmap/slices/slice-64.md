## Slice 64: Cross-Machine Determinism Completion And Replay Tooling

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 51](slice-51.md), [Slice 52D](slice-52d.md), [Slice 53B](slice-53b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for seven verifiable chunks. Each sub-slice
has its own Status, Checklist, and Acceptance checks; the umbrella closes when
64A, 64B, 64C, 64E, 64F, and 64G are archived (64D is consumer-gated and may
stay open).

| Sub-slice | Status | Hard prerequisites | Delivers |
| --- | --- | --- | --- |
| **64A** | Not started | 49, 52D | Pause/resume becomes simulation-invisible (presentation alpha hold replaces the `previous_x/previous_y` resync); sim-wide float `min`/`max`/`clamp` policy through `math.min`/`math.max`/`math.clamp` with three `idiom-lint` rules; `math.floatKeyBits` for float→key bits; `src/core/fp_env.zig` MXCSR/FPCR debug assertion at step entry, worker start, and lane-thread start |
| **64B** | Not started | 49, 50, 64A; land before 46 | Checksum format tag = live + 1 (`"zl-sim-checksum-v2"` in the merged order): NaN-canonical float folding with a NaN counter (`simd.nanMaskFloat4`), section digests with an ordered combine, threaded dense-tile block hashing (fixed 256-slot rounds), pipeline-history coverage with a comptime completeness classification over every `SimulationPipeline` field, the `normalizeDerivedState` API that backs the `normalized` class (including 64E's cursor, 65B's deferred job, the dirty marks, and 71B.3's prewarm fields), and the single owner of `buildFingerprint()` + the `app_version` option |
| **64C** | Not started | 49, 51, 53B, 64B; before 57B | `zig build replay -- <file>` headless runner on an app-layer `HeadlessSession` (no Engine mode), session descriptor + `build_fingerprint` in the replay header (`replay_format_version` = live + 1, v2 in the merged order), `GameSessionDescriptor`, New Game flow with a random root chosen once on the main thread (`SessionSeedSource`, `-Dsession-seed`) |
| **64D** | Not started — gated on the first simulation consumer of `atan2` | 52D (+ the gate) | Deterministic polynomial `simd.atan2Float4`, `math.atan2` delegating to lane 0, golden bits, `simd-asm-check` probe, `simd-atan2` bench |
| **64E** | Landed; manual ramp check open | — | Runtime ramp/stair links are routable the same step: new links dirty both endpoints on both levels via a link cursor (≤ 8 links/step, deterministic deferral), incremental == full-rebuild parity, `nav-update-links` bench; no ramp refusal |
| **64F** | Implemented; superseded by 64G | 64E | Per-level nav edge windows, one repack per level on overflow |
| **64G** | Not started | 64F; before 65B, 46 | [Chunk-owned terrain and nav](slice-64g.md): per-chunk storage, staged all-or-nothing apply, per-chunk GPU pages, simulation-derived residency |

**What 64 adds to Slice 49's Determinism Contract.** After 52D and 64A–64C,
the guarantee "same seed + same initial state + same per-step input →
bit-identical persistent state after every step" extends from one executable
to **every supported target built from the same source and toolchain**
(x86_64 `compat`/`ship`/`v3`, Linux/Windows, and `apple_m1` macOS):

- trig: 52D polynomial `sinCos`; `atan2` is pure-Zig scalar
  (`lib/std/math/atan2.zig` is a musl port using only IEEE basic ops; no
  `@mulAdd` on the scalar f32 path, `lib/std/math/atan.zig` scalar
  `atanBinary32`), and 64D replaces it when a vector consumer appears;
- no other transcendental reaches simulation code (64A `STD_MATH_TRANSCENDENTAL`
  lint plus 52D `LIBM_BUILTIN`);
- float `min`/`max`/`clamp` in `src/game/` are compare/select forms only (64A);
- float bits feed keys only through `math.floatKeyBits` (64A);
- the FP environment is asserted default (64A);
- NaN payloads never reach the checksum (64B).

The proof is a replay recorded on x86_64 Linux that verifies `matched` on
Apple Silicon with `zig build replay` (64C acceptance).

**Backlog items this umbrella closes** (source lines in the pre-promotion
roadmap): headless replay runner (339) → 64C; threaded per-dense-layer
checksum hashing (344) → 64B; render interpolation history vs pre-step pose
(349) → 64A; controller state in the checksum (373) → 64B; random per-session
seed and New Game flow (379) → 64C; scalar float `@min`/`@max` (384) → 64A;
NaN bit patterns (391) → 64B; FP environment (394) → 64A; upstream Zig issue
(397) → Slice 52D checklist addition; vector `atan2` (401) → 64D; Slice 46
clock and `level_sky_exposed` round trip (492) → Slice 46 checklist addition.

### Cross-slice additions (folded into the owning slices)

Slice 64's "Checklist additions to existing slices" (a)–(m) live in the owning
slice files, marked "(added by Slice 64)". Sub-slice text that cites
"Checklist additions (x)" refers to this table.

| Addition | Owner | What landed there |
| --- | --- | --- |
| (a) | [52D](slice-52d.md) | File the upstream Zig issue (with the `maskprobe.zig` repro); `MASK_FN_NOT_INLINE` stays; Out-of-scope pointers to 64A/64B/64D |
| (b) | [46](slice-46.md) | `"world_environment"` section (`game_ms`, `level_sky_exposed`) and its three tests |
| (c) | [46](slice-46.md) | `"pipeline_history"`, normalized saved image (live session untouched), save-invisibility and runtime-ramp trace tests, replay-across-save test, load-time link-slot validation, rebuild-time acceptance, `buildFingerprint()` |
| (d) | [49](slice-49.md), [57B](slice-57b.md), [63](slice-63.md) | Relative `replay_format_version` numbering (64C v2, 57B v3, 63 v4) |
| (e) | [60](slice-60.md) | Pause does not resync the camera rig; `anchorRect()` invariance test |
| (f) | [56](slice-56.md), [57](slice-57.md) | `attack_held_last` and the use-item latch hashed and saved |
| (g) | [52C](slice-52c.md) | `state_nan_values` beside `state_digest` in `frame-battle` / soak |
| (h) | [49](slice-49.md) | Out-of-scope and Scaling Gap pointers retargeted to 52D/64A–64D |
| (i) | [51](slice-51.md) | Capture header via the shared encoder; `pause_boundary_pending` rename |
| (j) | [65B](slice-65b.md) | Back-graph patch inherits 64E's fixed link slots and cursor |
| (k) | [51](slice-51.md) | `fp_env.assertDefault("background lane")` at lane-thread start |
| (l) | [69A](slice-69a.md) | Cave entrances skip cells without free nav link slots |
| (m) | [69F](slice-69f.md) | Replay `flags` bit1 `normalized_before_step` and `replayNormalize()` (Table T1) |
