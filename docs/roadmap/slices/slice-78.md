## Slice 78: Comptime Assessment

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: none · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Owner direction 2026-10-09: log it so it is not
forgotten; independent of the 64G seal work.

Goal: every place that does at runtime what Zig's comptime could do at build
time is found and either moved to comptime or kept with its reason, so
build-time facts are checked by the compiler and cost nothing per step or
frame.

### Current foundation

- Pipeline stage order is checked at build time (`stageContract()` and
  `stage_order` in `src/game/simulation_pipeline.zig`).
- Build-time drift checks (`@compileError`) guard layouts and bounds, for
  example the AI memory ring against `simd.lane_count` and the nav memory
  estimate against the group-field layout.
- Shipping builds compile instrumentation away (`src/app/runtime_perf_log.zig`).
- Comptime-built tables and `inline for` over fields and enums are in use
  across `src/`.
- Type erasure (`*anyopaque` + function pointers) sits at cold service
  boundaries and at thread job dispatch (one indirect call per worker range).

### Architecture notes

- Findings follow `.claude/rules/zig-style.md` and
  `.claude/rules/memory-performance.md` (hot paths do no per-item dynamic
  dispatch or repeated validation); a moved check keeps its behavior and
  tests.
- An assessment first; changes land per owning module, each with its tests.

### Checklist

- [ ] Read-only assessment, one row per candidate: runtime checks of values
      known at build time, tables built at init that could be built at
      compile time, switches or dispatch on values fixed for the build, and
      hot-path type erasure a comptime-generic form would remove; each with
      its verdict and reason.
- [ ] Land the accepted rows in their owning modules, each with its tests.

### Acceptance checks

- [ ] Every candidate in the assessment is moved to comptime or kept with
      its reason.
- [ ] `zig build verify` passes; hot-path benches touched by a change show
      no regression beyond run-to-run spread.
