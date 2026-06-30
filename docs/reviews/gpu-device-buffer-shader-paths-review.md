# GPU Review: Device, Buffer, Shader Paths

**Files:** `device.zig`, `buffer.zig`, `shader_paths.zig`  
**Date:** 2026-06-29  
**Reviewer:** zig-review-specialist (review-only)  
**Validation:** `zig build check` — pass

## Findings

### Medium — Vertex staging/upload lacks defensive size validation

- **File:** `src/render/gpu/buffer.zig:35-71`
- **Behavior:** `stageVertices` and `recordVertexUpload` copy `bytes.len` into GPU buffers without checking against the buffers' allocated sizes. Only `u32` overflow is guarded via `checkedGpuBytes`.
- **Why it matters:** Correctness depends on `Renderer.ensureBatchCapacity` staying in lockstep with `createVertexStreams`. A regression that stages before growing is an out-of-bounds write on mapped GPU memory.
- **Fix direction:** Add `validateVertexUpload(bytes_len, buffer_byte_size)` and call from both helpers; mirror `texture.zig` with unit tests.

### Medium — `uploadStorageRegions` has no in-module bounds validation

- **File:** `src/render/gpu/buffer.zig:146-196`
- **Behavior:** Partial storage writes compute `dst_byte_offset` from `element_index` without knowing the destination buffer's element count. Only `Renderer.uploadTileDataEdits` rejects out-of-range indices today.
- **Why it matters:** The helper is a public GPU-boundary API. Future callers that skip renderer-side validation can issue out-of-bounds GPU writes.
- **Fix direction:** Extend `StorageRegion` with `element_count` or pass buffer sizes; reject `element_index >= element_count` before copying.

### Medium — Dig path allocates transfer buffer and submits standalone command buffer per flush

- **File:** `src/render/gpu/buffer.zig:146-196`
- **Behavior:** Each `uploadStorageRegions` call creates a new transfer buffer, acquires a command buffer, records one copy pass, and submits immediately.
- **Why it matters:** Active digging is gameplay-hot and currently does per-flush GPU resource creation and an extra submit outside the main frame command buffer.
- **Fix direction:** Pool a reusable dig transfer buffer on `Renderer`; record tile patches into the frame's acquired command buffer where ordering allows.

### Medium — Test coverage gaps on device setup and upload contracts

- **File:** `src/render/gpu/device.zig`, `src/render/gpu/buffer.zig:35-196`, `src/render/gpu/shader_paths.zig`
- **Behavior:** `buffer.zig` tests cover byte-size math only. `device.zig` has no unit tests. `shader_paths.zig` has no co-located tests (indirect coverage via pipeline material structs).
- **Why it matters:** Staging size vs buffer capacity and present-mode fallback are unverified without display.
- **Fix direction:** Add display-free tests for `shader_paths` comptime strings, upload bounds helpers, and `selectPresentMode` logic.

### Low — Storage upload helpers omit copy-pass `errdefer` used elsewhere

- **File:** `src/render/gpu/buffer.zig:117-123`, `src/render/gpu/buffer.zig:174-190`
- **Behavior:** `recordVertexUpload` guards `SDL_BeginGPUCopyPass` with `copy_pass_open` + `errdefer`. Storage upload helpers do not, though current code cannot error mid-pass.
- **Fix direction:** Reuse the same `copy_pass_open` / `errdefer` pattern for consistency.

### Low — `device.zig` public helpers lack ownership doc comments

- **File:** `src/render/gpu/device.zig:10-59`
- **Behavior:** `createDevice`, `claimWindow`, `configureSwapchain`, and `createSampler` lack `///` ownership/teardown ordering docs.
- **Fix direction:** Document caller ownership and pairing with `SDL_DestroyGPUDevice` / `SDL_ReleaseGPUSampler`.

### Low — Present-mode fallback assumes vsync is always supported

- **File:** `src/render/gpu/device.zig:69-81`
- **Behavior:** When requested mode is unsupported, falls back to `SDL_GPU_PRESENTMODE_VSYNC` without probing vsync support.
- **Fix direction:** Probe vsync; if unsupported, walk a fixed preference list (mailbox → immediate → vsync).

## Open Questions

- **Tile edit submit ordering:** `flushDenseTileEdits` submits its own command buffer before swapchain acquire. Is the documented one-frame read race acceptable on all target backends?

## Summary

No High-severity defects under current `Renderer` call-site contracts. Ownership and init/deinit ordering look sound; only `renderer.zig` imports these modules (boundary respected). Main risks: missing defensive upload validation, per-flush GPU churn on the dig path, and thin unit-test coverage for device setup.

**Issue counts:** 0 High, 4 Medium, 3 Low