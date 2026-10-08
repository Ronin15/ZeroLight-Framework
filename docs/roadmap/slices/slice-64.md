## Slice 64: Cross-Machine Determinism Completion And Replay Tooling

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 50](slice-50.md), [Slice 51](slice-51.md), [Slice 52D](slice-52d.md), [Slice 53B](slice-53b.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella).** Closes when 64A, 64B, 64C, 64F, and 64G
are archived (64E is archived; 64D is consumer-gated and may stay open).

Goal: after 52D and 64A–64C, the determinism guarantee (same seed, initial
state, and per-step input give bit-identical persistent state after every
step, for every world instance) extends from one executable to every
supported target built from the same source and toolchain: x86_64
`compat`/`ship`/`v3` on Linux and Windows, and `apple_m1` macOS. The proof is
a replay recorded on x86_64 Linux that verifies `matched` on Apple Silicon
with `zig build replay` (64C acceptance).

| Sub-slice | Status | Prerequisites | Delivers |
| --- | --- | --- | --- |
| [64A](slice-64a.md) | Not started | 49, 52D | Pause is simulation-invisible; one pinned float min/max/clamp semantics in `src/game/` with lint; canonical float key bits; FP-environment assertion at step, worker, and lane entry |
| [64B](slice-64b.md) | Not started | 49, 50, 64A, 64G; before 46 | Checksum v2: NaN-canonical and counted, sectioned, terrain hashed per chunk on the thread system, comptime classification of all pipeline history, `normalizeDerivedState`, `buildFingerprint()` |
| [64C](slice-64c.md) | Not started | 49, 51, 53B, 64B; before 57B | Headless `zig build replay` runner, session descriptor and build fingerprint in the replay header, New Game random seed root |
| [64D](slice-64d.md) | Gated on the first simulation `atan2` consumer | 52D | Deterministic vector `atan2` |
| [64E](../archive/slice-64e.md) | Landed (archived) | — | Runtime ramps routable the same step, incremental == full rebuild, no ramp refusal; its storage is replaced by 64G |
| [64F](slice-64f.md) | Implemented; superseded by 64G | 64E | Per-level nav edge windows (replaced by 64G) |
| [64G](slice-64g.md) | Not started | 64F; before 65B, 46 | Chunk-owned terrain and nav |

What makes the guarantee hold across targets:

- trig: 52D's polynomial `sinCos`; `atan2` is pure-Zig scalar IEEE until 64D
  replaces it for a vector consumer;
- no other transcendental reaches simulation code (64A and 52D lint rules);
- float `min`/`max`/`clamp` in `src/game/` are compare/select forms (64A);
- float bits feed keys only through one canonical helper (64A);
- the FP environment is asserted default (64A);
- NaN payloads never reach the checksum (64B).

### Cross-slice additions (folded into the owning slices)

Slice 64's additions (a)–(m) live in the owning slice files, marked "(added
by Slice 64)".

| Addition | Owner | Outcome there |
| --- | --- | --- |
| (a) | [52D](slice-52d.md) | Upstream Zig issue filed; inline Mask4 rule stays after a fix |
| (b) | [46](slice-46.md) | Game clock and sky exposure saved and round-tripped |
| (c) | [46](slice-46.md) | 64B pipeline history saved; saved image normalized, live session untouched; save and replay invisibility tests; runtime-ramp trace test; `buildFingerprint()` in the header |
| (d) | [49](slice-49.md), [57B](slice-57b.md), [63](slice-63.md) | Relative `replay_format_version` numbering (Table T1) |
| (e) | [60](slice-60.md) | Pause never resyncs the camera rig |
| (f) | [56](slice-56.md), [57](slice-57.md) | Attack and use-item latches hashed and saved |
| (g) | [52C](slice-52c.md) | `state_nan_values` beside `state_digest` |
| (h) | [49](slice-49.md) | Out-of-scope pointers to 52D and 64A–64D |
| (i) | [51](slice-51.md) | Capture header through the shared encoder; pause-boundary rename |
| (j) | [65B](slice-65b.md) | Superseded by 64G: 64E's link slots and cursor no longer exist; 65B states its needs against chunk-owned nav |
| (k) | [51](slice-51.md) | FP-environment assertion at lane-thread start |
| (l) | [69A](slice-69a.md) | Superseded by 64G: no nav link slot limits remain; cave entrances are never refused for capacity (`.claude/rules/budgets-capacities.md`) |
| (m) | [69F](slice-69f.md) | Superseded: 69F keeps every chunk simulating in any storage form and never normalizes a live session, so replay flag bit1 stays reserved (Table T1) |
