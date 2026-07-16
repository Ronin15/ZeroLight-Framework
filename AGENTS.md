# ZeroLight-Framework

Shared project contract for agents in this repo.

| Harness | Role | Specialist tooling |
|---------|------|--------------------|
| **Grok Build** | **Primary** | `.grok/agents/`, `.grok/skills/` |
| **Cursor Agent CLI** | Secondary | `.cursor/agents/`, `.cursor/skills/`, `.cursor/rules/` |

Engineering rules below (docs, ownership, hot path, build, bench≠test) apply to
**both**. Harness-specific layout and spawn mechanics differ; do not require one
tree to load the other.

**Do not invent architecture** — read the owning `docs/` file and live `src/`
before editing.

**Stack:** Zig **0.16**, **SDL3 / SDL_GPU**, fixed-step **60Hz** sim, state stack
with policy-driven input, atlas assets by stable IDs, data-oriented SoA
(`DataSystem`, `WorldSystem`), state-owned `SimulationPipeline`, threaded/SIMD
processors (movement, AI, steering, collision, pathfinding, particles).

---

## Grok Build — layout and routing (primary)

Grok specialist behavior is **self-contained under `.grok/`** (prompts, presets,
and multi-phase workflows do not depend on `.cursor/`):

| Path | Role |
|------|------|
| `.grok/agents/zig-*.md` | Subagent types for `spawn_subagent` |
| `.grok/skills/zig-workflows/` | Inline vs delegate; design/implement/debug/review |
| `.grok/skills/pathfinder-review/` | Multi-agent pathfinder module review |
| `.grok/skills/architecture-assessment/` | Emergent-gameplay readiness assessment |
| `.grok/skills/zig-best-practices-review/` | Hot-subsystem best practices + durable guidance |
| `.grok/skills/zig-deep-correctness-review/` | Concurrency / determinism / test-gap deep pass |
| `.grok/skills/zig-workflows/references/module-presets.md` | Review unit file tables |
| `.grok/config.toml` | Project MCP / permissions only (**not** model defaults) |

### Subagents (`spawn_subagent`)

| Type | Mode | Use |
|------|------|-----|
| `zig-design-specialist` | read-only / plan | Non-trivial design, pipeline/ECS contracts |
| `zig-specialist` | full | Implement in owning modules |
| `zig-debug-specialist` | full | Build, test, shader, SDL/GPU, runtime failures |
| `zig-review-specialist` | read-only / plan | PR/diff/module review (no edits unless asked) |

**Rules:**

- Only the **parent** may spawn (depth 1). Multi-phase skills are parent-orchestrated.
- Work **inline** for 1–2 file local fixes with no architecture/pipeline change.
- **Delegate** for non-trivial features, named specialists, failures, PR review,
  hot-path/threading/pipeline work, or multi-phase skills.
- Prefer `background: true` for parallel units; collect with
  `get_command_or_subagent_output`.
- Design/review: `capability_mode: "read-only"` (agents also set `permission_mode: plan`).
- Do not restate full guardrails in child prompts — agents load `agents_md`.
- Multi-phase: run the matching skill (`/pathfinder-review`, etc.), not an ad-hoc
  partial review, unless the user narrows scope.

| Ask / signal | Action |
|--------------|--------|
| Design before coding | `zig-design-specialist` |
| Implement slice / feature | Design if contracts unclear → `zig-specialist` |
| Build/test/GPU failure | `zig-debug-specialist` |
| Review branch / PR / diff | `zig-review-specialist` |
| Pathfinder module review | `/pathfinder-review` |
| Emergent gameplay readiness | `/architecture-assessment` |
| Best-practices / durable lint | `/zig-best-practices-review` |
| Deep races/determinism/tests | `/zig-deep-correctness-review` |

### Model routing (policy only)

Grok does **not** switch the parent model from this file. Pin subagents in
**user** `~/.grok/config.toml` (`[subagents.models]`). Project `.grok/config.toml`
cannot set models.

| Role | Model | Subagents |
|------|--------|-----------|
| Plan / design / review | `grok-4.5` | `plan`, `explore`, `zig-design-specialist`, `zig-review-specialist` |
| Implement / debug | `grok-composer-2.5-fast` | `general-purpose`, `zig-specialist`, `zig-debug-specialist` |

Recommended pins:

```toml
# ~/.grok/config.toml
[subagents.models]
plan = "grok-4.5"
explore = "grok-4.5"
zig-design-specialist = "grok-4.5"
zig-review-specialist = "grok-4.5"
general-purpose = "grok-composer-2.5-fast"
zig-specialist = "grok-composer-2.5-fast"
zig-debug-specialist = "grok-composer-2.5-fast"
```

- Parent on **Grok 4.5:** orchestrate, design, review; delegate coding to
  `zig-specialist` / `zig-debug-specialist` unless the change is tiny.
- Parent on **Composer:** implement/debug; spawn design/review specialists for
  non-trivial design or full review passes.
- Model choice never skips `docs/`, coding standards, or `zig build verify`.
- Confirm with `grok models` and `grok inspect`.

---

## Cursor Agent CLI (secondary)

Cursor loads this file as project rules (`AGENTS.md` / `Agents.md`) and uses its
own harness paths:

| Path | Role |
|------|------|
| `.cursor/agents/zig-*.md` | Specialist prompts (same names as Grok) |
| `.cursor/skills/zig-workflows/` | Inline vs delegate; design / implement / debug / review |
| `.cursor/skills/zig-workflows/module-presets.md` | Multi-review unit tables (when used) |
| `.cursor/rules/*.mdc` | Auto-attach context for `src/game/**`, `src/render/**` |

**Shared with Grok (this file):** docs map, module ownership, working rules,
build/verify, bench≠test, same specialist roles and when to inline vs delegate.

**Cursor-specific:**

- Spawn via Cursor **Task / subagents** and `.cursor/agents/`, not Grok
  `spawn_subagent` or `.grok/skills/` slash commands.
- Multi-phase passes (pathfinder, architecture assessment, best-practices, deep
  correctness): follow `.cursor/skills/zig-workflows/` (and presets there). Grok
  multi-phase slash skills under `.grok/skills/` are for Grok Build sessions.
- Keep specialist **roles and contracts** aligned with this file when editing
  either agent tree; do not assume the two trees are auto-synced.

---

## Source of truth (`docs/`)

Read the owning doc before editing. Do not invent architecture from memory.

| Doc | Owns |
|-----|------|
| `docs/architecture.md` | Source layout, ownership, frame flow |
| `docs/coding-standards.md` | Zig style, performance, comments, tests |
| `docs/development-workflow.md` | Build options, shaders, packaging, ReleaseFast gate |
| `docs/setup.md` | Toolchain and SDL3 per platform |
| `docs/state-stack-and-input.md` | States, transitions, input routing |
| `docs/rendering-assets-shaders.md` | SDL_GPU rendering, resources, shaders |
| `docs/simulation-tiers-and-pipeline.md` | Fixed-step simulation contracts |
| `docs/atlas-asset-workflow.md` | Atlas packing, JSON sidecars, art swaps |
| `docs/framework-implementation-slices.md` | Live roadmap / open slices |
| `docs/framework-implementation-slices-archive.md` | Settled slices (0–8, 9–17, 18–25E, 26–32, 34, 36, 39–41) |
| `docs/changelogs/` | Per-branch feature summaries |
| `docs/reviews/` | Module deep-dives (pathfinder, GPU, …) |

---

## Module ownership (`src/`)

Add code under the module that owns the concern. Do not move ownership to make a
local change easier.

| Path | Owns |
|------|------|
| `src/main.zig` | Thin entry/timing: `AppConfig`, `Engine`, fixed-step loop |
| `src/config.zig` | `AppConfig`, presentation, clear color, thread defaults |
| `src/app/` | Engine, state stack, input + router, 60Hz time loop, frame pacer, pause, audio, thread system, resolution, perf log |
| `src/render/` | SDL_GPU facade (`renderer.zig`), camera, resources, sprite batch, text, debug. **Do not** import `src/render/gpu/*` outside render/platform |
| `src/assets/` | Catalog, safe paths, decode, cache, `manifest.zig` IDs, atlas metadata |
| `src/game/` | Gameplay states, `world_system`, `data_system/`, simulation pipeline/scope, player, dig/audio controllers, render_prep/depth, `systems/` (movement, ai, steering, collision, particles, perception, pathfinding). Pathfinding owns nav invalidation + post-commit nav reaction; state only invokes via pipeline |
| `src/core/` | Math, SIMD, logging |
| `src/platform/` | SDL imports, GPU smoke probe |
| `src/benchmarks/` | CPU gameplay, pathfinding, nav-update, scope, perception, render-prep benches |

---

## Working rules

- Read live owning files before editing. No stale roadmap/chat memory for details.
- Style: `docs/coding-standards.md` — `zig fmt`, camelCase functions, snake_case
  vars/fields, PascalCase types, direct declaration imports, explicit error sets.
- **Hot paths = allocation-free after init/reserve/warmup**, proven with
  `std.testing.FailingAllocator` (not comments). Ships **ReleaseFast** (strips
  `assumeCapacity` asserts). Avoid per-frame string lookups, hash-map dispatch,
  broad dynamic dispatch, formatted logging, resource churn unless measured and
  bounded.
- **Work budgets are fixed constants** — never scaled to world/map/cell/portal
  size. Grep `independent of` / `regardless of world size` before changing
  budgets. If a budget is chronically tight: graceful degradation or algorithm
  change under the **same** fixed budget — not a larger constant for one map.
- Threaded shared-buffer writes: disjoint per-worker ranges, reserve **before**
  dispatch. Allocators are init-time fields, never mid-function globals.
- Runtime asset paths: relative, traversal-safe. Persist stable IDs
  (`SpriteAssetId`, `AudioAssetId`), not paths or live GPU/SDL handles.
- Production APIs: runtime concepts only — no test-only tags, marker fields, or
  fixture hooks. Tests use private helpers, local fixtures, mocks, or real payloads.
- Slices ship complete: behavior + docs + tests + acceptance.
- Never edit `zig-out/` or `.zig-cache/`.
- **Tests:** smallest `WorldSystem`/`DataSystem` fixtures that still prove the
  behavior (`1x1` world ⇒ one chunk). Large worlds only for structural
  growth / reserve-proof tests.

---

## Build and validation

Gate: `zig build verify` before a slice or broad change is done.

```sh
zig build            # app + assets + shaders
zig build run        # build, install, run
zig build dev        # shaders + assets + run
zig build check      # compile coverage (no install)
zig build test       # unit tests (correctness only)
zig build bench      # perf / OOM benches only
zig build verify     # check + test + shaders + atlas + idiom-lint
zig build fmt        # format build.zig*, src/
zig build shaders    # GLSL → platform shaders
zig build gpu-smoke  # display-gated GPU smoke
zig build package    # release-mode install
zig build assets-lint
zig build idiom-lint
zig build fetch-sdl  # Windows SDL package cache
```

Default optimize: `Debug`. Use `--release=safe|fast|small` for release candidates
only. Packaged builds ship **ReleaseFast** — ReleaseSafe soak first (see
`docs/development-workflow.md`). Minimum toolchain: **Zig 0.16.0**.

### Agent working practices

- After edits: `zig build fmt`. Before finish: `zig build verify` (or targeted
  green first when debugging).
- Iterate with `zig build check`; use `zig build gpu-smoke` only for display/GPU.
- Search the owning module before adding utilities.
- Scope to the requested change — no drive-by refactors/reformats.
- Benches: always `zig build bench -- --group <name>` (optional `--case` /
  `--items`). Never run full bench suite and filter.
- **`test` ≠ `bench`:** no hand-rolled timing in tests (not even
  `-Doptimize=ReleaseFast`). No test code may call `src/benchmarks/*.zig`
  (except `suite.zig` pure utility tests). Correctness → small fixtures in the
  owning module; perf → add/extend a bench case.
