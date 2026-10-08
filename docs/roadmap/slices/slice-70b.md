## Slice 70B: Presentation Polish (Runtime Scene Resolution, Pad Zoom, Fade-Out, Sharp-Bilinear, Zoom Tween)

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 60](slice-60.md), [Slice 54](slice-54.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** After Slice 60, Slice 54, and Slice 44:

- **Slice 60** supplies `CameraRig`, `scene_composite.zig`, `SceneResolution`,
  `CompositeParams`, `ScreenFade`, `TransitionApplyResult.replaced`, the
  `camera_zoom_in`/`camera_zoom_out` actions, and `VideoSettings.zoom_index`.
- **Slice 54** supplies `SettingsStore`, `VideoSettings`, the `choice` widget,
  and `applyPendingSettings`.
- **Slice 44** supplies `PadInput`, `RuntimeInputBindings`, the binding load
  path, and the Controls screen.

`composite.frag.glsl` changes, so its committed artifacts and lock are
regenerated through 52A's `zig build shaders-update`. Without a local `dxc`,
use 52C's `shader-artifacts` job output. The trigger rows for `attack` and
`use_item` apply if Slices 56 and 57 have landed; otherwise those slices take
the triggers directly (see the Checklist's cross-slice amendments).

Goal:

1. `scene_resolution` (`drawable` / `world_pixel`) becomes a persisted video
   setting that applies live through a cold renderer re-layout.
2. The zoom actions get default pad bindings, as part of one final
   trigger/stick-click layout.
3. A replace batch fades the screen to black before the swap, with the
   outgoing stack frozen.
4. `world_pixel` gets no uneven-texel shimmer at non-integer magnification,
   via sharp-bilinear sampling.
5. Zoom changes tween over 12 fixed steps in drawable mode.

None of this touches Slice 49's `sim_view` or the checksum.

### Current foundation

- **Live code:**
  - `src/app/engine.zig`:
    - `handleEvents` (`:209-255`) polls, delivers events to the stack,
      routes them, then calls `applyTransitions`.
    - `applyFrameControls` (`:263-291`).
    - `update` (`:293-323`) runs states, then `applyTransitions` and the
      audio drain.
    - `renderFrame` (`:325-398`) feeds `interpolation_alpha` into
      `RenderContext`.
    - `applyTransitions` (`:460-475`).
  - `src/app/state.zig`:
    - `TransitionApplyResult` (`:58-60`).
    - `StateTransitions` (`:184-313`): a FIFO request queue (`replace`,
      `push`, `remove`, `pop`, `quit`) with a hard `max_requests`.
    - `StateStack.applyTransitions` (`:535-591`), where `replace` destroys
      the whole stack (`:613-624`).
  - `src/main.zig:25-46` is the fixed loop:
    `while (time_loop.shouldUpdate()) engine.update(...)`, then
    `renderFrame`.
  - `src/app/time_loop.zig:22-58`: the accumulator, at most 5 updates per
    frame, and `interpolationAlpha`.
  - `src/app/pause_controller.zig:56-141`: `reconcileWithStateStack` drops a
    pause handle whose state left the stack, and `enterPolicy` pushes
    `PauseState` directly.
  - `src/app/input.zig:9-26` is the `Action` enum, and `:61-74` is
    `default_gamepad_bindings`. That table maps SOUTH, EAST, WEST, NORTH,
    START, BACK, the D-pad, and both shoulders. `LEFT_STICK` and
    `RIGHT_STICK` are free today.
  - `src/app/resolution.zig`:
    - `computeViewport` (`:89-100`)
    - the `integer_fit` scale is `max(1, floor(fit))`, so `scale_x` is an
      exact integer (`:177-179`)
    - `fit`, `stretch`, and `overscan` give non-integer scales
  - `src/render/gpu/device.zig:54-67`: the nearest / clamp-to-edge sampler.
- **Slice 60 (section "Slice 60: Camera Behavior And Scene Composite Pass"):**
  - The rig keeps `center_previous`/`center_current` and the presentation
    clamp `[min + view/2z, max - view/2z]`.
  - `captureZoomInput` snaps the zoom and sets
    `center_previous = center_current`.
  - `renderCamera(alpha)` re-clamps the shaken center.
  - `anchorRect()` uses `zoom_levels[0]` only.
  - `SceneResolution` lives in `AppConfig.scene_resolution`, from
    `-Dscene-resolution`; "a runtime toggle is out of scope".
  - In `world_pixel`, the scene texture is `(logical_w + 2) × (logical_h + 2)`,
    the scene pass covers `ceil(view/z) + 1` texels, and the composite uses
    nearest sampling. It recommends integer-fit, with non-integer fit
    deferred.
  - `CompositeParams` is 64 B (`uv_rect`, `multiply`, `haze`, `adjust`),
    with a GLSL block-parse test.
  - `ScreenFade` provides `startFadeIn`, `advance`, `alpha`, and
    `k_screen_fade_in_ns = 350 ms`. `Engine.applyTransitions` calls
    `startFadeIn` on `replaced`.
  - `RenderOrder.screenFade()` and `k_post_state_command_headroom` exist.
  - `Renderer.init` fails with `error.SceneTargetFormatUnsupported` when
    `world_pixel` is unsupported.
  - `drawGroupRange` exists.
  - The zoom actions ship with no pad default.
- **Slice 54:**
  - `VideoSettings`, `setVideo` (sets `pending_video`), and
    `Engine.applyPendingSettings`. That apply order is fullscreen → present
    mode → frames in flight → `setResolutionPolicy`, and each failure is
    reverted in `current` with a `warn`.
  - `presentModeSupported`, which disables a `choice` option.
  - The `upgradeVNToVN+1` chain, where the appending slice bumps the
    current version by one.
- **Slice 44:**
  - `PadInput`, which includes `left_stick`, `right_stick`,
    `left_trigger`, and `right_trigger`.
  - Triggers act digitally at `k_trigger_press_threshold = 16384`.
  - `default_gamepad_bindings` is the reset source.
  - The list-form `.input.bindings`: an omitted entry keeps its default, and
    "an input bound to two actions" rejects the file.
  - A default-table invariant test.
  - The label table, with "L-Stick / R-Stick | L3 / R3".
- **Slices 56 and 57:**
  - Slice 56: `attack` on pad `RIGHT_STICK` "until Slice 44 binds the right
    trigger".
  - Slice 57: `use_item` on pad `LEFT_STICK` "until Slice 44".
  - Slice 44 does not own that move. This slice does.

### Architecture notes

**1. Scene resolution as a runtime setting (renderer re-layout).**

- **Setting.** `VideoSettings` gains `scene_resolution: SceneResolution`.
  - It is a ZON enum literal (`.drawable` / `.world_pixel`).
  - Its default is `app_config.scene_resolution`, from `-Dscene-resolution`,
    which stays the reset source.
  - `RuntimeSettings.defaults(app_config)` and `applyTo` carry it.
  - This slice bumps `k_settings_format_version` by one and adds an
    `upgradeVNToVN+1` step. The step copies every field and fills
    `video.scene_resolution` from the defaults; part 2 adds the binding
    migration to the same step.
  - **Version (consistency Table T2).** Live + 1
    (`.claude/rules/simulation.md`). In the merged order this is **v5**: 54
    v1, 44 v2 (list-form bindings), 60 v3 (`zoom_index`), 67A v4 (keyboard
    scancodes, migration freeze), 70B v5. Slice 67E adds no settings version;
    a locale setting is deferred
    ([Deferred By Owner → Full localization](../../framework-implementation-slices.md#deferred-by-owner))
    and takes the next version at landing. 67A's migration freeze applies to
    this step: any upgrade sets `save_requested`.
- **Renderer facade**, all render-owned and main-thread:
  - `sceneResolution() SceneResolution`.
  - `sceneResolutionSupported(mode) bool`: `.drawable` is always true;
    `.world_pixel` is true when 60's init-time
    `SDL_GPUTextureSupportsFormat(swapchain format, COLOR_TARGET | SAMPLER)`
    check passed, stored as `scene_target_supported: bool`.
  - `setSceneResolution(mode) error{ SceneTargetFormatUnsupported,
    SdlError }!void`. This is the re-layout, run cold and never inside a
    frame:
    1. Return if `mode` equals the current mode.
    2. For `.world_pixel`, require `scene_target_supported`. Create the new
       `(logical_w + 2) × (logical_h + 2)` target first, with an `errdefer`
       release. Then `waitForIdle`, release the old drawable target, and
       swap.
    3. For `.drawable`, `waitForIdle`, release the `world_pixel` target, and
       set the drawable target to empty (capacity 0). Slice 60's pre-acquire
       grow path creates it at the grow bucket on the next compositing
       frame.
    4. Store the mode and log one `render` `debug` line with the mode and
       dimensions.
- **Shared resources.** The composite pipeline and both samplers (the nearest
  sampler and part 4's linear sampler) are created at `Renderer.init` in
  either mode, so the re-layout touches only the scene target. If Slice 60
  created the pipeline only for one mode, this slice moves it to
  unconditional init.
- **Startup fallback, which amends 60.** `Renderer.init` with an
  unsupported `.world_pixel` falls back to `.drawable` with one `warn`
  instead of failing. A persisted setting must never brick startup on a
  different GPU.
  - `current` shows reality (Slice 54's rule). `Engine.init` writes
    `settings.current.video.scene_resolution = renderer.sceneResolution()`.
  - **The stored preference is not overwritten.** If `current` were simply
    saved, one launch on an unsupported GPU would permanently replace the
    user's `world_pixel` choice on the next settings save, even when the save
    was triggered by an unrelated edit.
  - So `SettingsStore` gains `scene_resolution_preference: ?SceneResolution
    = null`. It is runtime-only and never serialized itself.
    - On fallback, `Engine.init` sets it to the loaded value before writing
      reality into `current`.
    - The settings writer serializes `scene_resolution_preference orelse
      current.video.scene_resolution` for this one field.
    - `setVideo` clears the preference only when the edit changes
      `scene_resolution`. A user edit wins; an edit to another video field
      keeps the preference.
  - A live-apply failure (below) does not set the preference. The user just
    chose the mode and saw it fail, so the reverted reality is what gets
    saved.
- **Live apply.** `Engine.applyPendingSettings` calls `setSceneResolution`
  after `setResolutionPolicy`. On error it logs `warn` and reverts
  `current.video.scene_resolution` to `renderer.sceneResolution()`.
- **Settings screen.** A Video row "Pixel mode" is a `choice` with options
  `{ "Smooth", "Pixel-perfect" }` in `SceneResolution` order. The
  `enabled_mask` clears bit 1 when
  `!renderer.sceneResolutionSupported(.world_pixel)`. Edits flow through
  `setVideo`.

**2. Default gamepad zoom binding (final trigger and stick-click layout).**

- **Default table.** With Slice 44's one-action-per-input invariant, the
  free digital pad inputs are L3, R3, LT, and RT. Guide is never bound by
  default, because the OS and Steam overlays reserve it. The default table
  becomes:

  | `PadInput` | Action |
  | --- | --- |
  | `right_stick` (R3) | `camera_zoom_in` |
  | `left_stick` (L3) | `camera_zoom_out` |
  | `right_trigger` | `attack` (Slice 56; replaces its interim R3) |
  | `left_trigger` | `use_item` (Slice 57; replaces its interim L3) |

  The trigger rows exist only for Actions present at landing. The other
  defaults are unchanged.
- **Table type.** Trigger defaults must be expressible, so
  `default_gamepad_bindings` entries are `PadInput`-typed:
  `PadDefault { pad: PadInput, action: Action }`. If Slice 44 kept the
  `SDL_GamepadButton`-typed `GamepadButtonBinding`, this slice converts the
  table. `actionForGamepadButton` keeps working through Slice 44's
  SDL-button → `PadInput` mapping.
- **Migration** in this slice's `upgradeVNToVN+1` step, so existing files
  never reject. It runs in two ordered passes, **trigger moves first, then the
  zoom fill**:
  1. **Trigger moves.** For each moved Action: if the file's
     `(action, .gamepad, 0)` entry equals the old default (`attack`:
     `.right_stick`; `use_item`: `.left_stick`) or is absent, rewrite it to
     the new trigger. A user-customized value is kept.
  2. **Zoom fill.** For `camera_zoom_in` and `camera_zoom_out`: an absent or
     `.none` slot (the pre-70B default) takes `.right_stick` /
     `.left_stick`. If another action in the migrated file already binds that
     input, leave the slot `.none` and log one `debug` line.

  The order is load-bearing. If the zoom fill ran first, the not-yet-migrated
  old-default `attack` on R3 would collide with the zoom default, and every
  pre-70B file would end with zoom-in on `.none`. With moves first, a file
  holding only old defaults ends with RT/LT on the triggers and R3/L3 on
  zoom. Only a user-customized R3/L3 binding blocks the zoom fill.
- **Explicit beats default fill** (amends Slice 44's loader, owned here
  because this is the first change that adds non-empty defaults on inputs
  a user may already use): when the list form omits an entry and its default
  input is explicitly bound to a different action in the file, the default is
  dropped (`.none` for a pad slot, `SDL_SCANCODE_UNKNOWN` for a keyboard slot,
  since keyboard bindings are scancodes from Slice 67A) with one `debug` log,
  never rejected. The loader applies this to every settings version it
  reads, not only v5 (consistency F8).
- **Unchanged (consistency Table T1).** Replay `held_gameplay_bits` record
  Actions, not inputs, so moving pad bindings changes no bit: `attack` stays
  bit 8 (56), `use_item` bit 9 (57), `camera_zoom_in`/`camera_zoom_out` bits
  10/11 (60). There is no `replay_format_version` bump. "Reset Controls"
  restores the new defaults automatically. Prompts show "R-Stick"/"R3"
  through 44's label table.

**3. Screen fade-out before a state swap (hold the transition batch).**

- **`state.zig`:**
  - adds `pub const PendingTransitionKind = enum { none, immediate, replace }`
  - adds `StateTransitions.pendingKind() PendingTransitionKind`, a pure scan:
    - any `.quit` → `.immediate`; a quit is never delayed
    - else any `.replace` → `.replace`
    - else a non-empty queue → `.immediate`
    - else `.none`
  - The queue and `StateStack.applyTransitions` are unchanged. A held batch
    stays queued intact and is applied FIFO exactly as queued.
- **`ScreenFade` (`src/app/screen_fade.zig`, Slice 60) extensions:**
  - `phase: Phase = .idle`, where `Phase = enum { idle, fading_out, black,
    fading_in }`.
  - `pub const k_screen_fade_out_ns: u64 = 250 * std.time.ns_per_ms`.
    Fade-in stays 60's 350 ms.
  - `startFadeOut()` continues from the current alpha:
    `remaining = duration_out - @intFromFloat(alpha() * duration_out)`.
  - `advance(frame_delta_ns)` saturates: `fading_out` reaching 0 → `.black`,
    and `fading_in` reaching 0 → `.idle`.
  - `alpha()` by phase: `idle` 0, `fading_out` `1 - rem/dur`, `black` 1,
    `fading_in` `rem/dur`.
  - `fadeOutComplete() bool` is `phase == .black`.
  - 60's `startFadeIn()` sets `fading_in` from alpha 1.
- **`TransitionGate`** (same file, pure):
  `{ holding: bool = false, held_alpha: f32 = 0 }` with
  `decide(fade: *ScreenFade, pending: PendingTransitionKind,
  last_alpha: f32) Decision`, where `Decision = enum { apply, hold,
  release }`:
  - **Holding:** return `.release` (and clear `holding`) when
    `fade.fadeOutComplete()`; otherwise return `.hold`.
  - **Not holding:**
    - `.none` / `.immediate` → `.apply`
    - `.replace` → `fade.startFadeOut()`, `holding = true`,
      `held_alpha = last_alpha`, return `.hold`
- **Engine glue (`engine.zig`, app layer).** New fields:
  `screen_fade: ScreenFade` (Slice 60), `transition_gate: TransitionGate`,
  and `last_interpolation_alpha: f32 = 0`.
  - **`applyTransitions`** consults the gate first:
    - `.hold`: the first hold calls `input.releaseHeldGameplay()` and logs
      `app` `debug` with the pending count and 250 ms.
    - `.apply` / `.release`: run today's body. 60's `replaced → startFadeIn`
      then starts from `black` (alpha 1), so the black screen is continuous.
      The release logs `app` `debug` with the held milliseconds.
  - **`handleEvents`** while `holding`:
    - Events are still polled.
    - `SDL_EVENT_QUIT` and gamepad add/remove are handled by the existing
      switch.
    - States get no `handleEvent`, and nothing is routed to `InputState` or
      `FrameCommands`.
    - `applyTransitions` still runs at the end of the batch; that is where
      the release happens.
  - **`applyFrameControls`** returns early while holding: no user or policy
    pause on a stack that is about to be destroyed.
    `reconcileWithStateStack` after the release drops any stale handle.
  - **`update`** returns at the top while holding: no `states.update`, no
    `applyTransitions`, and no audio step.
    - `main.zig` still consumes the accumulator via `finishUpdate`, so no
      catch-up burst reaches the new state.
    - The outgoing session is frozen at the step that requested the swap.
      This is deterministic: the number of extra outgoing steps never
      depends on wall time or display rate, and nothing can enqueue a
      conflicting request mid-hold.
  - **`renderFrame`:**
    - First `screen_fade.advance(frame_delta_ns)` runs at the top, before
      the `can_render` branch. This moves 60's advance so a hidden or
      swapchain-blocked window still completes the fade.
    - Then `const alpha = if (transition_gate.holding)
      transition_gate.held_alpha else interpolation_alpha;` and
      `last_interpolation_alpha = alpha`, and that alpha is passed to
      `RenderContext`.
    - The frozen stack renders a still image under 60's single
      `RenderOrder.screenFade()` rect, so headroom is unchanged (one fade rect
      at a time).
  - **Timing:** the fade completes in `renderFrame` of frame N; the release
    applies in `handleEvents` of frame N+1. The new stack then updates and
    renders under a fade-in that starts at alpha 1.
- **No opt-out.** Every replace batch fades. There is no per-request opt-out
  and no "instant replace" API, because no consumer exists.
  `bootstrapStartupState` pushes directly and is unaffected. Audio is not
  faded; music changes stay with the state that starts music.

**4. `world_pixel` sharp-bilinear composite at non-integer magnification.**

- **Why it is not measurement-gated.**
  - With nearest sampling at magnification `m`, each scene texel's output
    width is `floor(m)` or `ceil(m)`.
  - Under sub-pixel scroll the pattern shifts every frame, so shimmer is
    guaranteed whenever `m` is not an integer.
  - Part 1 makes `world_pixel` user-selectable with the default `fit` scale
    mode. 1280×720 logical on a 1920×1080 drawable is `m = 1.5`, so the case
    is the common one.
- **Selection** (pure, in `scene_composite.zig`):
  `compositeSampling(mode: SceneResolution, viewport: resolution.Viewport,
  zoom: f32) CompositeSampling { sharp: bool, magnification: [2]f32 }`.
  - `.drawable` → `sharp = false`, because the composite is a 1:1 copy.
  - `.world_pixel`:
    - `m = { viewport.scale_x * zoom, viewport.scale_y * zoom }`
    - `sharp = !(m[0] == @floor(m[0]) and m[1] == @floor(m[1]))`
    - `magnification = { @max(m[0], 1), @max(m[1], 1) }`
  - `integer_fit` gives exact integer scales (`resolution.zig:177-179`), and
    `world_pixel` zoom is always an integer level (part 5 snaps there), so
    integer magnification keeps 60's exact nearest path.
  - Minification (`m < 1`) clamps to 1, which degenerates to plain
    bilinear.
- **`CompositeParams` grows to 80 B**, five `[4]f32`:
  - `uv_rect` at 0
  - `multiply` at 16
  - `haze` at 32
  - `adjust` at 48
  - `sampling` at 64: x/y = clamped magnification, z = sharp 0/1, w unused

  Update 60's comptime `@sizeOf`/`@offsetOf` asserts and its GLSL
  block-parse test to five `vec4`s in order.
- **`composite.frag.glsl`:** `c = sampleScene(uv).rgb` replaces the direct
  `texture(scene, uv)`, where:

  ```glsl
  vec4 sampleScene(vec2 uv) {
      if (params.sampling.z == 0.0) return texture(scene, uv);
      vec2 tex_size = vec2(textureSize(scene, 0));
      vec2 texel = uv * tex_size;
      vec2 scale = params.sampling.xy;            // >= 1
      vec2 region = 0.5 - 0.5 / scale;
      vec2 center_dist = fract(texel) - 0.5;
      vec2 f = (center_dist - clamp(center_dist, -region, region)) * scale + 0.5;
      return texture(scene, (floor(texel) + f) / tex_size);
  }
  ```

  - With `sampling.z == 0` and `grade_active == 0`, the output stays 60's
    exact pass-through.
  - The binding layout is unchanged: one `sampler2D` at set 2 binding 0, and
    the UBO at set 3 binding 0. The MSL entry signature is expected to be
    unchanged; copy the regenerated one if it differs.
- **Sampler.** `gpu/device.zig` adds
  `createLinearSampler(device) !*c.SDL_GPUSampler` (linear min/mag, nearest
  mip, clamp-to-edge). It is created at `Renderer.init` and released in
  `deinit`. The composite binds `if (sampling.sharp) linear_sampler else
  sampler`.
- **Coverage amendment to 60.**
  - The `world_pixel` scene pass covers `ceil(view/z) + 2` texels per axis,
    not `+ 1`. The texture is already `logical + 2`, which fits at `z = 1`.
  - The sharp blend at the last output column can read one texel past the
    sub-rect end when `frac → 1`; with `+ 1` coverage that texel would be
    clear color.
  - The top-left never blends below texel 0, because the first fragment
    center sits at `t ≥ frac + 0.5/m`.
- **CPU reference.** `scene_composite.sharpBilinearTexel(texel: f32,
  scale: f32) f32` mirrors the shader per axis for tests.
- **Diagnostics.**
  - One `render` `debug` line when the sampling mode changes (edge-detected
    against a stored `last_composite_sharp`).
  - A comptime-gated perf metric, `scene_composite_sharp_frames`.

**5. Zoom tween (drawable only; presentation-only).**

- **`CameraRig` additions (`src/render/camera.zig`):**
  - fields: `zoom_from_inv: f32`, `zoom_inv_previous: f32`,
    `zoom_inv_current: f32`, `zoom_tween_age: u8`
  - `pub const k_zoom_tween_steps: u8 = 12` (200 ms at 60 Hz)
  - `pub const ZoomRenderMode = enum { snap, tween }`
  - `src/core/math.zig` gains `easeOutCubic(t: f32) f32 = 1 - (1 - t)^3`,
    with tests: 0 → 0, 1 → exactly 1, monotonic.
- **Interpolated quantity.** The tween interpolates the visible extent
  (`inv = 1/zoom`) linearly, so the clamp formulas use it directly and no
  transcendental is needed.
- **`snapTo` / init:** `zoom_inv_previous = zoom_inv_current = 1/level` and
  `zoom_tween_age = k_zoom_tween_steps`, which is settled.
- **`captureZoomInput` on a change:**
  - `zoom_from_inv = zoom_inv_current` and `zoom_tween_age = 0`.
  - It keeps 60's `center_previous = center_current`.
  - It drops 60's immediate re-clamp at the target zoom, because the
    per-step clamp follows the tweened extent. A mid-tween retarget
    therefore starts from the current extent.
- **`step`:** insert between 60's step 4 (follow) and step 5 (clamp):
  `zoom_inv_previous = zoom_inv_current`,
  `age = min(age + 1, k)`, and
  `zoom_inv_current = if (age == k) 1/level else math.lerp(zoom_from_inv,
  1/level, math.easeOutCubic(age / k))`.
  - The step 5 clamp uses 60's exact `view/(2z)` formula when settled, and
    `view * zoom_inv_current / 2` while tweening, so the center moves
    smoothly near edges.
  - This fixed-step state does not depend on the render mode.
- **Settled** means `zoom_tween_age == k and zoom_inv_previous ==
  zoom_inv_current`.
- **`renderCamera(alpha, mode: ZoomRenderMode)`:**
  - With `.snap`, or when settled: `zoom = @floatFromInt(level)` exactly,
    matching 60.
  - Otherwise: `inv = math.lerp(zoom_inv_previous, zoom_inv_current, alpha)`
    and `zoom = 1/inv`.
  - It re-clamps the shaken center at the rendered extent, as 60 already
    does, so the rendered view never leaves the world in either mode.
- **`syncPrevious()`** also sets `zoom_inv_previous = zoom_inv_current`.
- **`GameDemoState.render`** passes `.tween` when
  `context.renderer.sceneResolution() == .drawable`, else `.snap`. A runtime
  switch to `world_pixel` mid-tween snaps immediately, with no state reset.
- **Invariants:**
  - `anchorRect()` reads only `anchor_min` and `zoom_levels[0]`, so it is
    bit-identical with and without tweening.
  - Zoom stays ≥ 1 throughout (interpolation between integer levels ≥ 1),
    so the visible area never exceeds the zoom-1 window. Render reservations
    are unchanged.
  - Replays reproduce the tween, because the zoom actions are replay bits
    10/11.

**Fixed budgets.**

- `k_screen_fade_out_ns = 250 ms`
- `k_zoom_tween_steps = 12`
- `CompositeParams` = 80 B
- one extra sampler
- `k_max_choice_options` is unchanged (2 options)

Nothing scales with world, map, or window size.

**Errors.**

- `setSceneResolution`: `error{ SceneTargetFormatUnsupported, SdlError }`.
  It is logged and reverted by `applyPendingSettings` and never escapes.
- `Renderer.init` no longer fails on an unsupported `world_pixel` (fallback
  above).
- Settings migration never adds a rejection reason.

**Diagnostics.**

- `app` `debug`: hold start and release.
- `app` `warn`: scene-resolution apply failure.
- `app` `debug` (settings): a migrated binding, and a dropped colliding
  default.
- `render` `debug`: re-layout, and a sampling-mode change.
- `render` `warn`: the `world_pixel` startup fallback.
- No per-frame logging.

**Ownership.**

- `src/app/`: `screen_fade.zig`, `engine.zig`, `state.zig`, `settings*.zig`,
  `input.zig`.
- `src/render/`: `camera.zig`, `scene_composite.zig`, `renderer.zig`,
  `gpu/device.zig`.
- `assets/shaders/composite.frag.glsl` plus its artifacts.
- `src/game/game_demo_state.zig` passes the zoom render mode.
- `src/game/settings_menu_state.zig` adds the choice row.
- Game states never call SDL or GPU.

**Out of scope, by decision:**

- Tween in `world_pixel`. It would toggle between sharp and nearest sampling
  at tween end and give up the pixel-perfect promise.
- Fade colors other than black.
- Audio crossfades.
- Instancing (see 70A).

### Checklist

- [ ] **Scene resolution:**
  - `VideoSettings.scene_resolution` with defaults/`applyTo`, a settings
    schema bump by one, and the `upgradeVNToVN+1` step
  - `Renderer.sceneResolution` / `sceneResolutionSupported` /
    `setSceneResolution`
  - unconditional composite-pipeline and sampler creation at init
  - the `world_pixel` → `.drawable` init fallback, the `Engine.init`
    write-back of reality into `current`, and
    `SettingsStore.scene_resolution_preference` with the writer's
    `preference orelse current` rule
  - the `applyPendingSettings` call with revert
  - the "Pixel mode" `choice` row with `enabled_mask`

  Tests:
  - the previous version upgrades with `scene_resolution` defaulted and
    every other field preserved, and the upgrade sets `save_requested`
  - the new version round-trips
  - `.bogus` rejects
  - `defaults(app_config)` honors `-Dscene-resolution`
  - settings-screen pass: the option is disabled when unsupported (fake
    query)
  - **preference survives fallback:** load `world_pixel` with a fake
    unsupported query. `current` reads `.drawable`. Edit the master volume and
    save: the written file still says `.world_pixel`. Then choose `.drawable`
    explicitly and save: the file says `.drawable` and the preference is null.
  - a live-apply failure reverts `current` and leaves the preference null
- [ ] **Pad layout:**
  - `PadInput`-typed `default_gamepad_bindings` rows for R3/L3 zoom and the
    RT/LT `attack`/`use_item` moves (for the Actions present)
  - the migration in this slice's upgrade step, trigger moves before the
    zoom fill
  - the explicit-beats-default-fill rule in Slice 44's loader (`.none` for
    pad slots, `SDL_SCANCODE_UNKNOWN` for keyboard slots)

  Tests:
  - 44's default-table invariant passes
  - old-default `attack` R3 migrates to RT; a customized `attack` binding is
    kept
  - **migration order:** a pre-70B file with `attack` on old-default R3 and
    `use_item` on old-default L3 ends with `attack` → RT, `use_item` → LT,
    `camera_zoom_in` → R3, and `camera_zoom_out` → L3, with no `.none` slot
  - a zoom default that collides with a user-customized binding becomes
    `.none` and is not rejected
  - an omitted entry whose default is explicitly taken stays empty (pad
    `.none`; a keyboard case stays `SDL_SCANCODE_UNKNOWN`)
  - Reset Controls restores the new table
  - the replay `held_gameplay_bits` layout test (Slice 49) passes unchanged
- [ ] **Fade-out hold:**
  - `PendingTransitionKind` and `StateTransitions.pendingKind`
  - `ScreenFade` phases, `startFadeOut`, `fadeOutComplete`, and
    `k_screen_fade_out_ns`
  - `TransitionGate`
  - Engine glue in `applyTransitions`, `handleEvents`, `applyFrameControls`,
    `update`, and `renderFrame` (advance at the top, held alpha)

  Tests:
  - `pendingKind` with real queued payloads (a local `TestingState`): empty,
    push-only, replace, and replace + quit → `.immediate`
  - fade-out continuity from a mid fade-in alpha
  - saturating `advance` through `black`
  - `alpha` monotonic per phase
  - gate table: apply, hold-until-complete, release, quit bypass, no
    re-entry while holding
- [ ] **Sharp-bilinear:**
  - `compositeSampling` and `sharpBilinearTexel` in `scene_composite.zig`
  - `CompositeParams` at 80 B with asserts
  - the `composite.frag.glsl` `sampleScene` branch
  - `createLinearSampler` and the per-frame sampler choice
  - `world_pixel` coverage `ceil(view/z) + 2`
  - `zig build shaders-update`; commit the composite artifacts and the lock

  Tests:
  - selection table: drawable → nearest; `integer_fit` × zoom 1–4 → nearest;
    fit 1.5× → sharp (1.5z); 0.75× → sharp with scale 1
  - the reference at integer scale returns texel centers (equals nearest)
    and blends only within one output pixel of a texel edge
  - GLSL parse: five `vec4`s in order
  - coverage covers the last-column neighbor at `frac → 1`
- [ ] **Zoom tween:**
  - `math.easeOutCubic` with tests
  - `CameraRig` fields, `k_zoom_tween_steps`, and `ZoomRenderMode`
  - the `captureZoomInput` / `step` / `renderCamera(alpha, mode)` /
    `syncPrevious` changes
  - the `GameDemoState.render` mode selection

  Tests:
  - settled `renderCamera` is bit-identical to 60's integer zoom
  - the tween reaches the target exactly at step 12 and is monotonic in
    extent
  - a mid-tween retarget is continuous
  - `.snap` gives the integer level
  - a zoom-in tween at each world edge keeps the rendered view inside the
    bounds
  - `anchorRect()` sequences are bit-identical with tween on and off
- [ ] (added by Slice 67) The Slice 67C gpu-smoke thumbnail probe runs once per
      `scene_resolution` mode and asserts the same world-only pixels (67C).
- [ ] `gpu_smoke_impl.zig` re-initializes a renderer with logical 160×90,
      scene resolution `.drawable`, and the window at 400×225 (fit 2.5×),
      then renders:
  1. a drawable frame with a non-neutral grade
  2. after `setSceneResolution(.world_pixel)`, a frame at a fractional
     camera at zoom 1 (sharp path)
  3. after `setResolutionPolicy(integer_fit)`, a frame at 2× (nearest path)
  4. after `setSceneResolution(.drawable)`, one more frame

  `gpu_debug` validation stays clean.
- [ ] Docs:
  - `docs/rendering-assets-shaders.md`: runtime scene resolution and
    re-layout, sharp-bilinear selection and `CompositeParams` v2, the second
    sampler, the coverage rule
  - `docs/state-stack-and-input.md`: fade-out hold semantics (held batch,
    frozen stack, quit bypass), the gamepad default table, migration rules
  - `docs/architecture.md`: Engine frame flow during a hold; the zoom tween
    as rig presentation state, separate from the anchor
  - `docs/development-workflow.md`: `-Dscene-resolution` is now the
    settings default
- [ ] Cross-slice amendments, in the same change:
  - **Slice 60:** move the zoom tween, runtime scene-mode switch, fade-out,
    and sharp-bilinear upscale out of its "out of scope" list into Slice 70B,
    and change "(non-integer fit is a Scaling Gap)" to "(Slice 70B
    sharp-bilinear)". Point "Fade-out-then-swap … deferred" and "No gamepad
    default (Slice 44)" to 70B. Mark the `world_pixel` init error as
    superseded by 70B's fallback.
  - **Slice 44:** "Slice 60 ships an empty pad slot for zoom" gains "Slice 70B
    sets the R3/L3 defaults and moves 56/57 to the triggers".
  - **Slice 56:** "until Slice 44 binds the right trigger" becomes "until
    Slice 70B moves it to `right_trigger`".
  - **Slice 57:** "`LEFT_STICK` until Slice 44" becomes "until Slice 70B moves
    it to `left_trigger`".
  - **Slice 67C:** thumbnail capture states that it works in both
    `scene_resolution` modes, because 70B makes the mode switchable at
    runtime (consistency L3).
  - **Slice 69E:** `presentationViewRect()` states that it uses 70B's tweened
    rendered zoom once 70B has landed (consistency L3).
- [ ] Add the explicit-beats-default-fill rule to
      `.claude/rules/input-state.md` when this lands.

### Acceptance checks

- [ ] `zig build verify` passes, including 52A's stale-lock gate with the
      regenerated composite artifacts.
- [ ] `zig build gpu-smoke` passes all four 70B frames with validation clean.
- [ ] Manual:
  - Switch Pixel mode Smooth ↔ Pixel-perfect in Settings during gameplay with
    no restart, then restart; the choice persists.
  - Pixel-perfect under Fit at a non-integer window scale shows no texel-width
    shimmer while scrolling.
  - Pad R3/L3 zoom in and out; RT attacks and LT uses an item where 56/57
    have landed.
  - Menu → gameplay and Quit to Main Menu fade out, swap, then fade in, with
    the outgoing scene frozen during the fade.
  - Zoom changes glide in Smooth mode and snap in Pixel-perfect mode.
  - UI and the FPS overlay stay untinted.
- [ ] A pre-70B `settings.zon`, with customized and default bindings, loads
      with no rejection, migrated as specified.
- [ ] `zig build bench --release=fast -- --group render-game-prep` shows no
      CPU regression from the rig or composite changes. Record before/after
      in the PR.

### VoidLight reference

**Port:**

- `include/events/SceneChangeEvent.hpp:28-64` and
  `src/events/SceneChangeEvent.cpp:16-71`: the idea of a fade transition
  type with a duration and color on scene change.
- `include/gpu/GPUTypes.hpp:46-61` (`CompositeUBO`) and
  `res/shaders/composite.frag.glsl`: the composite-uniform pattern that
  70B's `sampling` vec4 extends.
- `include/utils/Camera.hpp:65-67` and `src/utils/Camera.cpp:551-566`:
  integer zoom levels (the tween's endpoints).

**Do not port:**

- VoidLight's 1.0 s default transition duration
  (`SceneChangeEvent.hpp:118`). It is too slow for menu flows; ZL uses 250 ms
  out and 350 ms in.
- Scene changes dispatched through the global `EventManager`. ZL holds the
  `StateTransitions` batch in `Engine`.
- `zoom` as `uv / zoom` anchored at the top-left in the composite shader
  (Slice 60 already rejects this).
- Any composite filtering that changes with `-ffast-math`.

