## Slice 60: Camera Behavior And Scene Composite Pass

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 49](slice-49.md), [Slice 54](slice-54.md), [Slice 70A](slice-70a.md) (zoom setting on 54; 70A index buffer when landed) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on Slice 49 (`sim_view` / `simViewRect()` contract).
It uses Slice 43's input layer (landed). Slice 59's grade and weather visuals consume
this slice's `SceneGrade`. Gamepad zoom binding belongs to Slice 44. Zoom persistence
is this slice's item on Slice 54's `SettingsStore`. After Slice 52A, the composite
shader artifacts are regenerated and committed.

Goal:

- Replace the snap-to-player camera with a **deterministic fixed-step camera rig**:
  - follow lag
  - dead zone
  - catch-up snap
  - world clamp that centers the view when the world is smaller than it
  - integer pixel-perfect zoom levels
  - seeded trauma shake
- Render it via interpolation alpha as presentation only.
- Feed Slice 49's `sim_view` from the rig's deterministic `anchorRect()`. The
  render-time window never reaches the simulation.
- Add a renderer **scene-texture plus composite pass**:
  - world-domain draws render offscreen, then composite to the swapchain with zoom,
    sub-pixel scroll in `world_pixel` mode, and a color grade (tint, haze, saturation,
    flash)
  - UI and debug draw after the composite, untinted
  - frames-in-flight-safe resource and uniform handling
- Add an app-level screen fade-in on state replacement.

### Current foundation (do not rebuild)

- `src/render/camera.zig:10-13`: `Camera2D { position (top-left world), zoom }`. There
  is no CPU transform. `renderer.zig:1566-1602` (`frameUniformForPresentation`) folds
  the camera into the `.world` vertex affine, so a pan uploads nothing. Keep this.
- `src/game/game_demo_state.zig:274-275, 547-549, 615-651`: the camera is stepped in
  the fixed step as `camera_previous` / `camera_current`. It is lerped by
  `interpolation_alpha` in `render` (`:566-575`). `cameraForPlayer` snaps to the player
  (no lag) and clamps the top-left to `[0, bounds - view]`, pinning to 0 when the world
  is smaller.
- `src/app/time_loop.zig:58-61` provides `interpolationAlpha`. `engine.zig:352-360`
  passes it into `RenderContext`.
- Slice 49 routes sim scope through `SimulationPipelineUpdateContext.sim_view`.
  `GameDemoState.simViewRect()` derives it from `camera_current` today, and
  `SimulationPipeline.simViewRegion(context)` is the single scope-band reader
  (`stageTierPolicy`, Slice 55 `ai_decide_gather`, Slice 62 `population_update`).
  `setVisibleChunksForWorldRect` / `visibleChunkRegion` are render-only after 49.
- `src/render/renderer.zig:669-832` (`endFrame`): one swapchain render pass (CLEAR),
  one loop over the merged draw list. `mergeDrawList` (`:1477-1492`) stable-sorts by
  `(domain, depth)`, so all `RenderDomain.world` groups (`sprite_batch.zig:45-49`) are
  contiguous and first. The debug overlay draws `.world`-space debug-domain viz
  (`ai_debug_overlay.zig:379,428`) and `.drawable` text. Menus and pause use the `.ui`
  domain with `.logical` space.
- `src/render/gpu/device.zig:55-67` provides a nearest / clamp-to-edge sampler
  (reusable). `:36-50` sets swapchain SDR composition.
- `docs/rendering-assets-shaders.md:331-357` defines the `cycle` policy ("fully
  re-staged each frame → cycles"). `:30-51` lists the add-a-material steps. `:507-559`
  covers binding rules and `msl_entry_signature`. `sprite_batch.zig:183-216` is the
  extern-uniform layout assert pattern plus the GLSL-parse test pattern.
- `renderer.zig:196-212` holds the headroom constants and comptime assert. The proof
  test "engine overlay top-up after stacked UI fully consumes its headroom stays
  allocation-free" is at `:2360`.
- `src/app/state.zig:58-60` (`TransitionApplyResult { quit_requested }`).
  `engine.zig:460-475` (`applyTransitions`).
- `src/app/input.zig:9-26, 35-53, 188-200`: the `Action` enum, key bindings, and the
  gameplay/command classifiers.

### Architecture notes

**Camera rig (presentation state, deterministic fixed-step update).**

- `src/render/camera.zig` gains `CameraRigConfig` and `CameraRig`: pure value types
  with no allocator and no SDL. The gameplay state owns one and steps it in its fixed
  `update`, after `pipeline.update`. `Camera2D` keeps its meaning (top-left plus zoom).
  The rig stores a **center** and produces a `Camera2D` at the end.
- `CameraRigConfig`:
  - `view_size: Vec2` is the logical size, in world px at zoom 1.
  - `follow_lag_seconds: f32 = 0.15`. 0 = snap, today's behavior. Tests use 0 for
    parity.
  - `dead_zone_radius: f32 = 4`
  - `max_catchup_distance: f32 = 480`
  - `zoom_levels: [k_max_zoom_levels = 8]u8 = {1,2,3,4,…}`, `zoom_level_count: u8 = 4`,
    `default_zoom_index: u8 = 0`
  - `validate()` returns `error.InvalidCameraConfig` unless: values are finite and
    non-negative, zoom levels are strictly ascending integers ≥ 1, and the index is in
    range.
  - Zoom levels are always integers, in both scene modes: pixel-perfect by
    construction, and no zoom-out below 1. The visible area therefore never exceeds
    today's zoom-1 window, so render reservations and the scope anchor are unchanged.
- The rig keeps **two independent centers**:
  - the **sim anchor** (`anchor_min: Vec2`), a pure function of the fixed-step target
    and the world bounds at `zoom_levels[0]`. No lag, dead zone, `exp`, shake, trauma,
    current zoom, alpha, or other camera-feel tunable feeds it.
  - the **presentation center** (`center_previous`, `center_current`), which carries
    every camera-feel term.
- `CameraRig` state:
  - `anchor_min: Vec2` (top-left of the sim anchor rect)
  - `center_previous`, `center_current`
  - `follow_factor` (precomputed once at init as
    `math.expSmoothingFactor(TimeLoop.fixed_delta_seconds, lag)` = `1 - exp(-dt/lag)`;
    a new core helper with tests; 1 when lag is 0). Presentation only.
  - `zoom_index`, `zoom_in_held_last`, `zoom_out_held_last`
  - `bounds: { min, max }`
  - `trauma: f32`, `shake_previous`, `shake_current: Vec2`, `shake_step: u32`
- `step(target_center)` runs in this order:
  1. **Sim anchor first**, from `target_center` only:
     - per axis, `half0 = view_size / (2 * zoom_levels[0])`;
     - if the world extent is at least `2 * half0`:
       `anchor_min = clamp(target_center - half0, bounds.min, bounds.max - 2 * half0)`;
     - otherwise `anchor_min = (bounds.min + bounds.max) / 2 - half0` (centered).
     This is today's `cameraForPlayer` arithmetic in top-left form
     (`game_demo_state.zig:639-651`), so for a world at least as large as the zoom-1
     view it is bit-identical to Slice 49's pre-60 `simViewRect()`. Only IEEE
     `+ − × ÷` and min/max are involved.
  2. Presentation: catch-up snap if the distance exceeds `max_catchup_distance`.
  3. Presentation: dead zone hold.
  4. Presentation: exponential follow `center += (target - center) * follow_factor`.
  5. Presentation: clamp the center to `[min + view/2z, max - view/2z]` at the current
     zoom, or center on the world per axis when the world is smaller than the view
     (VoidLight behavior).
  6. Decay trauma by `k_shake_trauma_decay_per_step = 1.6/60`.
  7. Sample shake: `trauma² * k_shake_max_offset_px (8) * (2u-1)` with two explicit
     draws, `u_x = rng.uniformF32(k_camera_shake_seed, 0, shake_step, k_shake_salt_x)`
     and `u_y = rng.uniformF32(k_camera_shake_seed, 0, shake_step, k_shake_salt_y)`.
     This is a fixed constant seed and presentation only (Slice 49 names camera shake
     as an exemption from session seeding).
- `captureZoomInput(input)`: rising-edge latch on new gameplay actions `camera_zoom_in`
  / `camera_zoom_out`. A zoom change snaps (no tween; Slice 70B adds the
  drawable zoom tween and replaces this re-clamp with a per-step tweened
  clamp), re-clamps the presentation center, and sets `center_previous = center_current` so there is no slide at
  mismatched zoom. It never touches `anchor_min`.
- `renderCamera(alpha) Camera2D`: lerp center, add the lerped shake, then clamp the
  shaken center again (the rendered view never leaves the world). Top-left is
  `center - view/(2z)`; zoom is `@floatFromInt(level)`. Alpha, wall clock and frame
  count enter **only here**.
- `anchorRect() Rect` gives the sim-scope anchor: `{ anchor_min, view_size /
  zoom_levels[0] }`.
  - It is invariant under zoom index, trauma, shake, alpha, lag, dead zone and
    catch-up **by construction**, including at the world edges (the edge clamp uses
    `zoom_levels[0]`, never the current zoom).
  - With min zoom 1 it is exactly the zoom-1 view rect around the player, so
    battle-scale scope counts are unchanged.
  - With lag > 0 the rendered view trails the anchor by at most
    `max_catchup_distance` (480 px). Everything rendered therefore stays inside the
    anchor's cognition band (`cognition_halo_chunks = 16`, at least 512 px even at one
    tile per chunk), so nothing on screen is unsimulated. A test pins this bound.
- `syncPrevious()` (pause/resume; removed by Slice 64A's alpha hold if it has no
  other caller — see the Slice 64 Checklist addition) and `snapTo(center)` (init and
  teleport; sets both the presentation center and `anchor_min`).
- `addTrauma(amount)`: saturating, clamped to `[0,1]`.

**Sim-scope anchor.** `GameDemoState.simViewRect()` returns `camera_rig.anchorRect()`.
Nothing changes in `WorldSystem`, `PipelineResource`, or `stageContract`: Slice 49 owns
the `sim_view` input and the `simViewRegion` helper, and this slice only changes the
body of `simViewRect()`. No second anchor store or `PipelineResource` is added.

- `GameDemoState.update` order (fixed step):
  1. input phase: `camera_rig.captureZoomInput`
  2. `pipeline.update`
  3. particles
  4. trauma from this step's events:
     - `destructible_destroyed` → `0.3 * clamp(1 - dist/(0.75*view_w), 0, 1)`
     - Slice 59 `lightning_strike` → 0.25
  5. `camera_rig.step(playerCenter)`
  6. (no world call; the next step passes `.sim_view = self.simViewRect()`)
  7. structural commit
- The next step's scope reads the anchor through Slice 49's `sim_view`.
  `initWithWorld` calls `snapTo` so step 1 already has an anchor.
- **Spatial-index dense window (capacity audit; `src/game/systems/spatial_index.zig`).**
  `max_dense_window_side_cells`' doc comment defers its sizing to the min-zoom
  decision this slice makes: zoom levels are integers ≥ 1 and the sim anchor is
  the zoom-1 view, so the indexed population never spans more than the cognition
  band around `anchorRect()`. `SpatialIndexSystem.reserve` therefore sizes the
  window per axis from the loaded config and world, not from fixed constants:
  - `band_px = (ceilDiv(anchor_extent_px, chunk_px) + 1 + 2 *
    cognition_halo_chunks) * chunk_px`, with `anchor_extent_px = view_size /
    zoom_levels[0]` and `chunk_px = chunk_size_tiles * tile_size`;
  - `window_cells = min(ceil(world_extent_px / cell_size), ceil(band_px /
    cell_size) + 1)`.

  `DenseWindowGeometry` gains `sim_view_extent` and `world_extent` (set by the
  pipeline from the rig config and the loaded world), the lookup becomes
  non-square (`capacity_cells_x` / `_y`), and `max_expected_visible_window_cells`
  and `max_dense_window_side_cells` are deleted. The clamp-and-skip in
  `buildEntriesAndRanges` stays as the ReleaseFast guard, now counted
  (`SpatialIndexStats.dense_window_clamped`, perf metric
  `spatial_dense_window_clamped`, one `warn` per session).

**Scene composite pass (render-owned).**

- Modules:
  - `src/render/scene_composite.zig` (pure, headlessly testable)
  - `src/render/gpu/scene_target.zig` (texture create/release/format check)
  - `src/render/gpu/composite_pipeline.zig` (pipeline)
  - `assets/shaders/composite.{vert,frag}.glsl`, registered in `build.zig`
    `shader_programs` with exact `msl_entry_signature`s copied from the generated
    `.msl`
- Game code only calls `Renderer.setSceneGrade(SceneGrade)`. No SDL or GPU handles cross
  the boundary.
- `SceneResolution = enum { drawable, world_pixel }` in `AppConfig.scene_resolution`
  (default `.drawable`). Build option `-Dscene-resolution=drawable|world_pixel` feeds
  `main.zig`. The runtime toggle is Slice 70B (runtime scene resolution).
  - **`.drawable`** (default):
    - The scene texture is the presentation viewport size in drawable pixels. The
      scene pass uses today's transforms with the viewport origin moved to (0,0):
      zoom stays in the vertex affine.
    - The composite is a 1:1 nearest copy plus grade.
    - **Bypass rule:** when `grade.isNeutral()` (exact compare), `endFrame` runs
      today's single-pass path unchanged. Menus, loading, and Slice-60-without-59
      therefore cost nothing and are byte-identical.
  - **`.world_pixel`** (pixel-perfect):
    - Allocated once at `Renderer.init`, the scene texture holds
      `(logical_w + 2) × (logical_h + 2)` texels at one texel per world pixel. That is
      the zoom-1 view plus a one-texel margin per side.
    - The scene pass uses `cam_floor = floor(camera.position)` with transform
      `scale 1, offset -cam_floor` and covers `ceil(view/z)+1` texels.
    - The composite samples the nearest sub-rect:
      - `uv_rect = (frac.x/tex_w, frac.y/tex_h, (view_w/z)/tex_w, (view_h/z)/tex_h)`
      - with `frac = camera.position - cam_floor`
    - Result: integer zoom magnification plus smooth sub-pixel scroll at output
      resolution.
    - Always composites, neutral grade included.
    - Use integer-fit scale mode for even pixel widths (Slice 70B sharp-bilinear).
- `SceneGrade` (game-facing, `scene_composite.zig`):
  - `multiply: [3]f32 = {1,1,1}`
  - `haze: config.Color = {0,0,0,0}` (a = amount)
  - `saturation: f32 = 1`
  - `flash: f32 = 0`
  - `isNeutral()` and `lerp()`
  - `Renderer.beginFrame` resets the grade to neutral, so only a state that sets it
    gets it.
- `CompositeParams` is an extern struct, 64 B, std140, four `[4]f32` (Slice 70B
  grows it to 80 B and the scene-pass coverage to `+2`):
  - `uv_rect` (xy origin, zw size, normalized)
  - `multiply` (rgb, w unused)
  - `haze` (rgb, a amount)
  - `adjust` (x saturation, y flash, z grade_active 0/1, w unused)
  - Comptime `@sizeOf` / `@offsetOf` asserts, plus a test that embeds
    `composite.frag.glsl` (build.zig test import, like the tilemap layer test) and
    asserts the block declares exactly these four `vec4` in order.
- Shader:
  - `composite.vert` is the VoidLight fullscreen triangle from `gl_VertexIndex`:
    `uv = uv_rect.xy + vec2(p.x, 1-p.y)*uv_rect.zw`. No vertex buffers, no vertex
    uniform.
  - `composite.frag`:

    ```
    c = scene.rgb
    if grade_active == 0: out = (c, 1)
    else:
      c *= multiply
      c = mix(luma709(c), c, saturation)
      c = mix(c, haze.rgb, haze.a)
      c += flash
      out = (clamp(c), 1)
    ```

  - With `grade_active == 0` the output is an exact pass-through.
  - Bindings follow the doc rules: fragment sampler set 2 binding 0, fragment uniform
    set 3 binding 0.
  - Pipeline: swapchain color format, blend off, zero vertex buffers.
- **`endFrame` flow when compositing:**
  1. prepare + merge (unchanged)
  2. `world_end = std.sort.partitionPoint(... group.order.domain == .world)`
  3. copy pass (unchanged)
  4. **scene pass**:
     - color target = scene texture, `LOADOP_CLEAR` (clear color), `STOREOP_STORE`,
       **`cycle = true`**
     - viewport = full scene texture, scissor = the content rect
     - draw groups `[0, world_end)` with scene-target frame uniforms. A pure
       `scene_composite.sceneFrameTransform(layout, presentation, camera)` covers
       `.world`, `.logical` and `.drawable`, so any space is legal in either pass.
  5. **swapchain pass**:
     - CLEAR (letterbox color)
     - viewport = presentation viewport
     - bind the composite pipeline, scene texture and nearest sampler
     - push `CompositeParams`
     - `SDL_DrawGPUPrimitives(3,1,0,0)`
     - restore the full-drawable viewport
     - draw groups `[world_end, len)` with today's swapchain uniforms
- The group loop becomes `drawGroupRange(pass, cmd, groups, target)`, called per pass.
  It binds Slice 70A's quad index buffer per pass when 70A has landed (70A is before
  60 in the merged order).
  Its `active_*` binding trackers are per call, because bindings and uniforms do not
  persist across render passes.
- Debug world-space viz in the swapchain pass uses the same float render camera. In
  `.drawable` it lines up exactly with the composited image (1:1 copy). In
  `.world_pixel`, nearest sampling of the scene texture places each world point within
  ±½ texel × zoom output pixels of the swapchain `.world` transform; the mapping test
  asserts that tolerance.
- **Frames-in-flight safety:**
  - The scene texture is fully rewritten each frame (CLEAR), so it takes `cycle = true`.
    Add the row to the cycle-policy table. SDL rotates to an unbound backing texture
    while a prior frame still samples it.
  - Write and sample within one command buffer get SDL's inter-pass barrier.
  - `CompositeParams` is pushed with `SDL_PushGPUFragmentUniformData`, which copies into
    SDL's per-command-buffer uniform storage. The source is a stack local. There is no
    renderer-owned uniform buffer to cycle or fence.
- **Scene texture lifetime:**
  - Format = `SDL_GetGPUSwapchainTextureFormat`, so the existing sprite and tilemap
    pipelines render into it unchanged.
  - Usage `COLOR_TARGET | SAMPLER`, checked with `SDL_GPUTextureSupportsFormat` at init:
    - unsupported in `.drawable` → log `warn` once and treat grading as disabled
      (always bypass)
    - unsupported in `.world_pixel` → `error.SceneTargetFormatUnsupported`
      (superseded by Slice 70B's startup fallback)
  - `.drawable` uses **grow-only** sizing, rounded up to `k_scene_target_grow_bucket_px = 256`.
    Growth happens in the **pre-acquire** block from the drawable probe, using the
    tile-edit-transfer pattern (create new → `waitForIdle` → release old), so a resize
    stall never holds an acquired swapchain. If the acquired presentation still
    outgrows the texture (resize race), that frame bypasses.
  - Dimensions above `k_max_scene_target_dimension = 8192` bypass, with one `warn`.
  - Released in `deinit` after `waitForIdle`.
- **Screen fade (fade transitions).**
  - Fades are **not** a composite term. The composite runs before UI, so it could never
    cover menus or HUD.
  - `src/app/screen_fade.zig`: `ScreenFade { remaining_ns, duration_ns = k_screen_fade_in_ns (350 ms), color = black }`
    with `startFadeIn`, `advance(frame_delta_ns)` and linear `alpha()` (Slice 70B
    moves `advance` to the top of `renderFrame`). It is
    presentation-only and runs on the wall clock. Sim never reads it.
  - `TransitionApplyResult` gains `replaced: bool`. `Engine.applyTransitions` calls
    `startFadeIn` when it is set.
  - `Engine.renderFrame` submits one `.logical` full-logical rect at new
    `RenderOrder.screenFade()` = `{ .domain = .ui, .depth = maxInt(i32) }`. It is
    submitted after stacked states render and before the debug overlay, so it sits above
    every `uiInStack` depth and below debug.
  - New `Renderer.k_post_state_command_headroom = k_overlay_command_headroom +
    k_screen_fade_command_headroom (1)`. Reserve:
    `reserveSpriteCommands(count + k_post_state_command_headroom)`.
    `k_stacked_state_ui_headroom` goes 32 → 40, and the comptime assert becomes
    `>= 2 * k_post_state_command_headroom`. Slice 53B's per-screen reserve formula
    references `k_post_state_command_headroom`; whichever of 53B and 60 lands second
    edits the other's reserve site.
  - Fade-out-then-swap (holding transitions) is Slice 70B.
- Input:
  - `Action.camera_zoom_in` (`SDLK_EQUALS`) and `camera_zoom_out` (`SDLK_MINUS`) are
    classified by `isGameplayAction`, so they are routed only under gameplay policy.
  - They take Slice 49's reserved replay bits 10 (`camera_zoom_in`) and 11
    (`camera_zoom_out`) in the pinned `held_gameplay_bits: u16` table, appended in the
    same change. Zoom never reaches the sim (the anchor ignores it), but replay still
    reproduces the presentation.
  - No gamepad default here (Slice 70B sets the R3/L3 defaults).
  - The `actionForKey` table tests are extended.
- Zoom persistence: `VideoSettings.zoom_index: u8` on Slice 54's `SettingsStore`
  (validated `< zoom_level_count`), a schema bump by one with the
  `upgradeVNToVN+1` step this slice adds. The rig reads it at init as its starting
  `zoom_index`; a zoom change writes it back through the store's normal dirty path.
- Fixed constants, classified (coding-standards § Budgets, Capacities, And Thresholds):
  - `k_max_zoom_levels = 8`: format (the inline `zoom_levels` array;
    `zoom_index: u8`)
  - `k_shake_max_offset_px = 8`: presentation tuning amplitude, not a cap
  - grow bucket 256: rounding of the `.drawable` scene texture, a capacity
    sized from the drawable (grow-only)
  - max dimension 8192: format/hardware (the guaranteed GPU texture
    dimension); larger bypasses with one `warn`
  - the `world_pixel` texture is a capacity sized from the logical size at
    `Renderer.init`
  - the spatial-index dense window is a capacity sized from the anchor extent
    and the world (Sim-scope anchor above)
  - Nothing scales with world size except where a capacity is sized from the
    loaded world.
- Diagnostics:
  - `render` scope `debug` on scene-target create and grow (cold), one-shot `warn` on
    bypass fallback.
  - `game` `debug` on zoom change (input edge).
  - Comptime-gated perf metrics `scene_composite_frames`, `scene_target_regrows`.
  - No per-frame logging.
- Out of scope:
  - camera rotation
  - VoidLight `Free` / `Fixed` modes (no consumer)
  - zoom tween, runtime scene-mode switch, fade-out, and sharp-bilinear upscale:
    Slice 70B

### Checklist

- [ ] `src/core/math.zig`: `expSmoothingFactor(dt, time_constant)` with tests
      (0 → 1, monotonic, `dt == tc` ≈ 0.632).
- [ ] `src/render/camera.zig`: `CameraRigConfig` (validate), `CameraRig`
      (`step` / `captureZoomInput` / `renderCamera` / `anchorRect` / `addTrauma` /
      `syncPrevious` / `snapTo`), the separate zoom-1 sim anchor, constants and the two
      shake salts.
- [ ] `src/app/input.zig`: zoom actions, key bindings, gameplay classification, tests.
      Routing tests in `input_router.zig` for all four policies. Append the pinned
      replay bits 10/11 (Slice 49 table).
- [ ] `simViewRect()` returns `camera_rig.anchorRect()`. Test: `sim_view` equals
      `anchorRect()` every step and is invariant under zoom index, trauma, and alpha.
- [ ] (capacity audit) `spatial_index.zig` dense window sized by the band formula
      (Sim-scope anchor); delete `max_expected_visible_window_cells` and
      `max_dense_window_side_cells`; `dense_window_clamped` stat, metric and
      warn-once. Tests (minimal fixtures): the reserved `capacity_cells_x/_y`
      equal the formula for geometry inputs larger and smaller than the band (no
      world built); a population filling the band at every zoom index builds
      with `dense_window_clamped == 0`; a `std.testing.FailingAllocator` proof
      runs a serial and a real multi-worker build of a band-filling population
      after `reserve` with zero allocations.
- [ ] Zoom setting: `VideoSettings.zoom_index: u8` (validated `< zoom_level_count`), a
      schema bump by one with `upgradeVNToVN+1`, and the rig reads it at init.
- [ ] `game_demo_state.zig`: replace `camera_previous` / `camera_current` /
      `cameraForPlayer` with `camera_rig`. Fixed-step order as above. Trauma mapping from
      `destructible_destroyed`. `onPause` / `onResume` do not resync the rig (Slice
      64A alpha hold; see the item below). Demo config
      (lag 0.15, dead zone 4, catch-up 480, zooms {1,2,3,4}).
- [ ] `src/render/scene_composite.zig`: `SceneResolution`, `SceneGrade`,
      `CompositeParams` (asserts), `SceneLayout` (both modes), `sceneFrameTransform`, the
      world-domain split helper, grow-bucket math, bypass decision.
- [ ] Shaders `composite.vert/frag.glsl` plus the `build.zig` `shader_programs` entry
      with `msl_entry_signature`s, plus the GLSL block-parse test import.
- [ ] Run `zig build shaders-update` and commit the composite SPIR-V/MSL/DXIL plus the
      lock, so `verify`'s stale-lock gate (Slice 52A) passes. Without local dxc, use
      52C's shader-artifacts job output.
- [ ] `src/render/gpu/scene_target.zig` and `src/render/gpu/composite_pipeline.zig`.
- [ ] `renderer.zig`:
      - fields (composite pipeline, scene target, mode, grade)
      - `setSceneGrade`, plus the neutral reset in `beginFrame`
      - pre-acquire grow
      - two-pass `endFrame` with `drawGroupRange` (binding the 70A quad index
        buffer per pass when 70A has landed)
      - bypass path
      - `deinit` order
- [ ] `sprite_batch.zig`: `RenderOrder.screenFade()`, plus ordering tests against max
      `uiInStack` and debug.
- [ ] `src/app/screen_fade.zig`. `state.zig` `TransitionApplyResult.replaced`. `engine.zig`
      fade start, submit and advance. Headroom constants
      (`k_post_state_command_headroom`), assert and proof-test extension.
- [ ] `src/config.zig` `scene_resolution` (validated), the `build.zig` option, and
      `main.zig` wiring.
- [ ] `src/platform/gpu_smoke_impl.zig`:
      - **drawable**: a bypass frame, then a non-neutral-grade frame with a ui-domain
        rect plus a debug `.world` rect after the composite, then a forced regrow via
        `SDL_SetWindowSize`.
      - **world_pixel**: re-init the renderer; render at a fractional camera and zoom 2
        with a neutral and a non-neutral grade.
      - `gpu_debug` stays on.
- [ ] (added by Slice 64) `GameDemoState.onPause`/`onResume` do not call
      `CameraRig.syncPrevious()` or `snapTo` (64A alpha hold). `render`
      passes 64A's held alpha into `camera_rig.renderCamera(alpha)`. Remove
      `syncPrevious()` if it has no other caller.
- [ ] (added by Slice 64) Test: `anchorRect()` and the presentation centers are unchanged by
      `onPause`/`onResume`.
- [ ] (added by Slice 67; if this lands after Slice 67E) New UI and
      event-log text as `StringId`s with English `StringSpec`
      entries in `src/assets/strings.zig`, value-bearing text through
      `strings.format`; 67E's comptime table validation passes.
      Otherwise 67E migrates it.
- [ ] Docs:
      - `docs/rendering-assets-shaders.md`: scene composite section, modes, `SceneGrade`,
        cycle-table row, composite material steps, screen fade order.
      - `docs/architecture.md`: camera rig ownership; the rig's zoom-1 anchor as the
        source of Slice 49's `sim_view`, separate from the presentation center.
      - `docs/state-stack-and-input.md`: zoom actions; fade-in on replace.
      - `docs/development-workflow.md`: `-Dscene-resolution`.

### Acceptance checks

- [ ] Rig pure tests:
      - lag 0 reproduces the old `cameraForPlayer` (including zoom 1 clamp, with
        centering replacing pin-to-0 for small worlds; update that expectation
        deliberately)
      - follow factor
      - dead-zone hold
      - catch-up snap
      - clamp and centering
      - zoom bounds and edge latch
      - shake determinism, decay to exactly zero, and exclusion from `anchorRect`
      - `anchorRect` invariant under zoom index, trauma, alpha, lag, dead zone and
        catch-up, including an **edge-of-world test**: the player pressed against
        each world edge, stepped at zoom 1 vs zoom 4, gives bit-identical
        `anchorRect()` sequences
      - with a world at least as large as the view, `anchorRect()` is bit-identical to
        the pre-slice `simViewRect()` for the same player positions
      - the rendered view stays within `max_catchup_distance` of the anchor
- [ ] Composite pure tests:
      - `SceneLayout` UV and transform for both modes (fractional camera, zoom 1–4)
      - a world point maps to the same output pixel through the scene+composite path as
        through the swapchain `.world` transform: exactly in `.drawable`, within
        ±½ texel × zoom in `.world_pixel`
      - domain split index
      - grow-only bucketing and max-dimension bypass
      - neutral detection and bypass table
      - `CompositeParams` layout plus GLSL parse
- [ ] With neutral grade in `.drawable`, the `endFrame` CPU path is the pre-slice path
      (bypass covered by test). The existing renderer, sprite-batch and
      overlay-headroom `FailingAllocator` proofs still pass. The extended proof covers
      the fade rect.
- [ ] `zig build gpu-smoke` passes both modes with SDL GPU validation clean.
- [ ] Manual run:
      - lagged follow with no idle shimmer
      - zoom 1–4 snaps with the clamp held
      - shake on destructible destroy
      - pixel-perfect smooth scroll in `-Dscene-resolution=world_pixel` with integer fit
      - UI and FPS overlay untinted
      - fade-in on menu → gameplay
- [ ] (capacity audit) No fixed spatial-index window constant remains (grep), the
      window is a pure function of the rig config and world extent, and
      `zig build bench -- --group ai` and `--group perception` stay within noise.
- [ ] `zig build bench -- --group render-game-prep` shows no CPU regression from the
      draw-list split or rig. (Render-cadence independence of sim scope is Slice 49's
      test "simulation scope region ignores the render visibility window"; this slice
      keeps it passing.)
- [ ] `zig build verify` passes.

### VoidLight reference

**Port (re-architected):**

- Follow-lag time constant, dead zone and catch-up snap:
  `include/utils/Camera.hpp:41-85`, `src/utils/Camera.cpp:69-122`.
- Clamp with center-when-smaller: `Camera.cpp:441-466, 283-310`.
- Integer zoom levels: `Camera.hpp:65-67`, `Camera.cpp:551-566`.
- Shake as a decaying offset: `Camera.cpp:401-412, 74-83`.
- Fixed-step previous/current camera with render-alpha blend: `Camera.cpp:70-72, 313-327`.
- Scene texture plus composite pass with UI drawn to the swapchain afterward:
  `include/gpu/GPURenderer.hpp:143-172, 214-219`, `src/gpu/GPURenderer.cpp:321-412, 656-700`.
- Floor plus sub-pixel offset: `src/utils/GPUSceneRecorder.cpp:47-63`.
- Fullscreen-triangle composite and ambient tint:
  `res/shaders/composite.vert.glsl:1-11`, `composite.frag.glsl:1-26`.

**Do not port:**

- `mutable std::mt19937 m_shakeRng{std::random_device{}()}` (`Camera.hpp:480-481`).
- The shake "fade" `1 - r/(r+0.1)` (`Camera.cpp:483`), which is not a real envelope.
- Camera events through the global `EventManager` (`Camera.cpp:523-547`). Presentation
  emits no sim events.
- `weak_ptr<Entity>` targets and `Free`/`Fixed` modes (no consumer).
- `cycle=false` on a per-frame render target (`src/gpu/GPUTexture.cpp:103`).
- Scene texture recreated at exact viewport size on every resize
  (`GPURenderer.cpp:938-960`).
- Zoom as `uv / zoom` anchored at the top-left (`composite.frag.glsl:18`).
- Sub-pixel offset normalized by viewport, not texture, size (`GPUSceneRecorder.cpp:58-59`).
- Renderer singleton pushed from controllers (`DayNightController.cpp:149-157`).
- `-ffast-math` (`CMakeLists.txt:56,64`).

