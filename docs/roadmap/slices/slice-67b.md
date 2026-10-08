## Slice 67B: Debug Text Migration, Event Log, Text Atlas Telemetry, And UI Sound Cues

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 53A](slice-53a.md), [Slice 53B](slice-53b.md), [Slice 44](slice-44.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Render, game-UI, and app-audio work. Depends on Slice
53A (`TextLabelSystem`), Slice 53B (`UiScreen`, theme, HUD), and Slice 44
(the conflict-rejection path that gets the `denied` cue). Independent of 67A
and 67C: every focus change, from any source, goes through 53B's single
internal focus setter, which is where the cue is queued.

Goal:
- The two remaining surface-text consumers (`FpsCounter`, `AiDebugOverlay`)
  move onto `TextLabelSystem`, and the whole `PreparedText` /
  `TTF_RenderText_Blended` / `TextEntrySlot` path is deleted, so the app has
  one text pipeline.
- The demo HUD gains a typed, fixed-capacity event log fed from each step's
  `SimulationEvents`.
- Atlas page pressure becomes measurable (perf counters plus a gpu-smoke
  Western-corpus probe), with a recorded number behind the 8-page cap.
- UI navigation plays fixed SFX through stable `AudioAssetId`s that survive
  the pause SFX stop.

### Current foundation

- `src/render/fps_counter.zig:21-29`: prefix + 10 digit `PreparedText`s.
  - `:73-96`: per-DPI `loadFont` and full glyph re-prepare.
  - `:120-143`: drawable-space composition at (12, 10).
  - `:209-211`: `overlayFontSize(drawable_pixel_scale)`.
- `src/render/debug_overlay.zig:10-49`: owns `FpsCounter`, F2 toggle, and
  `init(text_service)`. `debug_overlay_stub.zig` mirrors that API.
- `src/game/ai_debug_overlay.zig`:
  - `:188-250`: behavior/tier/digit `PreparedText`s prepared in per-behavior
    colors
  - `:256-299`: drawable HUD at `10 + fpsOverlayFontSize(...) + 6`
  - `:421-430`: `.world`-space behavior labels
  - `:176-182`: command bound assumes one sprite per label
- `src/render/text.zig`, the path to delete:
  - `:159-186` `PreparedText` / placement
  - `:252-309` prepare/destroy
  - `:547` `drawPreparedText`
  - `:588-640` `TextCacheKey` / `TextEntrySlot` / `ColorKey`
  - `:641-705` `TextBackend.render_text` → `TTF_RenderText_Blended`
  - `:760-830` `FakeBackend` / `initFakeTextService` / `countLiveTextEntries`
  - `FontId` / `loadFont` / `registerFont` / `defaultFont` (`:37-56`,
    `:217-250`, `:411-460`) have no other consumers once the overlays move
    (53A/53B migrate every menu and the loading screen).
- `src/render/renderer.zig:562-569` `drawablePixelScale` is used only by the
  two overlays plus its own tests (`:2292-2300`).
  - `:196-212`: `k_overlay_command_headroom = 16` with the comptime
    `k_stacked_state_ui_headroom >= 2 ×` assert.
  - `src/render/sprite_batch.zig:46-50`: `RenderDomain { world, ui, debug }`.
  - `renderer.zig:1566-1602`: world→logical is `(world − camera.position) ×
    zoom` folded into the uniform.
- `src/game/simulation.zig:153-164` `SimulationEventPayload` (10 arms; the
  only player-facing one today is `destructible_destroyed`, `:145-151`) and
  `:245` `SimulationEvents`. `game_demo_state.zig:512-564`: `update` ends
  after `applyStructuralCommandsAndPostCommitEvents`, when
  `simulation_frame.events.mergedItems()` holds the whole step.
- `src/assets/manifest.zig:14-18, :116-135`: `AudioAssetId` and
  `audio_assets` (predecoded SFX).
- `src/app/audio.zig`:
  - `:30-36` `PlaySfxRequest { asset, gain, priority, frequency_ratio,
    position }`
  - `:92-197` the per-step `AudioCommandBuffer` (`AudioCommandLimitReached`)
  - `:363-373` `setPaused` → `stopAllSfx` (`:510-522`) stops **every** SFX
    track on pause enter and exit
- SDL_ttf 3.2.2 `src/SDL_gpu_textengine.c`:
  - `:216-223`: one stb_rect_pack skyline packer per 1024² page
  - `:545-548`: +1 px padding per glyph rect
- 53A:
  - `TextLabelSystem` page registry (`k_max_text_atlas_pages = 8`)
  - rebuild drops orphaned glyphs
  - `draw` takes `LabelDraw { x, y, color, order, clip }` in logical space
  - "debug overlays stay on `PreparedText` (Scaling Gap)"

### Architecture notes

**Label system extensions** (`src/render/text_labels.zig`, render-owned, all
O(1) or cold):

- `LabelDraw.space: LabelSpace = .logical` with `LabelSpace = enum { logical,
  drawable }`.
  - In `.drawable`, `x`/`y` are drawable px. `origin_px = round(x)`, and each
    cached quad is emitted as a `.drawable` sprite at `origin_px + dest_px`
    with no division, so it maps 1:1 exactly.
  - `clip` is in the same space.
- `pixelSize(id) ?[2]u16` returns the cached `size_px` (drawable px).
- `lineHeightPx(role) u16`, cached per role at init and at every rebuild from
  `TTF_GetFontHeight` through `LabelBackend.font_height` (a cold backend
  entry).
- `atlasStats() TextAtlasStats { pages: u8, rebuilds: u32,
  page_cap_rebuilds: u32, page_cap_overflow_epochs: u32 }`. The counters are
  maintained where 53A already detects pages, rebuilds, and overflow warns.
- Glyph size in `.drawable` space is `role pt × ui_scale × s` drawable px,
  where `s` is the committed logical→drawable raster scale. **Documented
  change:** debug text now follows the presentation scale and `ui_scale`
  (same as all UI text) instead of window pixel density. At 1280×720
  windowed it is 16 px (mono) instead of 18 px.

**Debug overlay migration:**

- **`src/render/debug_text.zig`** (new, render-owned, shared by both overlays):
  - `k_overlay_origin_px = [2]f32{ 12, 10 }`
  - `k_overlay_line_gap_px: f32 = 6`
  - `overlayLineHeightPx(labels) f32 = labels.lineHeightPx(.mono)`
  - `DigitLabels { ids: [10]TextLabelId = @splat(.invalid) }`, with:
    - `ensure(labels, renderer) TextLabelError!void`: per id,
      `if (!labels.isAlive(id)) id = try labels.create(renderer, .mono,
      &[_]u8{'0' + i}, null)`. This is cold, reached only on the first frame
      or after a 600-frame idle reclaim.
    - `drawNumber(labels, renderer, value: u64, x_px, y_px, color, order) !f32`:
      `bufPrint` into a `[20]u8` stack buffer, draws each digit label in
      `.drawable` space, advances by `pixelSize(id)[0]`, and returns the end x.
- **`FpsCounter`.**
  - Fields: `prefix: TextLabelId` ("FPS "), `digits: DigitLabels`, plus the
    unchanged sampling fields.
  - `prepareForRender(labels, renderer)` runs the `ensure` calls. Drawing is
    the prefix label, then `drawNumber`, at `RenderOrder.debug(.overlay)` with
    the yellow tint.
  - Removed: `font: FontId`, `active_font_size`, `texture_dirty`,
    `overlayFontSize`, the per-DPI `loadFont`, and `waitForIdle`.
  - `deinit` is removed: labels are reclaimed by 53A's idle sweep or torn down
    with `TextService`.
  - Bound: "FPS " is ≤ 4 quads and the u32 digits ≤ 10, so ≤ 14 ≤
    `k_overlay_command_headroom` (16). The headroom constants do not change.
- **`DebugOverlay`.** `init()` takes no arguments; `deinit` is removed;
  `prepareForRender(text_service, renderer)` reads `&text_service.labels`.
  `debug_overlay_stub.zig` mirrors the same API. Engine drops the FontId
  comment (`engine.zig:116-118`) and the overlay `deinit` call (`:182`).
- **`AiDebugOverlay`.**
  - Fields: `behavior_labels: [behavior_count]TextLabelId` (one per
    `@tagName`, drawn with that behavior's color as tint, so no per-color
    textures), `tier_labels: [5]TextLabelId`, `digits: DigitLabels`.
  - `ensureLabels` is `isAlive`-driven every visible frame: O(1) each, 20
    checks.
  - **HUD.** Drawable space, top
    `y = k_overlay_origin_px[1] + overlayLineHeightPx(labels) +
    k_overlay_line_gap_px`; line advance is `overlayLineHeightPx`.
  - **Behavior labels.** New facade `Renderer.worldToLogical(p: Vec2) Vec2 =
    (p − batch.camera.position) × batch.camera.zoom` (the CPU mirror of
    `frameUniformForPresentation`'s `.world` arm). Anchor:
    1. `world_anchor = origin − (0, bar_stack_offset + drive_count ×
       (bar_height + bar_gap))`.
    2. Project it with `worldToLogical`.
    3. Draw a `.logical` label at `(lp.x − w/2, lp.y − h)`, using
       `logicalSize` for `w`/`h`, at `overlay_order`.

    Labels stay crisp and constant-size at any Slice 60 zoom.
  - **Command bound** becomes byte-based, computed at comptime from the
    literal tables (glyph quads ≤ UTF-8 bytes):
    - `per_agent_commands = 2 + ring_segments + 2 × drive_count +
      ai_memory_ring_capacity + max_behavior_name_bytes`
    - `hud_commands = Σ tier_name bytes + Σ behavior name bytes + (hud_lines
      + behavior_count) × max_hud_digits`

    `commandCapacity()` and its test update.
- **Deletions in `text.zig`:**
  - `PreparedText`, `TextAnchor`, `TextPlacement`, `drawPreparedText`, `textDest`
  - `TextRequest`, `TextStyle`, `TextLayoutOptions`, `TextAlign`
  - `TextCacheKey`, `TextEntrySlot`, `TextTextureId`, `ColorKey`, `RenderedText`
  - `TextBackend` (and its renderer adapter `rendererRenderText` /
    `createTextureFromTextSurface` / `rendererDestroyTexture`)
  - `FakeBackend`, `initFakeTextService`, `countLiveTextEntries`
  - `FontId`, `FontSlot`, `loadFont`, `registerFont`, `findFont`,
    `defaultFont`, `prepareText*`, `destroyPreparedTexts*`

  `TextService` keeps `allocator`, `assets`, `labels: TextLabelSystem`,
  `ttf_initialized`, `init` (`TTF_Init`), `initLabels`, `beginFrame`, and
  `deinit` (labels first, then `TTF_Quit`). `FontDesc`, `default_font_path`,
  and `defaultFontDesc` stay, because `UiFontTable` uses them.
- **Other deletions.** `Renderer.drawablePixelScale` and its tests
  (`renderer.zig:562-569`, `:2292-2300`), which have no remaining caller.
- **53A amendment.** Its Scope bullet changes to "debug overlays move in Slice
  67B".

**Event log** (presentation-only, owned by `GameDemoState`):

- **`src/game/ui/event_log.zig` `EventLog`** (toolkit primitive, generic):
  - `entries: [k_event_log_rows]EventLogEntry`, `head: u8`, `len: u8`,
    `appends_this_step: u8`, `dropped: u32`.
  - Rows are **slot-bound**: entry slot `i` always renders through
    `labels[i]: TextLabelId`. A push re-texts only the slot it overwrites,
    never shifting the other rows (no 6× `setText` per push).
  - `EventLogEntry { text: [k_event_log_line_capacity]u8, text_len: u8,
    base_len: u8, style: StyleRole, key: u32, repeat: u16,
    last_step: StepIndex, text_dirty: bool }`. `StepIndex` is Slice 49's
    `u64` step type (`simulation_scope.zig`); steps are monotonic and never
    wrap.
  - `beginStep()` resets `appends_this_step`.
  - `push(line: EventLogLine, step: StepIndex) void`:
    1. If the newest entry has the same `key` and
       `step - last_step < k_event_log_visible_steps`, then `repeat += 1`
       (saturating at 999), `last_step = step`, and the text is re-formatted
       as `base ++ " (x{repeat})"`. This coalesced repeat does not count
       against the budget.
    2. Otherwise, if `appends_this_step == k_event_log_appends_per_step`,
       `dropped += 1` and return.
    3. Otherwise overwrite the oldest slot.

    Text is formatted with `std.fmt.bufPrint` into the fixed line buffer at
    push time, truncated on a UTF-8 boundary. Pushes are bounded at 3 new
    lines per step.
  - `EventLogLine { base: []const u8 (pre-formatted by the feed into a
    caller stack buffer), style: StyleRole, key: u32 }`.
- **Draw.** `drawEventLog(log, labels, renderer, theme, content: Rect,
  stack_order, step: StepIndex) !void`, with `step` from
  `SimulationScopeSystem.currentStep()`.
  - Visible entries are those with `step - last_step <
    k_event_log_visible_steps` (480 steps = 8 s of unpaused play; pause stops
    the step counter, so lines do not expire while paused). `push` asserts
    `step >= last_step` of the newest entry.
  - Rows are newest at the bottom, laid out upward by `logicalSize(h) +
    theme.metrics.event_log_row_gap`, `body` role, clipped to `content`.
  - Alpha fades linearly over the last `k_event_log_fade_steps = 60` steps.
    Color is `theme.colors` by `style` × alpha, a pure tint.
  - `isAlive` re-create and `setText` only for `text_dirty` slots.
  - Bound: `k_event_log_rows × k_event_log_line_capacity = 576` quads, added
    to `hud.drawCommandBound()` through `render_prep.spriteCommandCapacity`.
- **HUD placement.** `HudWidget.event_log_panel`, a 53B `panel` anchored
  `bottom_left`, offset `{16, -16}`, `width = .fixed(theme.metrics.event_log_width
  = 460)`, `height = .fixed(k_event_log_rows × theme.metrics.row_height)`.
  The panel is `setVisible(false)` whenever no entry is visible (dirty
  compare). `drawEventLog` runs inside `hud` rendering with
  `rectOf(.event_log_panel)` minus padding.
- **Feed** (`src/game/event_log_feed.zig`, game-specific).
  - `GameDemoState.observeStepEvents()` runs once at the end of `update`,
    after `applyStructuralCommandsAndPostCommitEvents`. It is **one pass**
    over `simulation_frame.events.mergedItems()` that drives both 53B's HUD
    "Destroyed N" counter and the feed.
  - The log reads the step's canonical merged order, so its content is
    deterministic. It never writes simulation state and never feeds back into
    the step.
  - `lineFor(event, player: PlayerView, buf: *[k_event_log_line_capacity]u8)
    ?EventLogLine` is an **exhaustive `switch` with no `else` arm**. Every
    slice that adds a `SimulationEventPayload` arm must decide its log line
    (or `=> null`) at compile time. Arms whose payload is itself a tagged
    union (59's `environment_transition`) switch exhaustively on the inner
    tag too, so a later sub-arm (69C `time_skipped`, 69B per-region
    `weather_changed`) is also a compile-time decision in its own slice.
  - Player level changes are not events: `observeStepEvents` compares
    `player.current_level` with the previous value and pushes "Reached level
    {n}" (style `success`, key `0xFFFF_0000 | n`).
  - Mapping table. The arms that exist when 67B lands are implemented by 67B;
    each later slice implements its own row in the same change (Checklist
    additions folded into 56, 57, 59, 61, and 63; see [Slice 67](slice-67.md)):

    | Payload arm (owner) | Logged when | Line | Style | Coalesce key (tag<<24 \| sub<<16 \| subject) |
    | --- | --- | --- | --- | --- |
    | `entity_created`, `entity_destroyed`, `component_changed`, `world_tile_changed`, `world_obstacle_changed`, `nav_region_invalidated`, `entity_perceived`, `entity_lost`, `affect_threshold_crossed` (live) | never | — | — | — |
    | `destructible_destroyed` (45, live) | always | "Obstacle destroyed (level {level})" | normal | sub 0, subject `level` |
    | `entity_damaged` (56) | attacker is player / target is player | "You hit for {amount}" / "You took {amount} damage" | normal / danger | sub 0 / 1, subject 0 |
    | `entity_killed` (56) | killer is player / victim is player | "Enemy defeated" / "You were defeated" | success / danger | sub 0 / 1 |
    | `item_picked_up` (57) | holder is player | "Picked up {count} {catalog name}" (feed takes `*const ItemCatalog`) | success | subject `item` low 16 |
    | `environment_transition` (59) | `day_phase_changed` / `season_changed` / `weather_changed` / `day_started`; `lightning_strike` never | "Dawn breaks" · "Day" · "Dusk falls" · "Night falls" / "{Season} begins" / "Weather: {kind}" / "Day {day_index}" | hint | sub = union tag |
    | `harvest_completed` (61) | harvester is player | "Harvested {quantity} {name}" plus " (depleted)" | success | subject `item` |
    | `trade_completed` (63) | customer is player | "Bought {quantity} {name} for {total}" / "Sold …" by `direction` | normal | sub = direction |
    | `gift_given` (63) | giver is player | "Gave {quantity} {name}" | normal | subject `item` |
    | `trade_session_requested` (63) | never | — | — | — |
    | `faction_stance_changed` (63) | `from` or `toward` is the player's faction | "{Faction} is now {stance}" | warning | subject `toward` |

  - `PlayerView { entity: EntityId, faction: Faction }` is built once per step
    in `observeStepEvents`.
- **Fixed budgets:**
  - `k_event_log_rows = 6` (VL default 5 plus one)
  - `k_event_log_line_capacity = 96` bytes
  - `k_event_log_appends_per_step = 3`
  - `k_event_log_visible_steps = 480`
  - `k_event_log_fade_steps = 60`

  The feed scan is O(step events), already bounded by each producer's fixed
  event budget. v1 is display-only, with no scrollback history; the ring holds
  exactly the displayable rows.

**Text atlas telemetry and probe** (measure, then never raise the cap):

- **Perf counters.** Comptime-gated `runtime_perf_log` metrics
  `text_atlas_pages` (max over the interval) and `text_atlas_rebuilds`,
  recorded in `Engine.renderFrame` from `labels.atlasStats()`. They show up
  in the existing ReleaseSafe soak dumps.
- **gpu-smoke probe** (`src/platform/gpu_smoke_impl.zig`, display-gated):
  - Loads the corpus `assets/test/text_corpus_western.txt`: printable ASCII
    U+0020–U+007E plus U+00C0–U+00FF, 159 glyphs, one line of ≤ 85 glyphs per
    label.
  - Creates the labels in all four roles at an effective raster of 4.5×
    role pt: 3.0× (4K at 1280×720 logical) × 150% UI scale. The smoke window
    is 320×180 (`gpu_smoke_impl.zig:40-45`), so its committed scale `s` is
    0.25 on a 1× display and 0.5 on a 2× HiDPI display. The probe reads the
    committed `s` through `Renderer.logicalPresentationScale()` and passes
    `ui_scale_percent = round(450 / s)` (1800 at `s = 0.25`, 900 at 0.5) to
    the real `beginFrame` parameter, so the effective raster is 4.5× on any
    display.
  - This relies on 53A's `beginFrame(renderer, ui_scale_percent: u16)`
    applying the value unclamped: the only range limit is 54's `UiScale`
    enum at the settings layer (`percent_100/125/150`), and 53A's clamp
    `[0.25, 8.0]` applies to the presentation scale `p`, not to ui scale.
    67B adds the 53A test that pins it: on the fake label backend,
    `beginFrame(…, 1800)` with a committed `s = 0.25` sets each role to role
    pt × 18 × 0.25.
  - Logs `atlasStats().pages` and asserts **≤ 6 pages**, which keeps 2 pages
    of slack for churn below the cap of 8.
  - Analytic expectation from glyph-area estimates plus the +1 px padding:
    about 3 pages. The measured value is recorded in Status.
  - If the assert fails, lower the shipped `theme.zon` `title` role size 2 pt
    at a time, down to a 24 pt floor. If it still fails at the floor, the
    measured pages are recorded in Status and the slice closes: the 8-page
    cap still holds with less slack, and 53A's page-cap rebuild keeps text
    correct (the overflow counter shows any rebuilds in soak dumps).
    `k_max_text_atlas_pages` and `k_text_atlas_size` never change.
  - CJK-scale policy is part of [Deferred By Owner → Full localization](../../framework-implementation-slices.md#deferred-by-owner).

**UI navigation SFX:**

- **Manifest.** `AudioAssetId` appends `ui_move_sfx`, `ui_confirm_sfx`,
  `ui_back_sfx`, `ui_denied_sfx`. `audio_assets` entries:
  `audio/sfx/ui_move.wav`, `ui_confirm.wav`, `ui_back.wav`, `ui_denied.wav`,
  all `.kind = .sfx, .predecode = true`.
- **Generation.** The WAVs come from the new `tools/generate_ui_sfx.py`
  (stdlib `wave`/`struct`/`math` only; deterministic; 48 kHz mono 16-bit;
  peak −6 dBFS; 5 ms attack, exponential decay; outputs committed):

  | Asset | Duration | Waveform |
  | --- | --- | --- |
  | `ui_move` | 60 ms | sine, 880 Hz |
  | `ui_confirm` | 110 ms | sine, 660 → 990 Hz two-step |
  | `ui_back` | 90 ms | sine, 660 → 440 Hz |
  | `ui_denied` | 120 ms | square, 220 Hz at −12 dBFS |

- **Cues.** `UiSound = enum { focus_move, activate, cancel, value_change,
  denied }` in `src/game/ui/types.zig`.
  - `UiTheme` gains `sounds: UiSoundTable { focus_move: ?AudioAssetId =
    .ui_move_sfx, activate = .ui_confirm_sfx, cancel = .ui_back_sfx,
    value_change = .ui_move_sfx, denied = .ui_denied_sfx, gain: f32 = 0.7,
    value_change_frequency_ratio: f32 = 1.12 }`.
  - It parses from `theme.zon` as enum literals. The theme `format_version`
    stays 1: new fields have defaults and the theme is a developer asset.
- **Queueing.** `UiScreen` holds `pending_sound: ?UiSound`. Queueing keeps the
  higher-priority cue (`denied > cancel > activate > value_change >
  focus_move`). Queue points:
  - 53B's internal focus setter (any source: action, hover, auto) →
    `focus_move`
  - `activated` / `list_activated` / `text_committed` → `activate`
  - `cancelled` → `cancel`
  - `value_changed` → `value_change`
  - activation or click on a disabled widget, 44's conflict rejection in
    `RebindCaptureState`, and 67C's text-field overflow → `denied`
  - The non-interactive HUD never queues.
- **Flush.** `UiScreen.pumpUpdate(audio: *AudioCommandBuffer, sounds: *const
  UiSoundTable) void` is called once at the top of every screen owner's
  `update`, before its `nextEvent` loop.
  - It plays at most one cue per screen per update step: `audio.playSfx(.{
    .asset, .gain = sounds.gain, .priority = 224, .frequency_ratio = (1.12
    for value_change else 1.0), .channel = .ui })`.
  - `error.AudioCommandLimitReached` is swallowed and a Debug counter
    `ui_sound_dropped` bumps: a UI sound never fails a state update.
  - `UpdateContext` gains `ui_theme: *const UiTheme` (Engine-owned, as in 53B).
- **Audio channel** (`src/app/audio.zig`). `PlaySfxRequest.channel: SfxChannel
  = .gameplay`, with `SfxChannel = enum { gameplay, ui }`; the track slot
  stores it. `stopAllSfx` (`:510-522`) skips `.ui` tracks.
  - Without this, a Resume confirm cue played in `update` would be cut about
    16 ms later by `pause.exit` → `setPaused(false)` → `stopAllSfx`.
  - UI cues are short one-shots on the SFX bus (user SFX volume), never
    looping, never spatial.

**Threading and allocation.** All main thread.
- Allocation-free after warmup: overlay draws, event-log push and draw,
  `pumpUpdate` into the reserved `AudioCommandBuffer`, and `.drawable` label
  draws.
- Label creates and `setText` are 53A's cold paths, bounded by content
  changes: at most 3 log lines per step, FPS never (digits are composed).

**Diagnostics.**
- `render` scope: `debug` on atlas rebuilds (53A).
- `game` scope: no per-event logs.
- Comptime-gated counters `ui_event_log_dropped`, `ui_sound_dropped`,
  `text_atlas_pages`, `text_atlas_rebuilds`.

### Checklist

- [ ] `text_labels.zig`: `LabelSpace` / `.drawable` draw, `pixelSize`,
      `lineHeightPx` (`LabelBackend.font_height`, cold), `atlasStats`.
      Fake-backend tests:
      - a drawable draw emits integer-pixel quads at `round(x) + dest_px`
        with no division
      - the clip works in drawable space
      - `lineHeightPx` refreshes on rebuild
      - stats count pages, rebuilds, and cap rebuilds
- [ ] `debug_text.zig` `DigitLabels` + constants, with tests:
      - `ensure` creates only missing or reclaimed ids (backend call count)
      - `drawNumber` advances by pixel widths and handles 0 and `maxInt(u32)`
- [ ] `FpsCounter` / `DebugOverlay` / stub migrated. Engine overlay calls
      updated. Tests:
      - a warmed prepare+render makes zero backend calls
      - reclaim then re-prepare re-creates all 11 labels
      - the command count stays ≤ 14
- [ ] `AiDebugOverlay` migrated: tint-colored behavior labels,
      `Renderer.worldToLogical` (pure test against
      `frameUniformForPresentation`'s `.world` transform at zoom 1 and 2),
      byte-based bounds. Update the worst-case capacity test
      (`ai_debug_overlay.zig:584-660`) to use fake-backend labels.
- [ ] Delete the `text.zig` path listed above, `drawablePixelScale`, and
      their tests. `zig build check` shows no remaining reference. Update the
      53A section's Scope bullet in the roadmap.
- [ ] `ui/event_log.zig` `EventLog` + `drawEventLog`. Tests:
      - coalescing within the visible window
      - a new line after expiry
      - 3-per-step budget with a `dropped` count
      - the slot-bound push re-texts exactly one slot
      - `(x{n})` formatting with saturation at 999
      - UTF-8-safe truncation at 96 bytes
      - expiry at 480 steps and fade alpha over the last 60
      - pause (no step advance) keeps lines
      - `push` across a `StepIndex` above `maxInt(u32)` keeps coalescing and
        expiry exact (no `u32` truncation)
      - draw order and clipping on a CPU-only renderer
- [ ] `event_log_feed.zig` exhaustive `lineFor` for every live arm, plus
      `GameDemoState.observeStepEvents` (single pass shared with the HUD
      counter, level-change line). Tests use a hand-built event slice, no
      world:
      - non-player arms map to `null`
      - `destructible_destroyed` text and key
      - coalesced bursts
      - HUD counter parity with the pre-67B count
- [ ] HUD `event_log_panel` + reservation (`spriteCommandCapacity` adds the
      576 bound) + panel visibility on dirty compare, with tests.
- [ ] Manifest IDs, `tools/generate_ui_sfx.py`, and the four committed WAVs
      (`zig build assets-lint` passes). The startup manifest coverage test
      (`manifest.zig:191-207`) covers them.
- [ ] `audio.zig` `SfxChannel` + `stopAllSfx` skip. Test (fake backend):
      `setPaused` stops a gameplay one-shot and keeps a `.ui` one.
- [ ] `UiSound`, `UiSoundTable` theme fields (shipped `theme.zon` updated),
      `UiScreen.pending_sound` priority, `pumpUpdate`,
      `UpdateContext.ui_theme`, and `pumpUpdate` calls in every screen owner
      (main menu, settings, pause, confirm dialog, controls, rebind capture,
      save/load). Tests:
      - each queue point
      - priority merge
      - one cue per step
      - `AudioCommandLimitReached` swallowed with the counter bumped
      - for each migrated menu, activation leaves a `ui_confirm_sfx`
        `play_sfx` command in the buffer
- [ ] gpu-smoke Western-corpus atlas probe (`ui_scale_percent = round(450 /
      s)`) + `assets/test/text_corpus_western.txt`, and the 53A
      unclamped-`ui_scale_percent` fake-backend test. Perf-log atlas metrics.
- [ ] `FailingAllocator` proofs:
      - (a) warmed FPS + AI overlay draw into a reserved CPU-only renderer
      - (b) `EventLog.push` + `drawEventLog` for a step with 3 appends and a
        coalesce
      - (c) `pumpUpdate` into a reserved `AudioCommandBuffer`
      - (d) a `.drawable` label draw
- [ ] Bench group `ui-event-log-feed` (`src/benchmarks/ui.zig`; serial-direct;
      item counts from `suite.eventScaleCounts`). Workload: a merged event
      slice of mixed payloads with 1% player-facing, through
      `observeStepEvents`.
- [ ] Docs:
      - `docs/rendering-assets-shaders.md`: rewrite Text Rendering (labels
        only; `PreparedText` removed; atlas telemetry and the probe number);
        rewrite Debug Overlay (labels, mono role, presentation-scale sizing)
      - `docs/architecture.md`: text ownership paragraph; event-log
        presentation boundary; UI audio channel
      - `docs/development-workflow.md`: `tools/generate_ui_sfx.py`
      - `src/tests.zig` registrations

### Acceptance checks

- [ ] `zig build verify` passes. No source file references `PreparedText`,
      `TTF_RenderText_Blended`, `TextEntrySlot`, or `drawablePixelScale`.
- [ ] `zig build bench -- --group ui-event-log-feed` runs; the baseline is
      recorded in Status.
- [ ] `zig build gpu-smoke` reports the Western-corpus page count ≤ 6 (or,
      after the title-size floor, the recorded terminal outcome). The
      measured value is recorded in Status.
- [ ] Manual (display):
      - F2 shows crisp FPS and AI HUD text at 1280×720, ~1.5× fit, and HiDPI
      - behavior labels sit above the drive bars at every zoom
      - destroying obstacles produces coalescing, fading log lines
      - menus play move/confirm/back cues
      - Resume from the pause menu plays its confirm cue in full
- [ ] Review check: the event-log feed has no `else` arm and reads events
      only after the step finishes; no `src/game/` file touches `TTF_*`.

### VoidLight reference

- **Port:**
  - `src/managers/UIManager.cpp:480-493` `createEventLog`
  - `:1142-1166` `addEventLogEntry` (FIFO trim to max entries)
  - `include/managers/UIConstants.hpp:104-106` (5 entries, 30% width;
    adapted to 6 rows, 460 px)
  - controller-originated combat/social log lines
    (`src/controllers/combat/CombatController.cpp:173-261`,
    `src/controllers/social/SocialController.cpp:257-701`), as typed-event
    feed arms
- **Do not port:**
  - controllers calling `UIManager::Instance().addEventLogEntry` directly
  - string log IDs, `std::string` entries, and `vector::erase` trimming
  - the `EventLogState` auto-update demo timer
    (`include/managers/UIManager.hpp:265-270`)
  - per-size font reload for debug text

---

