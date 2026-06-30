# GPU Pipelines Review — `sprite_pipeline.zig` & `tilemap_pipeline.zig`

**Files:** `sprite_pipeline.zig`, `tilemap_pipeline.zig`  
**Date:** 2026-06-29  
**Reviewer:** zig-review-specialist (review-only)  
**Validation:** `zig build check` — pass

## Findings

### Medium — Duplicated graphics-pipeline boilerplate between sprite and tilemap

- **Files:** `src/render/gpu/sprite_pipeline.zig:91-155`, `src/render/gpu/tilemap_pipeline.zig:148-212`
- **Behavior:** `createSpritePipeline` and `createTilemapPipeline` each carry ~65 identical lines: SoA vertex-buffer descriptions, vertex attributes, alpha blend state, rasterizer defaults, and pipeline create info. Only fragment resource counts and shader paths differ.
- **Why it matters:** `sprite_batch.zig` documents a fixed slot/layout contract. One-sided updates to blend, cull, or attribute format produce silent GPU misbinding.
- **Fix direction:** Extract shared `buildSoaSpriteVertexPipelineInfo(...)` parameterized by shader handles; keep material-specific resource counts per pipeline.

### Medium — Tilemap GPU bind/draw contract has no display smoke coverage

- **Files:** `src/platform/gpu_smoke_impl.zig`, `src/render/renderer.zig:601-609`
- **Behavior:** `gpu-smoke` draws one sprite rectangle. `Renderer.init` loads both pipelines, but nothing exercises tilemap binds: storage buffer + fragment UBO + `Material.tilemap`.
- **Why it matters:** Metal storage-slot shift and DXIL/SPIR-V binding translation are only validated on first real tilemap draw.
- **Fix direction:** Extend `gpu-smoke` with a minimal `appendStaticTilemapSpan` draw, or a display-gated integration test.

### Medium — Tilemap material resource counts are undocumented at test time

- **Files:** `src/render/gpu/tilemap_pipeline.zig:67-82`, `assets/shaders/tilemap.frag.glsl`
- **Behavior:** `tilemap_material` declares sampler/storage/uniform counts passed into `createShader`. No test pins counts to GLSL binding layout.
- **Why it matters:** Off-by-one on storage vs sampler fails late in SDL/driver validation.
- **Fix direction:** Unit test or comptime assert mirroring `docs/rendering-assets-shaders.md` binding layout.

### Low — `shaderSetForFormat` duplicates format→path logic

- **Files:** `src/render/gpu/tilemap_pipeline.zig:86-105`, `src/render/gpu/sprite_pipeline.zig:173-207`
- **Behavior:** Tilemap path selection is a separate MSL/DXIL/SPIR-V chain instead of reusing `selectShaderSetFromFormats`.
- **Fix direction:** Share one selection implementation; keep tilemap path/name tests on top.

### Low — `tests.zig` omits direct `tilemap_pipeline` import

- **File:** `src/tests.zig:66-67`
- **Behavior:** `sprite_pipeline.zig` is imported explicitly; `tilemap_pipeline.zig` is only transitive via `renderer.zig`.
- **Fix direction:** Add `_ = @import("render/gpu/tilemap_pipeline.zig");` for symmetric compile coverage.

### Low — `createShader` does not validate non-empty bytecode

- **File:** `src/render/gpu/sprite_pipeline.zig:228-248`
- **Behavior:** Zero-length shader files still reach `SDL_CreateGPUShader`.
- **Fix direction:** `if (code.len == 0) return error.EmptyShaderAsset` after read.

## What Looks Correct

- Shaders use `defer SDL_ReleaseGPUShader` after creation; pipeline failure does not leak shader handles.
- `Renderer.init` uses `errdefer` for sprite then tilemap pipeline release.
- `Renderer.deinit` releases batch/buffers before sampler/pipelines before device.
- MSL > DXIL > SPIR-V selection with device∩app mask; both pipelines share `shader_set.format`.
- Vertex layout matches `sprite_batch.zig` SoA contract; standard alpha blend on both pipelines.

## Summary

No High-severity defects. Pipelines are correctly wired to `Renderer`/`SpriteBatch`. Main follow-up: deduplicate pipeline boilerplate and extend `gpu-smoke` to exercise tilemap storage-buffer + fragment-UBO binds.

**Issue counts:** 0 High, 3 Medium, 3 Low