## Slice 70: Presentation Polish And Sprite Vertex Compaction

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 60](slice-60.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) (70B only) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for **70A** (independent) and **70B**
(after 60, 54, and 44). Both are render/app presentation work: neither adds a
pipeline stage, `PipelineResource`, `Component` tag, `SeedDomain`, persistent
`DataSystem` / `WorldSystem` state, checksum field, or save section.

Goal:

- **70A:** cut a sprite's GPU vertex cost from 192 B to 80 B through indexed
  quads over a fixed shared index buffer and packed color, with no
  game-facing API change.
- **70B:** close the presentation items Slice 60 deferred: scene resolution as
  a runtime setting, default pad zoom bindings, fade-out before a state swap,
  sharp-bilinear `world_pixel` at non-integer magnification, and a drawable
  zoom tween.

**Why two sub-slices.** 70A is a hot-path change with no prerequisites,
verified by benches and `gpu-smoke`, and can land any time; 70B depends on
three unlanded slices and is mostly cold app and settings work.

| Concern | Outcome | Owner |
| --- | --- | --- |
| Sprite vertices | 4 indexed vertices per quad, packed 8-bit color, 80 B per sprite, triangles bit-identical | 70A |
| Index buffer | Fixed at init, independent of sprite count or scene size; large groups split into chunks | 70A |
| Shaders | No GLSL change; committed artifacts unchanged | 70A |
| Scene resolution | Persisted video setting applied live by a cold renderer re-layout | 70B |
| Pad zoom | Stick clicks zoom; attack and use move to the triggers | 70B |
| Fade-out | A replace batch is held and the outgoing stack frozen during the fade | 70B |
| Sharp-bilinear | Automatic in `world_pixel` at non-integer magnification | 70B |
| Zoom tween | Fixed-step, drawable only, never touches the simulation anchor | 70B |

Cross-slice tables honored (Tables T1–T6 in the
[VoidLight port track](../tracks/voidlight-port.md)): no replay bit or
replay format change, settings live + 1 (Table T2), no stage, no component
tag, no checksum tag bump.
