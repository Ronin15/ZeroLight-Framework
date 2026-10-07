# src/benchmarks

- `zig build bench` measures performance and runs OOM/leak sweeps; `zig build
  test` checks contracts only and never times anything (CS § Benchmarks).
- Run targeted groups: `zig build bench -- --group <name>` (optionally
  `--case`/`--items`). Never run the whole suite and filter it; a full-suite
  sweep runs only when the owner asks or a slice names it.
- Test code never calls into this directory. Only `suite.zig`'s tests of its
  pure utilities, against hand-built stubs, live here. Fixture correctness
  rides on internal `std.debug.assert`s during real bench runs.
- Large-scale cases (e.g. 50k items) are stress tests and throughput ceilings,
  not per-frame targets; weight results by how often that count really occurs.
- A perf question with no covering case gets a new or extended case here.
