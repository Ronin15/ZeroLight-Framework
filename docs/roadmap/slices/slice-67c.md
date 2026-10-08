## Slice 67C: Save Slot Presentation — Thumbnails, Named Saves, And The Text-Input Widget

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 46](slice-46.md), [Slice 60](slice-60.md), [Slice 67A](slice-67a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Render, app, and game-UI work. Depends on:
- Slice 46: slots, the 128-byte `SaveSlotHeader` (format v1), lane jobs,
  slot scan, `SaveLoadMenuState`, `saveGame`, and its pause-stack render
  policy
- Slice 60: final `endFrame` composite structure, which the thumbnail replay
  builds on
- Slice 67A: `EventContext` pointer, so a click begins editing
- Slices 53A/53B: labels and the toolkit

Goal:
- Every save slot shows a 160×90 picture of the world as it was when saved,
  and an optional player-typed name.
- Getting there needs three things:
  - **GPU world-only thumbnail capture.** It is not a swapchain readback: see
    the decision below.
  - **A header-only save `format_version` bump** (live value + 1; v2 in the
    merged order). It adds a thumbnail section and a name, and files of the
    immediately previous version stay loadable.
  - **A reusable `text_field` widget.** It uses SDL3 text input, inline IME
    composition, and fixed UTF-8 buffers. Save naming is its first consumer.

### Current foundation

- `src/render/renderer.zig`:
  - `:669-832` `endFrame`
    - CPU prep and staging before acquire
    - one render pass over `draw_list`
    - per-group `applyGroupPresentation` / texture / tilemap binds
      (`:744-824`)
    - `SDL_SubmitGPUCommandBuffer` (`:828`)
  - `:345`: `target_format` from `SDL_GetGPUSwapchainTextureFormat` is a local
    that is not retained
  - `:946-953` `createTextureFromPixels`
  - `:1143-1160` `replaceTextureFromPixels` (waits idle before release)
  - `:574-578` `destroyTexture` (idles)
- `src/render/sprite_batch.zig:218-234`: every `DrawGroup` carries `order:
  RenderOrder`, whose `domain` is `.world` / `.ui` / `.debug` (`:46-50`).
- **SDL citations** below are SDL 3.4.18, the 52A pin; line numbers are from
  VoidLight's vendored source (`VoidLight-Framework/build/_deps/sdl3-src`,
  `SDL_version.h` 3.4.18). The live tree still pins 3.4.10
  (`build.zig.zon:17`) until 52A lands; 67C lands after 52A, and the cited
  declarations exist in both.
- **Swapchain readback is not possible.** In SDL 3.4.18
  `src/gpu/vulkan/SDL_gpu_vulkan.c:4776-4778`, Vulkan swapchain images get
  only `COLOR_ATTACHMENT | TRANSFER_DST`, with no `TRANSFER_SRC`, so
  `SDL_DownloadFromGPUTexture` / `SDL_BlitGPUTexture` from the swapchain
  texture is invalid. SDL-created textures always get `TRANSFER_SRC |
  TRANSFER_DST` (`:5748`). SDL documents readback as download → fence →
  map (`SDL_gpu.h:96-103`).
- `src/app/resolution.zig:74-128`: `computePresentation` (any size) and
  window→logical. There is no logical→window helper yet.
- `src/render/gpu/device.zig:43-49`: `SDL_SetGPUSwapchainParameters(...,
  SDL_GPU_SWAPCHAINCOMPOSITION_SDR, ...)`, so the swapchain format is a
  `_UNORM` format and the shader output is stored without sRGB encoding;
  `src/render/gpu/texture.zig:68`: sampled textures are
  `R8G8B8A8_UNORM`.
- Slice 46:
  - the 128-byte `SaveSlotHeader` table, with `reserved` validated zero
  - "No thumbnail in v1 … a later header version adds a section"
  - `saveGame(slot)` → `captureSave` at the paused quiescent point
  - Engine-owned encode buffer, lane `submit` / `isDone` / `complete`
  - slot scan of 8 headers on the lane
  - `SaveLoadMenuState` (8 slot buttons; overwrite confirm)
  - `LoadError.SaveCorrupt`
- SDL 3.4:
  - `SDL_StartTextInputWithProperties` and the `SDL_PROP_TEXTINPUT_*`
    properties (`SDL_keyboard.h:473-478`)
  - `SDL_StopTextInput` (`:511`), `SDL_SetTextInputArea(window, rect,
    cursor)` (`:550`, window coordinates)
  - `SDL_TextInputEvent.text` and `SDL_TextEditingEvent { text, start, length
    }` (`SDL_events.h:384-433`). The text is an SDL temporary string, valid
    only while the event is processed.
  - `SDL_HINT_IME_IMPLEMENTED_UI` (3.4.18 `SDL_hints.h:1236-1256`, define at
    `:1256`): "composition" makes the app render preedit text. It must be set
    before `SDL_Init`.
  - Editing `start` / `length` units are not uniform across backends: IBus
    sends characters (`src/core/linux/SDL_ibus.c:248-258`); Windows sends
    UTF-16 units (`SDL_windowskeyboard.c:930-934`).
- 53A labels: `TextLabelSystem.create` / `setText` / `logicalSize`, raster
  scale `s`, and a 256-byte label cap.

### Architecture notes

**Thumbnail capture** (`src/render/thumbnail_capture.zig`, render-internal,
behind `Renderer` facades):

- **Decision: offscreen replay of the frame's world-domain draw groups.** In a
  frame with a pending request, after the main pass, the renderer records a
  second render pass into a renderer-owned color target using the same
  `draw_list` (vertex data already uploaded by that command buffer's copy
  pass). It keeps only groups with `order.domain == .world`.
  - That pass excludes the pause and save menus, the HUD (`.ui`), and the
    debug overlays (`.debug`) by construction, with no per-state hooks.
  - It is ungraded: it replays world groups directly and never samples Slice
    60's scene texture or grade. It therefore works unchanged in both Slice
    70B `scene_resolution` modes (70B makes the mode runtime-switchable):
    the world groups and their `.world` frame uniform are the same input in
    either mode, and only the presentation computed below is used.
  - **Requires world groups in the save-menu frame.** `StateStack.render`
    walks down only while each state's `policy.render_below` is true
    (`src/app/state.zig:33`, `:522`). `SaveLoadMenuState` in save mode and
    every state between it and `GameDemoState` (the pause state) must use a
    `render_below = true` policy (the `modal_overlay` shape,
    `state.zig:645`). Otherwise the frame has no world groups and every
    capture times out to `failed`. This is a 46 requirement that 67C states
    and tests (Checklist; the Slice 67 requirement folded into [Slice 46](slice-46.md)).
- **Sizes and format.**
  - Render target `k_thumbnail_render_width × height = 320 × 180`
    (`k_thumbnail_supersample = 2`), in the retained swapchain format. New
    field `Renderer.swapchain_format` is stored from `:345`, because the
    sprite and tilemap pipelines are built for that format. Usage is
    `COLOR_TARGET`.
  - Presentation: `resolution.computePresentation(self.resolution_policy,
    .{320, 180}, .{320, 180})`. A 16:9 logical size fills it exactly; other
    aspects letterbox with the clear color.
- **Readback.** A copy pass runs `SDL_DownloadFromGPUTexture` into a download
  transfer buffer (`SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD`, 320 × 180 × 4 =
  230,400 bytes). The frame then submits with
  `SDL_SubmitGPUCommandBufferAndAcquireFence` instead of `:828`'s plain
  submit.
  - At the start of each later `endFrame`, `SDL_QueryGPUFence` is checked.
    Once signaled:
    1. Map (`cycle = false`).
    2. Run pure `downsampleBox2x(src, 320, 180, order, dst)`: a 2×2 box
       filter, BGRA/RGBA swizzle by format, alpha forced to 255.
    3. Write into `pixels: *[k_thumbnail_bytes]u8` (`k_thumbnail_bytes = 160 ×
       90 × 4 = 57,600`).
    4. Unmap, then `SDL_ReleaseGPUFence`.
  - There is no `SDL_WaitForGPUIdle` and no frame stall.
  - The fence makes this safe at any `frames_in_flight`.
  - Supported swapchain formats: `B8G8R8A8_UNORM` → bgra and
    `R8G8B8A8_UNORM` → rgba. The downloaded bytes are then exactly what the
    main pass stores, and the catalog texture (`R8G8B8A8_UNORM`, 53A/46
    `createTextureFromPixels`) samples them back unchanged, so the picture
    matches the screen. `_SRGB` formats are **rejected**: the renderer
    requests `SWAPCHAINCOMPOSITION_SDR` (`device.zig:46`), which never yields
    one, and accepting one would store sRGB-encoded bytes into a UNORM
    texture that the UNORM swapchain then shows encoded a second time. Any
    other format (including `_SRGB`) → `failed` with one `warn`.
- **State machine.** Pure and unit-tested; the GPU glue around it is thin:

  ```zig
  pub const ThumbnailState = enum { idle, requested, in_flight, ready, failed };
  ```

  - `requestWorldThumbnail() u32` moves `idle`, `ready`, or `failed` to
    `requested` and returns the target `epoch + 1`. In `requested` or
    `in_flight` it returns the pending target.
  - A frame with ≥ 1 world group records the capture → `in_flight`.
    `k_thumbnail_request_max_frames = 30` consecutive frames without world
    groups → `failed`.
  - Fence signaled → `ready`, `epoch += 1`.
  - Accessors: `thumbnailEpoch() u32`, `thumbnailState()`, and
    `thumbnailPixels() ?*const [k_thumbnail_bytes]u8` (non-null only when
    `ready`).
- **Ownership and lifetime.** The target, download buffer, and `pixels`
  (renderer allocator) are created on the first request (cold) and reused
  afterwards. `deinit` releases them after its existing `waitForIdle`,
  including any unreleased fence.
- **Refactor.** The main loop body (`:744-824`) moves into
  `recordDrawList(render_pass, command_buffer, presentation, groups,
  domain_filter: ?RenderDomain)`. The main pass calls it with `null`; the
  thumbnail pass with `.world`.
- **Request timing.**
  - `SaveLoadMenuState` (save mode) calls
    `context.renderer.requestWorldThumbnail()` once on its first `render` and
    stores the returned epoch.
  - The world is frozen while paused, so the capture equals the saved state.
  - The capture is recorded in that same frame (endFrame runs after state
    render) and is normally `ready` 1–3 frames later, long before the user
    picks a slot.

**Save header format bump and file layout** (Slice 46 amended):

- `k_save_format_version` = live value + 1 (v2 in the merged order, directly
  after 46's v1). Writes are always the current version. The loader also
  accepts the immediately previous version, because this bump is
  header-only and bytes 76–127 were validated zero. That acceptance ends at
  the next payload bump: per 46's policy, a bump that adds or changes a
  payload section rejects every older file with `SaveVersionUnsupported`
  (slot shows "Incompatible version"); only a header-only bump keeps its
  predecessor.
- The new fields occupy the start of 46's `reserved` region. 46's header
  pins every offset with comptime `@offsetOf` asserts, including its
  explicit `reserved_pad0: [4]u8` at 36 (validated zero), so `reserved`
  starts at offset 76 after `world_levels` (74). Each new offset is pinned
  the same way, and `@sizeOf == 128` still holds:

  | Offset | Field | Type / rule |
  | --- | --- | --- |
  | 76 | `thumbnail_bytes` | u32: 0 or exactly 57,600 |
  | 80 | `thumbnail_crc32` | u32: `std.hash.Crc32` of the section |
  | 84 | `thumbnail_width` | u16: 0 or 160 |
  | 86 | `thumbnail_height` | u16: 0 or 90 |
  | 88 | `thumbnail_format` | `SaveThumbnailFormat = enum(u8) { none = 0, rgba8 = 1 }` |
  | 89 | `slot_name_len` | u8 ≤ `k_save_slot_name_capacity = 32` |
  | 90 | `slot_name` | [32]u8: valid UTF-8, no C0/DEL, zero tail |
  | 122 | `reserved` | [6]u8: zero (gated Slice 69F later takes `region_x: i16` @122 and `region_y: i16` @124, leaving `[2]u8` @126) |

- **File layout.** `header (header_bytes = 128) | thumbnail (thumbnail_bytes)
  | payload (payload_bytes)`. The payload offset is `header_bytes +
  thumbnail_bytes`. The file size must equal the sum, else `SaveCorrupt`.
- **Previous-version files.** Their bytes 76–127 are 46's validated-zero
  `reserved`, which read as "no thumbnail, empty name" under the same struct.
  No separate parser.
- **Validation.** Any thumbnail field combination other than (0, 0, 0, none)
  or (57,600, 160, 90, rgba8), or an invalid name, is `SaveCorrupt`. The slot
  shows "Corrupt", as 46 does.
- **Thumbnail CRC mismatch** is **not** an error. The scan marks the slot's
  thumbnail invalid (one `debug` log) and shows the placeholder. A load seeks
  past the section and never reads it, so a damaged picture never blocks a
  load.
- **Unaffected.** `payload_crc32`, `sim_checksum`, `build_fingerprint`, and
  `content_fingerprint` keep their meaning. The thumbnail and name are
  presentation data outside Slice 49's checksum.
- **Payload-purity test (46).** It now allows exactly two more things: the
  thumbnail section (pixels only) and the header name. Neither holds a path
  or a handle.
- **Slice 46's save-size bound (`k_max_save_file_bytes`)** covers header +
  thumbnail + payload; the 57,600-byte thumbnail counts against it. Slice 46
  owns that bound's value and sizing; 67C does not restate it.

**Save flow (Engine, 46 amended):**

- **Request.** `StateTransitions.saveGame(request: SaveRequest)` with
  `SaveRequest { slot: SaveSlot, name: [32]u8, name_len: u8,
  thumbnail_epoch: u32 }`. It is fixed-size and needs no allocation.
- **Encode.** On `TransitionApplyResult.save_slot`, Engine runs `captureSave`
  and encodes the payload immediately (46's quiescent point). The encode
  buffer reserves `128 + 57,600` leading bytes.
- **Pending save.** Engine stores `pending_save { request, buffer,
  frames_waited }` and publishes `SaveStatus.saving`.
- **Waiting for the picture.** Each frame, after `renderFrame`:
  - `renderer.thumbnailEpoch() >= request.thumbnail_epoch` and `ready` →
    copy the pixels into the section and fill the header fields + CRC.
  - Else `failed`, or `frames_waited == k_save_thumbnail_wait_frames = 8` →
    `thumbnail_bytes = 0`. The buffer is compacted by moving the payload down
    57,600 bytes (cold memmove).
  - Otherwise wait.
- **Submit.** Then 46's lane `submit` runs as before. The sim is paused
  throughout, so the capture point stays valid.
- **Deinit.** `Engine.deinit` with a `pending_save` finalizes it without a
  thumbnail and submits and completes it before `background_lane.deinit`
  (46's lifetime rule).
- **After save success.** Engine copies the saved thumbnail into the catalog
  cell and re-uploads (below). No rescan is needed.

**Slot thumbnails in the menu:**

- **`SaveSlotCatalog`** (`src/app/save_slots.zig`, the Engine-owned holder of
  46's scan results; extended in place if 46 already created it):
  - `summaries: [k_save_slot_count]?SlotSummary`, with `SlotSummary` gaining
    `name` / `name_len`
  - `thumbnail_valid: [8]bool`
  - `atlas_pixels: []u8`: 640 × 180 × 4 = 460,800 bytes, allocated once at
    `Engine.init`; slot `i` is the cell (`i % 4` × 160, `i / 4` × 90)
  - `thumbnail_texture: TextureId`: created at `Engine.init` after the
    renderer with `createTextureFromPixels`, destroyed in `Engine.deinit`
    before `renderer.deinit`
  - `epoch: u32`
- **Placeholder.** Invalid or empty cells are filled with opaque RGBA (32,
  34, 38, 255).
- **Scan job** (46's lane job, extended):
  - It reads each header. For a current-version header with a thumbnail it
    reads the section,
    checks the CRC, and writes the pixels straight into `atlas_pixels` at the
    cell (row stride 640 × 4).
  - The buffer is lent to the job while it is in flight; Engine does not
    touch it until `complete`.
  - On `complete`, the main thread calls
    `renderer.replaceTextureFromPixels(thumbnail_texture, atlas_pixels, 640,
    180, 2560)` and bumps `epoch`. This is a cold path; its `waitForIdle` is
    acceptable on a menu.
- **Context.** `RenderContext.save_slots: *const SaveSlotCatalog`.
- **53B image source.** The `image` widget's source becomes
  `ImageSource = union(enum) { sprite: SpriteRef, texture: TextureRegion }`
  with `TextureRegion { texture: TextureId, source: Rect }`. Thumbnails are
  the `.texture` arm's consumer. A `TextureId` in screen state is render-side
  state, never `DataSystem`.
- **Slot rows.** Each `SaveLoadMenuState` row becomes an `hstack` of
  `[image 160×90 (cell rect of the catalog texture) | button]`. Button text:
  "{name or "Slot N"} — Level 4 — 2026-10-05 14:03 — 1:23:45", ≤ 128 bytes.
  The 53B scroll absorbs the taller rows.

**Named saves** (`src/game/save_name_dialog_state.zig`, `SaveNameDialogState`,
modal):

- **Replaces 46's overwrite confirm.** In save mode, activating any slot
  pushes this dialog with `{ slot, existing name, occupied: bool,
  thumbnail_epoch }`.
- **Widgets:**
  - title: "Save to Slot N" or, when occupied, "Overwrite {name}?"
  - `name`: a `text_field` with `max = 32`, pre-filled with the existing name
    or "Save N"
  - an `hstack` of [Save, Cancel]
  - a hint footer
- **Behavior.**
  - The field starts in edit mode, so keyboard users type at once.
  - `text_committed(name)` or Save `activated` → the name is trimmed of ASCII
    spaces at both ends; empty becomes "Save N". Then
    `transitions.saveGame(...)` and `pop()`.
  - `cancelled` (Escape or East outside editing) → `pop()`.
  - Gamepad: South while editing commits, which saves the default name with
    one press. East while editing ends editing; East again cancels.
  - The SDL screen keyboard appears wherever SDL shows it for
    `SDL_StartTextInput`. There is no in-game on-screen keyboard.

**`text_field` widget** (53B toolkit; new `WidgetKind.text_field`; pure
UTF-8 helpers in `src/game/ui/text_edit.zig`):

- **Columns.** It reuses `text` (committed UTF-8, ≤ `max` bytes ≤
  `k_widget_text_capacity` 128, enforced at `build()`), `max` (byte
  capacity), and `label` / `value_label` (the display label). It is
  focusable.
- **Edit session.** At most one per screen (fixed field):

  ```zig
  EditSession {
      widget: u8,
      caret: u8,
      original: [128]u8,
      original_len: u8,
      preedit: [k_ime_preedit_capacity]u8,
      preedit_len: u8,
      preedit_cursor_cp: i32,
      preedit_sel_cp: i32,
      display_dirty: bool,
      caret_x: f32,
      preedit_x: [2]f32,
      sel_x: [2]f32,
      scroll_x: f32,
      last_edit_ns: u64,
  }
  ```

  `k_ime_preedit_capacity = 64` bytes; a longer preedit is truncated on a
  code-point boundary for display only.
- **Begin.** `beginEdit(w)` runs on confirm (`resume_game`), on a
  `primary_up` click (67A; the caret goes to the end, with no click-to-caret
  positioning), or via `setEditing(w)`. It snapshots `original`.
- **Input vocabulary** (`src/app/input.zig`, resolved by Engine per event):

  ```zig
  pub const EditKey = enum { backspace, delete, left, right, home, end, commit, cancel };
  pub const TextEdit = union(enum) {
      insert: []const u8,                // SDL_EVENT_TEXT_INPUT text (valid during dispatch only)
      compose: struct { text: []const u8, start: i32, length: i32 }, // SDL_EVENT_TEXT_EDITING
      key: EditKey,                      // KEY_DOWN (repeat included) by scancode
  };
  ```

  - Scancode → `EditKey`: BACKSPACE, DELETE, LEFT, RIGHT, HOME, END, RETURN
    and KP_ENTER → `commit`, ESCAPE → `cancel`.
  - Engine always resolves `text` and `keyboard_event`. The field ignores them
    unless editing.
- **While editing,** `UiScreen.handleEvent` gives the session precedence and
  **consumes every event with `keyboard_event` or `text != null`**. Rebound
  letters therefore type instead of navigating, and nothing reaches the
  router. F2 is consumed while editing; this is documented.
  - `insert`:
    - drops the whole string if it is invalid UTF-8
      (`std.unicode.utf8ValidateSlice`)
    - filters C0 controls and DEL
    - inserts the longest code-point-aligned prefix that fits `max`
    - queues `denied` (67B) if anything was cut
    - clears the preedit
  - `compose`:
    - copies into `preedit` (display-truncated)
    - `start` / `length` are treated as **code-point** indices, clamped to the
      preedit's code-point count; −1 means unset (caret at the preedit end, no
      selection)
    - the Windows UTF-16 vs code-point mismatch affects only non-BMP
      composition characters and is documented
    - an empty text clears the preedit
  - `key`:
    - backspace/delete remove the previous/next code point (scanning
      continuation bytes `0b10xxxxxx`); left/right move by code point;
      home/end
    - `commit` → end the session and emit the new `UiEvent` arm
      `text_committed: W`
    - `cancel` → restore `original`, end the session, no event
  - Gamepad `press` (when `device == .gamepad`): `resume_game` → commit,
    `quit` → cancel.
  - A pointer `primary_down` outside the field commits, then is processed
    normally.
  - There is no grapheme-cluster editing (combining marks delete separately);
    this is documented.
- **Display and measurement.**
  - The display string is `text[0..caret] ++ preedit ++ text[caret..]`, ≤ 192
    bytes, within 53A's 256-byte label cap. 53B's build-time
    `drawCommandBound()` counts a `text_field` as `max +
    k_ime_preedit_capacity` glyph quads plus its caret, selection, and
    preedit-underline rects (a fixed per-field count set at `build()`), never
    the live display length. `setText` runs only when
    `display_dirty` (cold, per keystroke).
  - Caret, preedit, and selection x offsets come from a new cold 53A API:
    `labels.textOffsetX(id, byte_offset) ?f32`, through `LabelBackend.sub_string_x`
    → `TTF_GetTextSubString(text, offset, &sub)`. It returns `sub.rect.x` / `s`
    (logical); an offset at the end yields the end-of-text zero-width
    substring.
  - It is called only after a display change or a `layoutEpoch()` change and
    the results are cached in the session. `draw` never calls it.
  - `scroll_x` keeps the caret inside the field's content rect: `scroll_x =
    clamp(scroll_x, caret_x − (content_w − 4), caret_x)`. The label is drawn
    at `x − scroll_x` through the clipped facade.
- **Draw** (bound per field = 1 panel + 4 border + 192 text + 1 caret + 2
  underline = 200):
  - field box: theme `panel` / `panel_border`
  - text
  - preedit underline: 1 logical px, `colors.ime_underline`
  - selected-segment underline: 2 px
  - caret: `metrics.caret_width = 2` × line height, `colors.caret`, visible
    when `((frame_start_ns − last_edit_ns) / k_caret_blink_half_period_ns) %
    2 == 0` with `k_caret_blink_half_period_ns = 530 ms`
- **Theme additions** (defaults; shipped `theme.zon` updated):
  `metrics.text_field_width = 400`, `metrics.caret_width = 2`,
  `colors.caret`, `colors.ime_underline`.

**Text input lifecycle** (`src/app/text_input.zig`, `TextInputController`, an
Engine field):

- **Claim.** A per-frame claim, so no state can forget to stop text input:
  - `RenderContext.text_input: *TextInputClaim` with `TextInputClaim { active:
    bool, area: Rect (logical), cursor_x: f32 (logical, relative to area.x) }`.
  - Engine resets it before `states.render`. A field with an edit session
    calls `claim()` in its render.
- **Apply.** After `states.render`, `applyClaim(window, renderer)` runs the
  pure `nextAction(applied, claim) TextInputAction = enum { none, start, stop,
  update_area }`. Area changes under 1 window px are `none`.
  - `start` → `sdl.startTextInput(window)`, which calls
    `SDL_StartTextInputWithProperties` with `TYPE_NUMBER = SDL_TEXTINPUT_TYPE_TEXT`,
    `CAPITALIZATION_NUMBER = SDL_CAPITALIZE_NONE`, `AUTOCORRECT_BOOLEAN =
    false`, `MULTILINE_BOOLEAN = false`.
  - `stop` → `sdl.stopTextInput(window)`.
  - `start` and `update_area` → `sdl.setTextInputArea(window, rect,
    cursor)`. The rect comes from the new facade
    `Renderer.logicalRectToWindow(rect) ?WindowRect` over the new pure
    `resolution.logicalToWindow(point, policy, window_size, drawable_size)
    !Point` (logical × viewport scale + offset → drawable ×
    window/drawable).
- **Frames that cannot render** (`!frame_policy.can_render`) skip `applyClaim`
  and keep the current state, so a minimize does not flap stop/start.
- `Engine.deinit` stops text input if active.
- **IME hint.** `Engine.init` calls `sdl.setHint(SDL_HINT_IME_IMPLEMENTED_UI,
  "composition")` **before** `SdlContext.init`: ZL renders the preedit,
  while candidate lists stay native. gpu-smoke does not set it.

**Fixed budgets:**

| Constant | Value |
| --- | --- |
| thumbnail | 160×90 RGBA8 = 57,600 B; render 320×180; download 230,400 B |
| `k_thumbnail_request_max_frames` | 30 |
| `k_save_thumbnail_wait_frames` | 8 |
| catalog atlas | 640×180 RGBA8 = 460,800 B |
| `k_save_slot_name_capacity` | 32 |
| `k_ime_preedit_capacity` | 64 |
| `text_field` `max` | ≤ 128 (build-checked) |
| `k_caret_blink_half_period_ns` | 530 ms |
| edit sessions | ≤ 1 per screen |

**Errors.**
- `UiBuildError` gains `UiTextFieldCapacity`: `max` is 0 or > 128.
- `LoadError` is unchanged; every violation of the new header fields is
  `SaveCorrupt`.
- Thumbnail capture failure is a state, not an error: one `warn`, then the
  save proceeds without a picture.
- The platform text-input wrappers return `error{SdlError}`. Engine logs
  `warn` once and keeps the field usable; text then arrives only if SDL
  delivers it.

**Threading and allocation.**
- All capture, readback, downsample, editing, and claim work is main-thread.
- The scan and write stay on 46's lane, with buffers lent through
  `submit`/`complete`.
- Edit operations, claim diffing, and the warmed second thumbnail cycle
  allocate nothing. The first capture allocates its target, buffer, and
  pixels once (cold).

**Diagnostics.**
- `render` scope: `debug` on capture recorded and ready; `warn` once on
  `failed`.
- `app` scope:
  - `debug` on text input start/stop
  - `debug` when a save proceeds without a thumbnail, with the reason
  - `debug` on a scan CRC mismatch
- Comptime-gated counters `thumbnail_captures`, `text_input_starts`.

### Checklist

- [ ] `thumbnail_capture.zig`:
      - pure `ThumbnailState` machine and `downsampleBox2x`
      - `Renderer.swapchain_format`
      - `recordDrawList` refactor with `domain_filter`
      - capture pass + download + fence submit + poll/map/unmap
      - facades `requestWorldThumbnail` / `thumbnailEpoch` / `thumbnailState`
        / `thumbnailPixels`
      - deinit release

      Tests:
      - every transition, including the 30-frame failure and repeated
        requests returning the pending epoch
      - box filter on known 2×2 blocks for both channel orders, alpha forced
        255
      - the format gate accepts `B8G8R8A8_UNORM` / `R8G8B8A8_UNORM` and
        rejects both `_SRGB` variants and any other format → `failed`
      - `recordDrawList` filter selects only `.world` groups from a mixed
        list (pure group-selection helper)
- [ ] `resolution.logicalToWindow` + `Renderer.logicalRectToWindow`. Tests:
      round-trip with `windowToLogical` at fit / integer_fit / overscan and at
      HiDPI.
- [ ] Header format bump:
      - fields, comptime offset asserts, `k_save_format_version` = live
        value + 1
      - the immediately previous version accepted as no-thumbnail and empty
        name; two versions back → `SaveVersionUnsupported`
      - validation into `SaveCorrupt`
      - payload offset from `header_bytes + thumbnail_bytes`
      - thumbnail CRC mismatch is non-fatal on scan and skipped on load

      Tests:
      - each rejection reason
      - a previous-version fixture loads; a fixture with `format_version`
        two below current is rejected
      - a corrupted thumbnail byte loads fine and scans with
        `thumbnail_valid = false`
      - the payload-purity test amended
- [ ] Engine save flow: `SaveRequest`, `pending_save` wait / finalize /
      compact, deinit finalize. Inline-lane tests:
      - ready-before-request includes the picture
      - `failed` saves without it after compaction (round-trip loads)
      - the 8-frame timeout path
      - deinit with a pending save writes a complete file
- [ ] `SaveSlotCatalog`:
      - atlas pixels and texture create/destroy
      - scan job writes cells
      - `complete` re-uploads
      - save success updates one cell

      Tests (CPU-side): cell placement and stride; placeholder fill.
- [ ] 53B `ImageSource.texture` arm + draw. `SaveLoadMenuState` rows with
      thumbnails, names, and the thumbnail request on first render. Tests:
      - row text formatting with and without a name
      - the request happens once
      - with the pause stack built as in play (`GameDemoState` → pause →
        `SaveLoadMenuState` in save mode), `StateStack.render` reaches
        `GameDemoState`, and the CPU-only renderer's draw list holds ≥ 1
        `.world` group (so the capture is recorded, not timed out)
- [ ] `SaveNameDialogState`, replacing 46's save-mode overwrite confirm.
      Test: `text_field` `drawCommandBound()` is unchanged across insert and
      compose. Keyboard, gamepad, and pointer tests:
      - default name
      - trim
      - empty → "Save N"
      - South-commit saves with one press
      - Escape ends editing, then cancels
      - a click on Save commits the edit first
- [ ] `text_edit.zig` pure UTF-8 helpers. Tests:
      - insert at caret with a code-point-aligned partial fit and the denied
        flag
      - invalid UTF-8 dropped
      - C0/DEL filtered
      - backspace/delete over 1–4-byte sequences
      - caret moves
      - code-point → byte mapping for the preedit cursor, with clamping
- [ ] `WidgetKind.text_field`, `EditSession`, `UiEvent.text_committed`,
      `UiTextFieldCapacity`, session precedence and consumption, display
      composition, scroll_x, draw, and caret blink. 53A `textOffsetX` +
      `LabelBackend.sub_string_x`. Tests (fake label backend):
      - a rebound letter types instead of navigating
      - all key events are consumed while editing
      - preedit display and underline rects
      - `textOffsetX` is called only on display or epoch change
      - the caret blinks on `frame_start_ns`
- [ ] `input.zig` `EditKey` / `TextEdit` / `textEditForEvent` and
      `EventContext.text` / `keyboard_event`. Engine resolution. Tests with
      synthetic TEXT_INPUT, TEXT_EDITING, and KEY_DOWN (repeat) events.
- [ ] `text_input.zig` `TextInputController` + pure `nextAction` +
      `RenderContext.text_input`. `sdl.startTextInput` / `stopTextInput` /
      `setTextInputArea` / `setHint`. IME hint before `SdlContext.init`.
      Deinit stop. Tests:
      - `nextAction` table: start, stop, area-change threshold, no change
      - a dialog pop stops input on the next frame (claim absent)
      - a non-rendering frame skips apply
- [ ] `FailingAllocator` proofs:
      - (a) a warmed edit session with insert/compose/keys + render on a
        CPU-only renderer, fake label backend
      - (b) `nextAction` / claim reset
      - (c) the second thumbnail state-machine cycle + `downsampleBox2x` into
        the preallocated pixels
      - (d) current-version header encode/validate with a preallocated
        buffer
- [ ] gpu-smoke:
      - a world quad + a `.ui` rect; request a thumbnail; poll until `ready`
        (≤ 30 frames)
      - assert the downsampled pixels contain the world quad's exact color
        (no sRGB re-encoding) and not the UI rect's
      - start and stop text input on the smoke window
- [ ] Extend Slice 46's `save-encode` bench group with a case that assembles a
      current-version file with a thumbnail section (same group,
      `suite.zig` convention).
- [ ] Docs:
      - `docs/architecture.md` save boundary: the header format bump and
        loader policy, the thumbnail as
        presentation data outside the checksum, why there is no swapchain
        readback
      - `docs/rendering-assets-shaders.md`: thumbnail capture
        (domain-filtered replay, fence, formats, ungraded)
      - `docs/state-stack-and-input.md`: text input lifecycle, IME, edit
        keys, named saves
      - `src/tests.zig` registrations

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `zig build gpu-smoke` captures a world-only thumbnail (UI excluded)
      within 30 frames with no `SDL_WaitForGPUIdle` on the capture path.
- [ ] Manual (display):
      - save from pause → each slot shows the paused world without the pause
        or save menus or the HUD
      - a renamed slot shows its name after restart
      - a save from the previous format version (a Slice 46 build in the
        merged order) loads and shows a placeholder
      - a hand-corrupted thumbnail byte still loads the game
- [ ] Manual (Linux fcitx5 or IBus Japanese input; Windows Microsoft IME when
      available):
      - composition renders inline with an underline
      - candidates appear near the field
      - committing inserts the converted text
      - Escape mid-composition behaves per the IME
- [ ] `zig build bench -- --group save-encode` runs with the thumbnail case;
      the
      result is recorded in Status.
- [ ] Review check:
      - no `src/game/` file calls SDL text-input functions
      - `src/game/` stores no thumbnail pixels
      - `DataSystem` holds no `TextureId`

### VoidLight reference

- **Port:**
  - `src/managers/UIManager.cpp:373` `createInputField`
  - `:1298` `isInputFieldFocused`: a focused input field captures typing
    (here `EditSession` precedence)
  - the 46 slot API concept (`include/managers/SaveGameManager.hpp:68-101`),
    with names
- **Do not port:**
  - `std::string` input buffers
  - SDL2-style always-on text input
  - VL's absence of IME composition handling
  - string component IDs
  - any save picture taken from the swapchain

---

