## Slice 70A: Sprite Vertex Compaction (Indexed Quads, Packed Color)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** No hard prerequisite, and independent of every
gameplay track. It coordinates with three slices:

- **Slice 60's two-pass `endFrame`.** Whichever of 60 and 70A lands second
  binds the quad index buffer at the top of `drawGroupRange`.
- **Slice 52A.** No GLSL changes, so the committed sprite and tilemap
  artifacts and `shader_sources.sha256` stay byte-identical.
- **Slice 53A.** Glyph quads go through `submitOrderedSprite` and inherit the
  compaction.

Goal:

- Dynamic and static sprite quads upload 80 B per sprite instead of 192 B
  (−58%).
- Indexed draws come from a fixed index buffer that is independent of scene
  size.
- Rasterized triangles are bit-identical to today's. Colors are identical for
  tints on the 1/255 grid, and within 1 LSB per channel otherwise.
- No game-facing API is renamed. Game code changes only its corner-array
  length and the `VertexColor` element type.

### Current foundation

- **`src/render/sprite_batch.zig`:**
  - **SoA vertex types and views (`:126-147`):** `Position = [2]f32`,
    `Uv = [2]f32`, `VertexColor = [4]f32` (16 B), plus `VertexColumns` and
    `VertexColumnsConst`. The columns are plain `std.ArrayList`s
    (`SpriteBatch.positions/uvs/colors`, `:267-269`) with no base-alignment
    guarantee.
  - **`writeSpriteQuad` (`:627-688`):** computes four corners with
    `core/simd` (lane = corner) and expands them to six vertices through
    `indices = {0,1,2,1,3,2}` (`:660`). The tint is splatted as `[4]f32` into
    six color slots (`:682`). Dynamic prep and `writeWorldSpriteQuad`
    (`:616-622`) share it.
  - **`emitVerticesAssumeCapacity` (`:414-481`):** sets
    `vertex_count = valid_count * 6` and threads through
    `parallelForWithOptions` with `range_alignment_items = 4`. The comment at
    `:455-457` ("192/192/384 B per column") assumes 64-B column bases that the
    plain lists do not provide.
  - **`fillPreparedRange` (`:585-601`)** carries the dual write bounds.
  - **`buildDrawGroups` (`:503-558`)** uses `first_vertex = prepared_index * 6`
    and `vertex_count += 6`.
  - **`ensureFrameStorage` (`:345-354`)** sizes storage as `commands * 6`.
  - **AoS oracle test (`:1489-1598`)** proves the SoA columns bit-exact.
  - **Serial/threaded parity and `FailingAllocator` proofs:** `:1220-1262`,
    `:1063-1087`, `:1339-1390`.
- **`src/render/renderer.zig`:**
  - **Initial capacity (`:30-31`):** `4096 * 6` vertices.
  - **`VertexStreams` (`:133-190`):** 3 GPU buffers plus 3 transfer buffers.
  - **`reserveSpriteCommands` (`:439-453`):** sizes as `* 6`.
  - **Static geometry (`:484-560`):** `reserveStaticGeometry`, and
    `appendStaticTilemapSpan` taking `VertexColumnsConst`.
  - **Draw loop (`:744-823`):** binds the 3 vertex buffers on a source change,
    then calls `SDL_DrawGPUPrimitives(render_pass, group.vertex_count, 1,
    group.first_vertex, 0)` (`:822`).
  - **Grow and stage (`:1236-1282`, `:1403-1429`).**
  - **Copy pass (`:1290-1362`):** `cycle=true` per stream.
  - **`coalesceDrawList` (`:1452-1473`):** checks contiguity in vertex units.
- **`src/render/gpu/pipeline_common.zig:12-92`:**
  `SoaSpriteVertexPipelineLayout` declares slots 0/1/2 as FLOAT2/FLOAT2/FLOAT4
  with pitches from `@sizeOf`. The sprite and tilemap pipelines share it
  (`sprite_pipeline.zig:102`, `tilemap_pipeline.zig:148`).
- **`src/render/gpu/buffer.zig`:**
  - `:30-33` `columnBytes`
  - `:142-197` the one-shot create → map → copy → submit pattern
    (`uploadStorageData`)
  - `:329-341` the per-column byte test
- **Shaders.** `assets/shaders/sprite.vert.glsl:8-10` and
  `tilemap.vert.glsl:8-10` declare `vec2 in_position`, `vec2 in_uv`, and
  `vec4 in_color`; tilemap reads only position. Neither shader uses
  `gl_VertexIndex`.
- **Game-side quad builders.** These are the only non-render code that sees
  vertex columns:
  - `src/game/world_system.zig:37-38, 926-958`: `[6]Position/Uv/VertexColor`,
    then `writeWorldSpriteQuad` and `appendStaticTilemapSpan`.
  - `src/game/render_prep.zig:350-357`: `staticGeometryCapacity` uses
    `span_capacity * 6`; tests at `:1024-1025`.
  - `src/platform/gpu_smoke_impl.zig:16-19, 78-104`.
- **Benches:**
  - `src/benchmarks/render_prep.zig`, group `render-prep` (`:21-25`):
    reserve at `:71`; phase timers `ordered_submit`, `snapshot`,
    `vertex_emit`, and `draw_group` at `:160-194`.
  - `src/benchmarks/render_game_prep.zig`, groups `render-game-prep`,
    `-dense-surface`, and `-dense-deep` (`:60-77`): reserve at `:189`;
    hand-built `DrawGroup`s at `:649-661`.
- **`src/render/text.zig:734-738`:** private `colorByte` (clamp, then
  `@round(v * 255)`), the same conversion this slice needs.
- **`src/app/runtime_perf_log.zig:384`:** records `sprite_vertices` from
  `SpritePrepStats.vertex_count`.
- **SDL 3.4 (`zig-pkg/.../SDL3/SDL_gpu.h`):**
  - `SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM` (`:1084`)
  - `SDL_GPU_INDEXELEMENTSIZE_16BIT` (`:670`)
  - `SDL_GPU_BUFFERUSAGE_INDEX` (`:987`)
  - `SDL_BindGPUIndexBuffer` (`:3371`)
  - `SDL_DrawGPUIndexedPrimitives(pass, num_indices, num_instances,
    first_index, Sint32 vertex_offset, first_instance)` (`:3524-3554`). The
    header notes that the vertex offset is incompatible only with built-in
    vertex-ID shader variables, which neither shader uses.

### Architecture notes

**Byte budget (fixed arithmetic, not a measurement).**

| | Before | After |
| --- | --- | --- |
| Bytes per vertex | 8 + 8 + 16 = 32 B | 8 + 8 + 4 = 20 B |
| Vertices per sprite | 6 | 4 |
| Bytes per sprite | **192 B** | **80 B** (pos 32, uv 32, color 16) |
| Index bytes per sprite per frame | — | 0 (static buffer) |
| 2,048 sprites (`frame-battle` movers) | 393,216 B | 163,840 B |
| 4,096 sprites (`initial_batch_commands`) | 786,432 B | 327,680 B |
| 10,000 sprites (bench `quick` ceiling) | 1,920,000 B | 800,000 B |
| 50,000 sprites (bench `standard` ceiling) | 9,600,000 B (576 MB/s at 60 Hz) | 4,000,000 B (240 MB/s) |
| Static index buffer | — | 196,608 B, once at init |

The same 58.3% applies to the CPU columns, to the dynamic and static GPU vertex
buffers and their transfer buffers, and to the per-frame `stageVertices`
memcpy. At the initial reserve, each GPU stream set shrinks from 786,432 B to
327,680 B (16,384 vertices × 20 B), and so does its transfer set.

**Layout decisions and rejected alternatives.**

1. **Indexed quads.**
   - Each quad has 4 vertices: (TL, TR, BL, BR).
   - `quad_corner_indices = {0, 1, 2, 1, 3, 2}` is today's `indices`
     (`sprite_batch.zig:660`), so the GPU rasterizes the same two triangles
     from the same four positions.
2. **`u16` indices with a fixed chunk cap.**
   - The cap is `k_max_quads_per_indexed_draw = 16384` quads, which is
     65,536 vertices: the whole `u16` range.
   - A draw group larger than the cap is issued as consecutive chunks. Each
     chunk uses `first_index = 0` and `vertex_offset` = its first vertex.
   - The buffer is a fixed constant. It never grows, and it does not depend on
     sprite count, capacity, or world size.
   - **Index 65535 is a real vertex, not a restart.** The top index of the
     last quad equals the `u16` primitive-restart sentinel. That is safe
     because restart applies only to strip topologies, and every sprite and
     tilemap pipeline uses a triangle list:
     - Vulkan: SDL creates every pipeline with `primitiveRestartEnable =
       VK_FALSE` (`SDL_gpu_vulkan.c:6461`).
     - D3D12: SDL sets no strip-cut value.
     - Metal: restart applies to strip topologies only.

     A future strip-topology material must not reuse this buffer. The
     "Adding a New Material" doc edit states this.
   - **Rejected:** VoidLight's `u32` buffer sized to `MAX_SPRITES = 50000`
     (1.2 MB). Its coverage must match the largest group, so it either grows
     with the batch (a capacity-scaled resource) or caps sprites. `u16` with
     chunking is fixed, half the bytes, and costs one extra draw per 16,384
     quads.
3. **Color.**
   - `VertexColor = [4]u8` (rgba) with `SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM`.
   - It is packed once per sprite by `math.packUnorm8x4`: clamp to [0, 1],
     NaN → 0, then `@round(v * 255)`. That matches `text.zig` `colorByte`.
   - Tint quantization is ≤ 0.5/255. On the 8-bit SDR swapchain
     (`gpu/device.zig:42-46`), output is identical for 0/1 tints (white
     sprites, opaque rects) and within 1 LSB per channel otherwise.
   - Channels above 1 clamp. No live producer exceeds [0, 1]:
     - visual colors (`render_prep.zig:148-153`)
     - particle colors (`particle.zig:71-88`)
     - debug overlay alphas (`ai_debug_overlay.zig:343-346`)
     - text styles, which already reject non-normalized color (`text.zig`
       test at `:834-843`)
4. **Position and uv stay `f32x2`.**
   - **Rejected `HALF2` uv:** an 11-bit mantissa gives a step of 2^-11 near
     u = 1, which is 2 texels on a 4096 px atlas.
   - **Rejected `USHORT2_NORM` uv (64 B/sprite):** the error is up to
     0.5/65535 = 0.031 texel at 4096 px. `docs/atlas-asset-workflow.md`
     documents no atlas gutter, so a sub-pixel quad edge in `.drawable` can
     sample the neighbor cell.
   - **Rejected integer texel uv plus a per-texture size uniform:** it breaks
     the fractional `Sprite.source` rects the facade accepts.
5. **Keep three SoA streams; do not interleave.**
   - The bytes are identical either way.
   - Streams keep the slot 0/1/2 bind contract and the `VertexColumns` views
     that `writeWorldSpriteQuad` and `appendStaticTilemapSpan` take.
   - They keep the worker-seam math: per 4-command range, positions are
     128 B, uvs 128 B, and colors 64 B, all multiples of 64.
6. **64-byte column bases.**
   - `SpriteBatch.positions/uvs/colors` become
     `std.ArrayListAligned(T, .fromByteUnits(k_vertex_column_alignment))`
     with `k_vertex_column_alignment = 64`. Use
     `thread_system.thread_shared_record_alignment` instead if that
     constant has been consolidated by landing.
   - Together with `range_alignment_items = 4`, every worker seam then lies
     exactly on a cache line, which today's comment only assumes.
   - **Named exception to the MAL default:** these are GPU upload streams,
     each uploaded as raw bytes to its own buffer. Their 64-B bases are
     load-bearing for disjoint threaded writes, and the coding standards note
     that MAL does not guarantee 64-byte column bases.
   - The renderer's static columns (`static_positions/uvs/colors`) are
     written single-threaded and stay plain `ArrayList`s.
7. **Rejected per-sprite instancing (~48 B/sprite).**
   - It needs corners generated from vertex IDs. SDL documents
     `first_vertex`/`first_instance` as non-portable with built-in IDs
     (`SDL_gpu.h:3530-3535`), which forces per-group instance-buffer
     rebinding.
   - It moves rotation trig into both vertex shaders and breaks the tilemap
     world-position varying.
   - It regenerates all four shader artifacts for a further 32 B.
8. **No GLSL change.**
   - Normalized formats deliver float `vec4` to `in_color` on SPIR-V, MSL,
     and DXIL. `in_uv` stays FLOAT2.
   - The sources, the committed `.spv/.msl/.dxil`, and the lock do not
     change, so no `shaders-update` run is needed.
   - A guard test pins the attribute declarations. A future `uvec4 in_color`
     would need a non-normalized format.

**Types and constants (`sprite_batch.zig`; `renderer.zig` re-exports them at
module level beside `Position`/`Uv`/`VertexColor`).**

```zig
pub const VertexColor = [4]u8; // rgba, SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM
pub const k_quad_vertex_count: usize = 4;
pub const k_quad_index_count: usize = 6;
pub const QuadIndex = u16;
pub const quad_corner_indices = [k_quad_index_count]QuadIndex{ 0, 1, 2, 1, 3, 2 };
/// Full u16 index range: 16384 quads × 4 vertices = 65536 vertices.
pub const k_max_quads_per_indexed_draw: usize = 16384;
pub const k_quad_index_buffer_bytes: usize =
    k_max_quads_per_indexed_draw * k_quad_index_count * @sizeOf(QuadIndex); // 196_608
pub const k_vertex_bytes: usize = @sizeOf(Position) + @sizeOf(Uv) + @sizeOf(VertexColor); // 20
pub const k_quad_vertex_bytes: usize = k_vertex_bytes * k_quad_vertex_count; // 80
const k_vertex_column_alignment: usize = 64;
comptime {
    std.debug.assert(@sizeOf(Position) == 8 and @sizeOf(Uv) == 8 and @sizeOf(VertexColor) == 4);
    std.debug.assert(k_quad_vertex_bytes == 80);
    std.debug.assert(k_max_quads_per_indexed_draw * k_quad_vertex_count - 1 == std.math.maxInt(QuadIndex));
    // 4-command worker ranges stay cache-line multiples in every column.
    std.debug.assert((4 * k_quad_vertex_count * @sizeOf(Position)) % 64 == 0);
    std.debug.assert((4 * k_quad_vertex_count * @sizeOf(VertexColor)) % 64 == 0);
}
```

Functions (pure, headless):

- `pub fn quadIndices(quad: usize) [k_quad_index_count]QuadIndex`. It asserts
  `quad < k_max_quads_per_indexed_draw` and returns
  `quad_corner_indices[i] + quad * 4`.
- `pub fn fillQuadIndices(out: []QuadIndex) void`. It asserts
  `out.len == k_max_quads_per_indexed_draw * k_quad_index_count`.
- `pub const IndexedQuadDraw = struct { num_indices: u32, vertex_offset: i32 }`.
- `pub const IndexedQuadDrawIterator` has `init(first_vertex: u32,
  vertex_count: u32)`, which asserts both are multiples of 4, and
  `next() ?IndexedQuadDraw`. Each chunk covers
  `min(remaining_quads, k_max_quads_per_indexed_draw)` quads, and
  `vertex_offset = first_vertex + done_quads * 4`.
  - **Range proof:** `columnBytes` caps a positions column at
    `maxInt(u32)` bytes, so vertices ≤ 2^29 and every `vertex_offset`
    < 2^31.
- `pub fn packTint(color: config.Color) VertexColor` returns
  `math.packUnorm8x4(color.r, color.g, color.b, color.a)`.
- `src/core/math.zig` gains `pub fn unormByte(value: f32) u8` and
  `pub fn packUnorm8x4(r: f32, g: f32, b: f32, a: f32) [4]u8`.
  - `unormByte` is `if (!(value > 0)) 0 else if (value >= 1) 255 else
    @intFromFloat(@round(value * 255))`; the first test also catches NaN.
  - These are scalar only. They run once per sprite on 4 channels, and the
    lane dimension is sprites while emit is store-bound, so there is no SIMD
    pair to keep.
  - `text.zig` `colorByte` delegates to `math.unormByte`, removing the
    duplicate conversion.

**Emission and draw groups.**

- `writeSpriteQuad` writes lane `i` of the rotated corners to
  `positions[base + i]` and `uv[i]` to `uvs[base + i]` for i in 0..4. It then
  runs `@memset(out.colors[base..][0..4], packTint(sprite.tint))`.
  - The CPU does no index expansion.
  - The asserts become `base + k_quad_vertex_count <= len`.
- Every `* 6` vertex sizing becomes `* k_quad_vertex_count`:
  - in `sprite_batch.zig`: `ensureFrameStorage`, the
    `snapshotCommandsAssumeCapacity` asserts, `emitVerticesAssumeCapacity`,
    the `fillPreparedRange` asserts, and `buildDrawGroups`
  - in `renderer.zig`: `initial_batch_vertices`, `reserveSpriteCommands`,
    `ensureFrameBatchCapacity`, and tests
  - in game and benchmark code: `render_prep.staticGeometryCapacity`, and
    `render_prep.zig:71` / `render_game_prep.zig:189, 649-661`
- `setVertexCountAssumeCapacity` takes the aligned list type generically.
- `DrawGroup.first_vertex` and `vertex_count` stay in **vertex** units, now
  multiples of 4.
  - `coalesceDrawList`'s contiguity check is unchanged.
  - The draw loop converts vertex units to quads through
    `IndexedQuadDrawIterator`.
- Threading is structurally unchanged: disjoint ranges of 4 aligned
  commands, a serial fallback when there is no `ThreadSystem` or one range,
  and serial draw-group build. Output is a pure function of the
  prepared-command index, so serial == threaded bytes.

**Index buffer (`src/render/gpu/buffer.zig`).**

- `pub fn createQuadIndexBuffer(device) error{ SdlError, GpuBufferTooLarge,
  GpuMapMisaligned }!*c.SDL_GPUBuffer` follows the `uploadStorageData` pattern:
  1. Create an `INDEX` buffer of `k_quad_index_buffer_bytes`.
  2. Create a one-shot upload transfer buffer and map it with `cycle=false`
     (fresh).
  3. Call `sprite_batch.fillQuadIndices` directly into the mapped memory,
     through `@alignCast` to `[*]u16`. No Zig allocation happens.
     - The cast carries a local justification comment: SDL maps a whole
       transfer buffer at backend allocation granularity, which is at least
       4-byte aligned on every backend, so a 2-byte `QuadIndex` cast is
       sound.
     - The comment is not the guard. Before the cast, a cold-path check
       `if (@intFromPtr(mapped) % @alignOf(QuadIndex) != 0)` unmaps, releases
       the transfer and index buffers, and returns `error.GpuMapMisaligned`.
       A misaligned `@alignCast` is undefined behavior in ReleaseFast, and
       this init-time check costs nothing.
  4. Unmap, upload with `cycle=false` (the destination is written once and
     never re-uploaded), submit, and release the transfer buffer.
- **`Renderer.quad_index_buffer: *c.SDL_GPUBuffer`:**
  - created in `init` right after `createVertexStreams`, with an `errdefer`
    release
  - released in `deinit` after `waitForIdle`, beside the streams
  - CPU-only test renderers set it `undefined`, like `pipeline`
- SDL orders submission on the device queue, so the upload completes before
  the first frame's draws.
- **Cycle-policy table row:** "Quad index buffer | written once at init:
  source map `false`, destination upload `false`; never re-staged".

**Draw.**

- In `endFrame`, right after `applyDrawableViewport`, bind the index buffer
  once per render pass:
  `SDL_BindGPUIndexBuffer(pass, &.{ .buffer = self.quad_index_buffer,
  .offset = 0 }, SDL_GPU_INDEXELEMENTSIZE_16BIT)`.
- Replace `:822` with:
  `var it = IndexedQuadDrawIterator.init(group.first_vertex,
  group.vertex_count); while (it.next()) |d|
  c.SDL_DrawGPUIndexedPrimitives(render_pass, d.num_indices, 1, 0,
  d.vertex_offset, 0);`.
  - Both materials use it; a tilemap span is one quad and one indexed draw.
- **Slice 60:** `drawGroupRange` binds the index buffer at its top in both
  passes, because bindings do not persist across passes. The composite
  triangle has zero vertex buffers and uses `SDL_DrawGPUPrimitives(3,1,0,0)`,
  so it is unaffected.
- **Pipeline layout (`pipeline_common.zig`):** slot 2 attribute format
  becomes `SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM`; pitch is
  `@sizeOf(VertexColor)` = 4. The other slots are unchanged.

**Facade contract.**

- These keep their names, units, and semantics:
  - `Sprite`, `RenderOrder`, `CoordinateSpace`
  - `submitOrderedSprite`, `submitOrderedRectInSpace`
  - `reserveSpriteCommands(command_capacity)`, which counts commands
  - `beginStaticGeometry`
  - `reserveStaticGeometry(vertex_capacity, span_capacity)`
  - `appendStaticTilemapSpan`, `writeWorldSpriteQuad`
  - `spritePrepStats`, `setCamera`
- Visible deltas, all named:
  - (a) The `VertexColor` element type is `[4]u8`.
  - (b) A quad is `k_quad_vertex_count` (4) vertices. The three static-quad
    builders replace the literal `6` with `k_quad_vertex_count`, imported
    from `renderer.zig`.
  - (c) `appendStaticTilemapSpan` returns the new `error.PartialQuadSpan` when
    `vertices.positions.len % k_quad_vertex_count != 0`. This is a cold path,
    a returned error rather than an assert, because ReleaseFast strips
    asserts.
  - (d) `SpritePrepStats.vertex_count`, and so the perf-log
    `sprite_vertices` metric, counts 4 per sprite.

**Allocation and errors.**

- No new per-frame allocation, and the `FailingAllocator` proofs are kept.
- The index fill writes into SDL-mapped memory.
- Batch reservation keeps today's live-count reserve
  (`spriteCommandCapacity` / `dynamicRecordCapacity`) with geometric
  high-water growth, the standard practice for a per-frame render batch (the
  2026-10-06 capacity audit reviewed it and kept it).
- New errors: `error.PartialQuadSpan` (static append) and
  `createQuadIndexBuffer`'s `error{ SdlError, GpuBufferTooLarge,
  GpuMapMisaligned }`, which propagates out of `Renderer.init`.

**Diagnostics.**

- `render` `debug` once at init: "quad index buffer: 16384 quads, 196608 B,
  u16".
- The existing vertex-grow `warn` now reports 4 vertices per quad.
- No per-frame logging.

### Checklist

- [ ] `src/core/math.zig`: `unormByte` and `packUnorm8x4`, with tests:
  - 0 → 0, 1 → 255, 0.5 → 128, 0.25 → 64
  - −0.1 → 0, 1.7 → 255, NaN → 0, ±inf clamp

  `text.zig` `colorByte` delegates to it, and the `ColorKey` test passes
  unchanged.
- [ ] `sprite_batch.zig` types, constants, and comptime asserts (above):
  - `VertexColor = [4]u8` and `packTint`
  - `quadIndices`, `fillQuadIndices`, and `IndexedQuadDrawIterator`
  - 64-B-aligned column lists
  - 4-vertex `writeSpriteQuad`
  - all `* 6` sites switched; the `:455-457` comment updated to
    "128/128/64 B per column, 64-B bases"

  Tests:
  - **Oracle:** keep `aosOracleQuad` verbatim as the pre-slice six-vertex
    oracle. Expanding the four written corners through
    `quad_corner_indices` reproduces its positions and uvs bit-exactly, and
    each color equals `packTint` of the oracle tint.
  - **Index pattern:** `quadIndices(0) == {0,1,2,1,3,2}`; `quadIndices(1)`
    is offset by 4; `quadIndices(16383)` tops out at exactly 65535.
  - **Full buffer:** `fillQuadIndices` over a test-allocated
    98,304-entry slice writes `quadIndices(q)` for every quad `q`. Its last six
    entries are exactly `{65532, 65533, 65534, 65533, 65535, 65534}`. This
    test, not `gpu-smoke`, is what proves the last triangle's indices (see the
    smoke item).
  - **Iterator:**
    - 1 quad → 1 draw of 6 indices
    - exactly 16,384 quads → 1 draw
    - 16,385 quads → (98,304 indices at `vertex_offset = first`) plus
      (6 indices at `first + 65536`)
    - a non-zero `first_vertex`
    - 3 × 16,384 + 5 quads

    The index counts sum to `vertex_count / 4 * 6`.
  - **Offset bound:** `vertex_offset` stays < 2^31 at the largest
    `columnBytes`-valid capacity.
  - **Alignment:** after `reserveStorage`,
    `@intFromPtr(list.allocatedSlice().ptr) % 64 == 0` for all three
    columns.
  - **Existing tests:** group, order, parallel-parity, and alignment-knob
    tests updated to 4 per quad.
  - **Allocation proofs:** the `FailingAllocator` proofs "warmed sprite batch
    prep does not allocate" and "warmed multi-worker sprite prep does not
    allocate" re-pass at `command_capacity * k_quad_vertex_count`.
- [ ] `gpu/buffer.zig`: `createQuadIndexBuffer`, with the alignment
      justification comment and the `error.GpuMapMisaligned` cold check before
      `@alignCast`. The column-byte test expects color = 4 B, and
      `k_quad_index_buffer_bytes == 196_608`.
- [ ] `gpu/pipeline_common.zig`: slot 2 uses `UBYTE4_NORM` with pitch 4.
      Pure test: the layout's pitches equal `@sizeOf` of the column types,
      and the formats are FLOAT2/FLOAT2/UBYTE4_NORM. It is a struct value
      and needs no device.
- [ ] `renderer.zig`:
  - the `quad_index_buffer` field, with its init/deinit order
  - a per-pass index bind and the iterator draw loop
  - `initial_batch_vertices = 4096 * k_quad_vertex_count`
  - `error.PartialQuadSpan`
  - module re-exports of `k_quad_vertex_count` and `VertexColor`

  Tests:
  - `appendStaticTilemapSpan` rejects 6- and 3-vertex spans with
    `error.PartialQuadSpan`.
  - The window-slot, composite-cap, and allocation-free static/merge tests
    pass at 4 per span.
  - "reserve sprite commands is grow-only…" and "engine overlay top-up…"
    proofs pass.
- [ ] GLSL guard test. Add `build.zig` test imports `sprite_vert_glsl` and
      `tilemap_vert_glsl`, following the `tilemap_frag_glsl` pattern at
      `build.zig:163`. The test asserts each source contains
      `layout(location = 1) in vec2 in_uv;` and
      `layout(location = 2) in vec4 in_color;`.
- [ ] Game, platform, and benchmark call sites:
  - `world_system.zig:931-958` and `gpu_smoke_impl.zig:80-104`:
    `[k_quad_vertex_count]` corner arrays
  - `render_prep.zig:355`: `span_capacity * k_quad_vertex_count`; tests at
    `:1024-1025` updated
  - `render_prep.zig:71`, `render_game_prep.zig:189`, and `:649-661`:
    multiples of 4
- [ ] `gpu_smoke_impl.zig` adds a second frame after the existing
      sprite+tilemap frame:
  - `reserveSpriteCommands(16_400)`, then 16,400 `.world` 1×1 white rects
    at one `RenderOrder`. They coalesce into one group, which issues two
    indexed draws (`vertex_offset` 0 and 65,536).
  - SDL GPU validation (`gpu_debug`) stays clean.
  - **What this frame does not prove, and why that is accepted.** "Validation
    clean" cannot detect a dropped last triangle. The smoke has no readback
    path today (`gpu_smoke_impl.zig` and `gpu/*.zig` contain no
    `SDL_DownloadFromGPU*` call), and SDL_GPU exposes no primitive counter.
    Adding a texture download path only for this check is out of proportion.
    The risk is covered instead by:
    - the full-buffer unit test above, which pins index 65535 in place;
    - the restart analysis in Layout decision 2, which shows 65535 is drawn
      as a vertex on every backend for triangle lists.

    The frame's job is to exercise the second chunk's non-zero
    `vertex_offset` (Metal `baseVertex`, D3D12 `BaseVertexLocation`) under
    validation. If a later slice adds a smoke readback path, it also asserts
    the last quad's pixel here.
- [ ] Doc and cross-slice edits:
  - **`docs/rendering-assets-shaders.md`:**
    - Sprite Rendering: the stream formats, 4 vertices per quad, the
      shared `u16` index buffer and 16,384-quad chunks, and 80 B per sprite.
    - A cycle-table row for the index buffer.
    - Adding a New Material: a material using the sprite vertex layout draws
      through the index buffer and `IndexedQuadDrawIterator`. The shared
      buffer is triangle-list only, because its index 65535 equals the `u16`
      restart sentinel.
  - **`docs/architecture.md`:** the sprite-batch bullet (`:37`) and the
    render-prep paragraph (`:201-218`) name the indexed 4-vertex layout.
  - **Slice 60 section:** `drawGroupRange` binds the 70A quad index buffer
    per pass, if 70A landed first.

### Acceptance checks

- [ ] `zig build verify` passes. The shader stale-lock gate is untouched,
      because no `.glsl` changed.
- [ ] Bench gate. On one machine, record each command before and after, and
      paste both into the PR:
  - `zig build bench --release=fast -- --group render-prep --profile standard --items 10000 --details`
  - the same command with `--items 50000`
  - `zig build bench --release=fast -- --group render-game-prep --details`

  Pass criteria:
  - `vertex_emit_ns` at 10,000 and 50,000 is below the pre-slice value, for
    both `serial-direct` and `thread-fixed-2`.
  - `ordered_submit_ns`, `snapshot_ns`, and `draw_group_ns` do not regress
    by more than 5%.
  - The reported vertex count (`candidate_pairs`) is 4 × the valid sprite
    count.
- [ ] `zig build gpu-smoke` passes on Linux with validation clean, including
      the two-chunk frame. The 52C CI gpu-smoke job and macOS arm64 run it
      when available. Metal `baseVertex` is exercised by the non-zero
      `vertex_offset`.
- [ ] Manual `zig build run`, compared against a pre-slice screenshot at the
      same camera:
  - world sprites, the tilemap with rim shadow, particles, the F2 debug
    cones and rings, and menus all render with no missing or garbled quads
  - tints are visually identical
- [ ] Every `FailingAllocator` proof named in the Checklist passes.

### VoidLight reference

**Port:**

- `include/gpu/GPUTypes.hpp:15-22`: `SpriteVertex` is 20 B (f32 pos, f32 uv,
  `uint8` rgba).
- `src/gpu/GPUPipeline.cpp:140-158`: FLOAT2/FLOAT2/`UBYTE4_NORM` attributes.
- `include/gpu/SpriteBatch.hpp:35-41`: 4 vertices and 6 indices per sprite.
- `src/gpu/SpriteBatch.cpp:22-94`: index buffer prebuilt once through a
  one-shot transfer.
- `:362-368`: bind once, then `SDL_DrawGPUIndexedPrimitives`.

**Do not port:**

- The 32-bit index buffer sized to `MAX_SPRITES = 50000` (1.2 MB), which is
  also a hard sprite cap. ZL uses a fixed `u16` 16,384-quad buffer plus
  `vertex_offset` chunking.
- The interleaved single stream. ZL keeps SoA streams for its three-slot
  contract and worker seams.
- Writing vertices straight into a mapped pool during recording
  (`SpriteBatch.hpp:62-79`, `begin(SpriteVertex* writePtr, …)`). ZL keeps CPU columns, threaded emit, and the
  pre-acquire stage.
- One `SpriteBatch` instance per texture. ZL uses one ordered stream with
  texture-keyed draw groups.

