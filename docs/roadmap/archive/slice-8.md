## Slice 8: Shader And Platform Expansion

**Status: landed.** All Checklist and Acceptance checks below are `[x]`.

Goal: keep platform support reliable as shader count and target platforms grow.

Current foundation:

- SDL chooses the GPU backend from supplied shader formats.
- Linux builds SPIR-V, macOS builds MSL, and Windows builds DXIL.
- Runtime selects shader files from SDL-reported supported formats.
- Build metadata and runtime pipeline metadata are still updated in separate
  places until a shared shader/material manifest exists.

Architecture notes:

- Shader expansion should add render-owned material/pipeline metadata; it should
  not push shader, pipeline, or SDL_GPU handles into `DataSystem` or gameplay
  state.
- Lighting, fire, post-effect, and tile shaders should keep draw intent as
  stable asset/material IDs plus typed render order until render prep resolves
  them into queue records or a render-owned batcher stream.
- New batchers may be added for tile spans, light volumes, or effect particles,
  but they should consume an explicitly ordered stream or a documented
  render-owned phase with the same ordering guarantees. Do not add renderer
  fallback sorting to hide unordered producers.
- Build-time shader manifests and runtime pipeline registries should converge so
  adding a material does not require unrelated parallel edits.

Checklist:

- [x] Keep generated runtime shader files under `assets/shaders` in the install
      tree.
- [x] Add explicit Windows target output through DXIL.
- [x] Keep runtime backend selection SDL-driven; do not hard-code GPU driver names.
- [x] Consolidate shader-program, material, and runtime pipeline metadata so
      new pipelines do not need parallel registry edits.
- [x] Define the material/batcher routing contract for sprites, tile spans,
      lighting/fire effects, and post-effect passes without exposing SDL_GPU
      handles to game code.
- [x] Validate the right shader format list for each target OS.
- [x] Add direct runtime asset/shader lookup guidance or tests for direct binary
      execution outside the installed binary directory.
- [x] Add shader output checks for each supported target path.

Acceptance checks:

- [x] `zig build shaders` emits the same sprite shader outputs as before.
- [x] `zig build verify` exercises shader compilation.
- [x] `zig build gpu-smoke` confirms runtime submission on display-capable hosts.


