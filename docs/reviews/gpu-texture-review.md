# GPU Review: Texture Upload

**Files:** `texture.zig`  
**Date:** 2026-06-29  
**Reviewer:** zig-review-specialist (review-only)  
**Validation:** `zig build check` — pass

## Findings

### Medium — `UploadedTexture` ownership contract is undocumented at the API boundary

- **File:** `src/render/gpu/texture.zig:12-15`
- **Behavior:** `UploadedTexture` returns a live `*c.SDL_GPUTexture` plus `TextureDesc`, but the module does not document that the caller must register and later release via `Renderer` / `resources.zig`.
- **Why it matters:** GPU texture lifetime is easy to get wrong at the render boundary. Today only `renderer.zig` calls `uploadFromPixels`; knowledge is implicit in `Renderer.init` teardown.
- **Fix direction:** Add `///` on `UploadedTexture` and `uploadFromPixels` stating caller owns the texture until `SDL_ReleaseGPUTexture` through the resource registry.

### Medium — Transfer buffer sized to full `pixels.len`, not minimum required length

- **File:** `src/render/gpu/texture.zig:48-58`
- **Behavior:** `validatePixels` requires `pixels.len >= pitch * height` but allows larger slices. Transfer buffer `size` uses `pixels.len`, copying and allocating for the entire slice even when only `required_len` bytes are meaningful.
- **Why it matters:** Callers passing oversized backing buffers (common with decoder padding) pay extra transfer memory and copy cost per texture load — cold path, but scales with atlas size.
- **Fix direction:** Size transfer buffer to `required_len` from validation and pass a `pixels[0..required_len]` slice to `@memcpy`.

### Low — No test that `uploadFromPixels` rejects post-validation SDL failures distinctly

- **File:** `src/render/gpu/texture.zig:17-108`
- **Behavior:** Unit tests cover `validatePixels` and sizing helpers only; no mock/display-free test of the full upload orchestration (texture create → map → submit).
- **Why it matters:** `errdefer`/`defer` pairing on partial failure is correct by inspection but unverified by test.
- **Fix direction:** Acceptable without display if left as-is; optional integration behind `gpu-smoke` or a narrow SDL mock is enough.

### Low — `validatePixels` is public but `checkedTextureBytes` / `checkedPixelsPerRow` are private

- **File:** `src/render/gpu/texture.zig:110-128`
- **Behavior:** External callers can validate pixels but cannot reuse the same overflow guards without duplicating logic.
- **Fix direction:** Minor; export sizing helpers if other upload paths appear, or keep private if `uploadFromPixels` remains the only entry.

### Low — Upload uses immediate submit outside frame command buffer

- **File:** `src/render/gpu/texture.zig:61-102`
- **Behavior:** Texture load acquires its own command buffer and submits before the texture is registered — correct for asset load, separate from per-frame draw submission.
- **Why it matters:** Not a bug; worth noting that bulk runtime texture creation during gameplay (if ever added) would need batching policy.
- **Fix direction:** Document as load-time-only in module header if runtime streaming is considered later.

## What Looks Correct

- `validatePixels` runs before any SDL_GPU allocation (`texture.zig:24-29`).
- `errdefer` releases texture on failure; transfer buffer uses `defer` release (`texture.zig:44-52`).
- Copy pass uses `copy_pass_open` + `errdefer SDL_EndGPUCopyPass` (`texture.zig:73-76`).
- Command buffer cancel on failure before submit (`texture.zig:64-67`).
- Pitch/width/height/length validation has thorough unit tests (`texture.zig:134-160`).
- Only `renderer.zig` imports this module — render boundary intact.

## Summary

`texture.zig` is in good shape: validation precedes GPU work, cleanup on failure is sound, and tests cover the validation contract well. No High-severity leak/UAF/boundary issues. Follow-up is documentation of ownership and optionally sizing the transfer buffer to the validated minimum length.

**Issue counts:** 0 High, 2 Medium, 3 Low