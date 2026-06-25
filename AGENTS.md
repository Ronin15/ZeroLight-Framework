# Repository Guidelines

## Purpose

This file is a concise agent contract for this Zig 0.16 + SDL3/SDL_GPU game
project. Do not duplicate full repo documentation here. Use the canonical docs
below for details and update those docs when architecture, workflow, or roadmap
content changes.

## Source Of Truth

- `docs/architecture.md`: durable architecture, source layout, ownership
  boundaries, frame flow, rendering boundary, gameplay data ownership, and
  simulation pipeline/tier direction.
- `docs/framework-implementation-slices.md`: roadmap sequencing, slice scope,
  checklists, and acceptance status.
- `docs/simulation-tiers-and-pipeline.md`: current `src/game/simulation.zig`
  contracts for `SimulationFrame`, range-output streams, simulation events, and
  structural commands.
- `docs/state-stack-and-input.md`: state contracts, transition policies, input
  routing, and action mapping.
- `docs/rendering-assets-shaders.md`: SDL_GPU rendering, renderer resources,
  shaders, texture loading, text, debug overlay, and render assets.
- `docs/atlas-asset-workflow.md`: atlas packing, JSON sidecars, order manifests,
  runtime atlas validation, and art swaps.
- `docs/coding-standards.md`: enforced Zig style, performance, comment policy,
  test standards, and generated-output rules.
- `docs/development-workflow.md`: build options, release modes, test commands,
  shader tools, packaging, and GPU smoke workflow.

## Agent Rules

- Read the live files that own the work before editing. Do not rely on stale
  roadmap memory or prior chat summaries for exact implementation details.
- Add new code under the owning module described by `docs/architecture.md`.
  Do not move ownership boundaries just to make a local change easier.
- Follow `docs/coding-standards.md` for Zig style, imports, performance,
  comments, logging, tests, generated-output rules, and production-contract
  boundaries. Log via `src/core/logging.zig` scoped loggers, never raw
  `std.log`/`std.debug.print`; hot paths stay log-free in release.
- Keep `src/main.zig` timing-centric, app/state flow under `src/app/`, rendering
  and GPU resource work under `src/render/`, runtime asset catalog/path work
  under `src/assets/`, and gameplay/data/systems under `src/game/`.
- Treat implementation slices as full features. Do not mark a slice complete
  until runtime behavior, docs, tests, and acceptance checks are integrated.
- Keep roadmap specifics in `docs/framework-implementation-slices.md`. Keep
  durable architecture guidance in `docs/architecture.md`. Keep agent workflow
  guidance in this file or repo-local `.codex/skills`, but only when it must
  guide future agents before they open the deeper docs.
- Scaffolding is valid only when it lands final owner modules, storage/defaults,
  validation, and tests while preserving current behavior. Do not document
  deferred runtime behavior as complete.
- Do not add test-only enum tags, union payloads, marker fields, fake stages,
  fixture hooks, or service paths to production contracts. Tests should use
  private helpers, local fixtures, test-only mocks, or real production payloads.
- Keep runtime asset paths relative and traversal-safe. Persistent gameplay data
  should use stable asset IDs, not string paths, live renderer handles, SDL
  handles, loaded audio handles, or prepared draw records.
- Keep hot paths allocation-free after initialization, reserve, or warmup. Avoid
  per-frame string lookup, hash-map dispatch, formatted logging, dynamic
  dispatch, or resource churn unless the cost is measured, bounded, and
  intentionally isolated.
- Do not edit generated output such as `zig-out/` or `.zig-cache/`.

## Validation

- Run `zig build verify` before considering a slice or broad cleanup complete.
- Use `zig build test` for focused non-display contract checks.
- Use `zig build check` for compile coverage without installing assets.
- Use `zig build bench` for non-interactive gameplay/render-prep benchmarks.
- Use `zig build gpu-smoke` only when a display/GPU validation is required.
- Use `zig build fmt` for Zig formatting.
