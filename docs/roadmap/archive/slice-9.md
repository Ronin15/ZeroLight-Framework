## Slice 9: Platform-Neutral SIMD Helper Layer

Goal: provide a small SIMD helper layer with clear project names so movement,
particles, and other hot data processors can use vectors without exposing
platform-specific intrinsic names throughout gameplay code.

Current foundation:

- `src/core/math.zig` contains small math primitives.
- `ThreadSystem.parallelFor` already divides work into contiguous ranges.
- Future movement and particle processors are expected to operate on SoA slices.
- The v1 helper uses Zig `@Vector` as the project abstraction; LLVM may lower the
  resulting vector operations to SSE-family or NEON instructions for suitable
  targets and optimize modes, but this slice does not hand-write target-specific
  intrinsics.

Checklist:

- [x] Add `src/core/simd.zig` with friendly vector aliases such as `Float4`,
      `Int4`, and `Mask4`.
- [x] Prefer portable Zig vector types first, hiding target-specific intrinsic
      details behind the helper API.
- [x] Add load, store, splat, add, subtract, multiply, divide, min, max,
      compare, select, and clamp helpers needed by movement and particle loops.
- [x] Add scalar-tail helpers for item counts that are not a multiple of the
      vector lane count.
- [x] Keep the helper free of game-specific entity, particle, SDL, renderer, or
      thread-system dependencies.
- [x] Document when scalar code should be preferred for tiny batches or clarity.

Acceptance checks:

- [x] SIMD helper tests prove lane order is stable.
- [x] SIMD and scalar implementations produce identical results for representative
      float and integer operations.
- [x] Tail handling covers empty, partial, exact-lane, and multi-lane inputs.
- [x] `zig build test` passes on targets where the helper is expected to compile.

