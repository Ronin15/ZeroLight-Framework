# `tools/`

Developer tooling for ZeroLight-Framework: the asset/atlas pipeline, idiom
lint, and the benchmark runner. These are build- and content-side helpers —
they are **not** part of the game binary.

## Conventions

- **Language:** Python 3. Run everything from the **repository root** (paths are
  resolved relative to it), e.g. `python3 tools/pack_atlas.py …`.
- **Dependency:** the asset-generation scripts need [Pillow](https://pypi.org/project/Pillow/)
  (`from PIL import Image`). Install with `pip install Pillow`. The benchmark
  runner, asset lint, and idiom lint scripts are stdlib-only.
- **Shared modules** (`*_common.py`, `tileset_quality.py`) are imported by the
  CLIs, not run directly.
- The canonical description of the atlas workflow lives in
  [`docs/atlas-asset-workflow.md`](../docs/atlas-asset-workflow.md); this README
  is just the index.

## Runnable scripts

| Script | What it does |
| --- | --- |
| `bench_run.py` | Run `zig build bench`, save a timestamped copy to `benchmark_outputs/`, and rotate to the newest N runs. |
| `gen_atlas_orders.py` | Generate atlas **order manifests** (`atlas_orders/*.json`) from the procedural sprite registries. |
| `generate_grim_sprites.py` | Generate the grim-dark fantasy character and item sprite atlases. |
| `generate_world_tileset.py` | Generate the grim-dark 32×32 world tileset atlas. |
| `pack_atlas.py` | Pack loose, filename-driven source sprites into atlas PNG + JSON manifests. |
| `export_source_sprites.py` | Inverse of packing: export loose source PNGs back out of installed atlas sheets + JSON manifests. |
| `lint_assets_if_changed.py` | Lint registered runtime atlas PNG/JSON (and optional source sprites). Wired into `zig build verify` via the atlas-lint step. |
| `lint_idioms.py` | Lint Zig naming, current stdlib spellings, and unsafe `catch`/`orelse unreachable`. Wired into `zig build verify` via `zig build idiom-lint`. |

## Shared modules (imported, not run)

| Module | Used by |
| --- | --- |
| `atlas_pack_common.py` | `pack_atlas.py`, `export_source_sprites.py`, `gen_atlas_orders.py` |
| `tileset_common.py` | `gen_atlas_orders.py`, `generate_grim_sprites.py`, `generate_world_tileset.py`, `tileset_quality.py` |
| `tileset_quality.py` | `generate_world_tileset.py` |

## `atlas_orders/`

Order manifests consumed by the packing/generation step: `characters.json`,
`items.json`, `world_tiles.json`. Regenerate with `gen_atlas_orders.py`.

## Benchmark runner — `bench_run.py`

Wraps `zig build bench`: streams output live, saves a header-stamped copy
(date, commit, branch, host, cpu count, args) to `benchmark_outputs/`
(gitignored), and prunes to the newest runs. `latest.txt` symlinks the most
recent run for quick `diff`-ing. The repetitive `ThreadSystem initialized`
debug lines are stripped from the saved copy by default.

```sh
tools/bench_run.py                 # run, save, rotate (keep 20)
tools/bench_run.py --keep 50       # deeper history window
tools/bench_run.py --no-strip      # keep the ThreadSystem debug lines
tools/bench_run.py -- --details    # forward args to the bench binary
```

## Asset pipeline at a glance

```
registries ──gen_atlas_orders.py──▶ atlas_orders/*.json
                                          │
   source sprites ──pack_atlas.py / generate_*.py──▶ atlas PNG + JSON manifests
                                          │
                                  lint_assets_if_changed.py  (also via `zig build verify`)
```

`export_source_sprites.py` runs the pipeline in reverse to recover loose PNGs
from packed sheets.
