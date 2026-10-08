## Slice 70A: Sprite Vertex Compaction (Indexed Quads, Packed Color)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** No prerequisite. Whichever of 60 and 70A lands
second binds the index buffer in 60's per-pass draw loop; 53A's glyph quads
inherit the compaction; no shader artifact changes (52A).

Goal: sprite and tilemap quads upload 80 B per sprite instead of 192 B (4
vertices of position, uv, and 8-bit color, drawn through one fixed shared
index buffer). Rasterized triangles are bit-identical to today's; colors are
identical for tints on the 1/255 grid and within 1 LSB otherwise. No
game-facing renderer API is renamed.

### Current foundation

- `src/render/sprite_batch.zig`: SoA vertex columns `Position = [2]f32`,
  `Uv = [2]f32`, `VertexColor = [4]f32` in plain `std.ArrayList`s with no
  64-byte base guarantee; `writeSpriteQuad` expands four corners to six
  vertices and splats the tint into six color slots; every vertex sizing is
  `commands * 6`; threaded emit uses 4-command ranges; an AoS oracle test and
  serial/threaded and `FailingAllocator` proofs cover it.
- `src/render/renderer.zig`: three vertex streams plus transfer buffers,
  `SDL_DrawGPUPrimitives` per draw group, `cycle=true` per stream,
  `coalesceDrawList` in vertex units; static tilemap spans through
  `appendStaticTilemapSpan`.
- `gpu/pipeline_common.zig`: one SoA layout (FLOAT2/FLOAT2/FLOAT4) shared by
  the sprite and tilemap pipelines; neither shader uses `gl_VertexIndex`.
- Game-side quad builders that see vertex columns: `world_system.zig`,
  `render_prep.zig` (`staticGeometryCapacity`), `gpu_smoke_impl.zig`.
- `text.zig` has a private float → byte color conversion.
- SDL 3.4 provides `UBYTE4_NORM`, 16-bit index buffers, and indexed draws with
  a vertex offset.
- Benches: `render-prep` (phase timers for submit, snapshot, vertex emit,
  draw group) and `render-game-prep` groups.

### Architecture notes

- The index buffer is a fixed render resource built once at init; it never
  grows with sprite count, capacity, or world size, and larger draw groups
  split into consecutive chunked draws (`.claude/rules/render.md`,
  `.claude/rules/budgets-capacities.md`).
- Triangle-list topology only; a future strip material must not reuse the
  shared buffer (documented in the material steps).
- Color packs once per sprite through a new `core` conversion that
  `text.zig` reuses (`.claude/rules/memory-performance.md` § SIMD and core
  math).
- Three SoA streams stay (slot contract and worker seams); threaded emit
  columns get 64-byte bases so every 4-command seam is a cache line
  (`.claude/rules/threading.md`).
- Draw groups stay in vertex units; batch reservation keeps its live-count
  reserve with geometric growth at the pre-reserve seam.
- No GLSL change; a guard test pins the vertex attribute declarations.
- VoidLight: port the 20 B vertex, FLOAT2/FLOAT2/UBYTE4_NORM attributes, and
  the prebuilt index buffer; do not port its sprite-capped 32-bit buffer,
  interleaved stream, mapped-pool recording, or per-texture batches.

### Checklist

- [ ] `core` color-to-byte conversion with tests; `text.zig` delegates.
- [ ] Sprite batch: packed color type, 4-vertex quads, index pattern and
      chunked draw iterator, 64-byte column bases, every `* 6` sizing
      switched; oracle, index, iterator, alignment, parity, and allocation
      tests.
- [ ] Fixed quad index buffer created at init and released at deinit.
- [ ] Pipeline layout slot 2 as packed color.
- [ ] Renderer: per-pass index bind, chunked indexed draws, static span
      validation (partial quad rejected).
- [ ] GLSL attribute guard test.
- [ ] Game, platform, and bench call sites on 4 vertices per quad.
- [ ] `gpu-smoke` frame exercising a second index chunk.
- [ ] Docs: `docs/rendering-assets-shaders.md` (stream formats, index buffer,
      cycle row, material steps), `docs/architecture.md` (sprite batch).

### Acceptance checks

- [ ] Expanding the four written corners reproduces the six-vertex oracle
      bit-exactly; the last index chunk's indices are pinned by test.
- [ ] Bench: `render-prep` vertex emit drops at two sample sizes for serial
      and threaded cases, other phases within run-to-run spread;
      `render-game-prep` recorded before and after.
- [ ] `zig build gpu-smoke` passes with validation clean, including the
      two-chunk frame.
- [ ] Manual: world sprites, tilemap, particles, debug viz, and menus render
      unchanged against a pre-slice screenshot.
- [ ] Every `FailingAllocator` proof passes; `zig build verify` passes.
