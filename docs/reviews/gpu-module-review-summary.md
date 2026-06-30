# `src/render/gpu` — Multi-Reviewer Summary

**Scope:** All 6 files in `src/render/gpu/`  
**Date:** 2026-06-29  
**Reviewers:** 3× zig-review-specialist (device/buffer/shader-paths, texture, pipelines)  
**Validation:** `zig build check` — pass

## Files Reviewed

| File | Lines | Review doc |
|------|------:|------------|
| `device.zig` | 85 | [gpu-device-buffer-shader-paths-review.md](./gpu-device-buffer-shader-paths-review.md) |
| `buffer.zig` | 239 | [gpu-device-buffer-shader-paths-review.md](./gpu-device-buffer-shader-paths-review.md) |
| `shader_paths.zig` | 18 | [gpu-device-buffer-shader-paths-review.md](./gpu-device-buffer-shader-paths-review.md) |
| `texture.zig` | 160 | [gpu-texture-review.md](./gpu-texture-review.md) |
| `sprite_pipeline.zig` | 315 | [gpu-pipelines-review.md](./gpu-pipelines-review.md) |
| `tilemap_pipeline.zig` | 217 | [gpu-pipelines-review.md](./gpu-pipelines-review.md) |

## Combined Issue Counts

| Severity | Count |
|----------|------:|
| High | **0** |
| Medium | **9** |
| Low | **9** |

## Top Findings (all reviewers)

1. **[Medium]** `buffer.zig` — vertex staging lacks defensive size checks vs allocated buffer capacity.
2. **[Medium]** `buffer.zig` — `uploadStorageRegions` trusts caller for element-index bounds; dig path allocates + submits per flush.
3. **[Medium]** `texture.zig` — `UploadedTexture` ownership undocumented; transfer buffer may oversize on padded pixel slices.
4. **[Medium]** `sprite_pipeline.zig` / `tilemap_pipeline.zig` — ~65 lines duplicated pipeline setup; drift risk.
5. **[Medium]** `tilemap_pipeline.zig` — no `gpu-smoke` coverage for tilemap storage-buffer + UBO binds.
6. **[Medium]** `tilemap_pipeline.zig` — material resource counts not tested against shader binding layout.
7. **[Medium]** `device.zig` / `buffer.zig` / `shader_paths.zig` — thin unit-test coverage on setup and upload invariants.

## Verdict

The GPU module is **ship-ready** under current `Renderer`-only usage: render boundary is respected, init/deinit pairing is sound, and `texture.zig` validates before GPU work. No crash/leak/UAF High findings. Priority follow-ups are defensive upload bounds in `buffer.zig`, tilemap draw smoke coverage, and deduplicating pipeline creation.