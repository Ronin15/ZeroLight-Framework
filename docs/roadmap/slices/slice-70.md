## Slice 70: Presentation Polish And Sprite Vertex Compaction

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 60](slice-60.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for **70A** (independent) and **70B** (after
Slices 60, 54, and 44). Both are render/app presentation work. Neither adds a
`SimulationPipeline` stage, `PipelineResource`, `Component` tag, `SeedDomain`,
persistent `DataSystem`/`WorldSystem` state, checksum field, or save section.

Goal:

- **70A:** cut the GPU vertex cost of a sprite from 192 B to 80 B. Use indexed
  quads over one static shared `u16` index buffer and a packed `UBYTE4_NORM`
  color stream. The game-facing renderer contract does not change.
- **70B:** close every presentation item Slice 60 deferred:
  - scene resolution as a runtime setting, with a renderer re-layout
  - default gamepad zoom bindings
  - fade-out before a state swap, holding the transition batch
  - a sharp-bilinear `world_pixel` composite at non-integer magnification
  - a drawable-mode zoom tween

**Why two sub-slices.** 70A is a hot-path change with no prerequisites. It is
verified by benchmarks and `gpu-smoke`, and it can land at any time. 70B
depends on three unlanded slices and is mostly cold app and settings work.
Landing them together would block the bandwidth win on the settings and input
tracks.

| Concern | Decision | Owner |
| --- | --- | --- |
| Quad topology | 4 vertices per quad, indexed `{0,1,2, 1,3,2}` over (TL, TR, BL, BR): exactly today's triangle list | 70A |
| Index buffer | One static `u16` buffer of `k_max_quads_per_indexed_draw = 16384` quads (196,608 B), built once at `Renderer.init` and never grown. Larger groups split into chunks via `vertex_offset`. | 70A |
| Vertex format | 3 SoA streams: `f32x2` position, `f32x2` uv, `UBYTE4_NORM` color, at 20 B/vertex and 80 B/sprite. Column bases aligned to 64 B. | 70A |
| Shaders | No GLSL change; committed artifacts and lock unchanged | 70A |
| Scene resolution | `VideoSettings.scene_resolution` (schema bump) plus `Renderer.setSceneResolution` cold re-layout | 70B |
| Pad zoom | R3 → `camera_zoom_in`, L3 → `camera_zoom_out`; `attack` → RT, `use_item` → LT | 70B |
| Fade-out | A replace batch is held and the outgoing stack frozen for `k_screen_fade_out_ns = 250 ms`, then the batch is applied and Slice 60's fade-in runs | 70B |
| Sharp-bilinear | Selected automatically in `world_pixel` when the magnification is non-integer; shares one composite pipeline, adds a fifth `CompositeParams` vec4 and a linear sampler | 70B |
| Zoom tween | `k_zoom_tween_steps = 12` fixed steps, ease-out cubic on the visible extent, drawable only, never touches `anchorRect()` | 70B |

### Cross-slice amendments (applied to the owning slices)

| Owner | Amendment |
| --- | --- |
| [60](slice-60.md) | Out-of-scope items point to 70B; `world_pixel` init error superseded by 70B's fallback; `drawGroupRange` binds 70A's index buffer; `CompositeParams` 80 B and coverage `+2`; fade `advance` at the top of `renderFrame`; tweened clamp replaces `captureZoomInput`'s re-clamp |
| [44](slice-44.md) | Pad defaults and the explicit-beats-default-fill loader behavior |
| [56](slice-56.md), [57](slice-57.md) | Interim stick-click pad defaults end at 70B (RT/LT) |
| [67C](slice-67c.md), [69E](slice-69e.md) | Thumbnails work in both scene modes; the presentation view rect uses the tweened zoom |

Cross-slice tables honored (Tables T1–T6 in the
[VoidLight port track](../tracks/voidlight-port.md)): no replay bit or
`replay_format_version` change, settings v5, no stage, no component tag, no
`checksum_format_tag` bump.
