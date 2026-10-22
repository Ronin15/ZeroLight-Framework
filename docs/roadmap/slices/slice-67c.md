## Slice 67C: Save Slot Presentation — Thumbnails, Named Saves, And The Text-Input Widget

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 46](slice-46.md), [Slice 60](slice-60.md), [Slice 67A](slice-67a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.**

Goal:
- Every save slot shows a small picture of the player's view of the world
  at save time (world only: no menus, HUD, or debug overlays) and an
  optional player-typed name.
- The save format takes a header-only version bump (relative; Table T3)
  that adds the thumbnail section and name; files of the immediately
  previous version stay loadable.
- A reusable `text_field` widget with SDL3 text input, inline IME
  composition, and fixed UTF-8 buffers; save naming is its first consumer.

### Current foundation

- Swapchain readback is impossible: in the pinned SDL Vulkan backend,
  swapchain images lack `TRANSFER_SRC`, so download or blit from the
  swapchain is invalid; SDL-created textures always allow it, and readback
  is download → fence → map.
- `src/render/renderer.zig` `endFrame` does CPU prep and staging before
  acquire, then one render pass over the draw list and one submit; the
  swapchain format is a local that is not retained. Every `DrawGroup`
  carries a `RenderOrder` whose domain is `.world`, `.ui`, or `.debug`.
- `src/render/gpu/device.zig` requests SDR swapchain composition (a UNORM
  format, no sRGB encode); sampled textures are `R8G8B8A8_UNORM`.
- `src/app/state.zig` `StateStack.render` walks down only while each
  state's `render_below` holds, so a save menu over pause draws the world
  only if every state between them renders below.
- `src/app/resolution.zig` has window→logical but no logical→window
  mapping.
- SDL 3.4 text input: start/stop with properties, a window-space input
  area, text-input and editing events whose strings are valid only during
  dispatch, and an IME hint (must be set before `SDL_Init`) that makes the
  app draw the preedit. Editing offsets are characters on IBus and UTF-16
  units on Windows.
- From earlier slices: 46's slot header with a validated-zero reserved
  region, quiescent save capture, lane write and slot scan, Save/Load menu;
  53A labels (byte-length cap); 53B toolkit; 67A pointer context.

### Architecture notes

- Thumbnail and name are presentation data outside Slice 49's checksum and
  the saved simulation; neither holds a path or handle, and `src/game/`
  stores no pixels and `DataSystem` no `TextureId`
  (`.claude/rules/simulation.md` § Persistent data).
- A save covers the whole session, every world in it (Slice 46); the
  thumbnail shows only the player's view. The session is paused while the
  save menu is open, so the capture matches the saved state.
- The thumbnail is an offscreen, ungraded replay of the frame's world-domain
  draw groups behind `Renderer` facades, read back through a fence with no
  idle wait or frame stall, at any frames-in-flight count, and in either
  Slice 70B scene-resolution mode. Only UNORM swapchain formats are
  accepted (an sRGB one would double-encode); anything else saves without
  a picture (`.claude/rules/render.md`).
- Capture failure or timeout is a state, not an error: the save proceeds
  without a picture. A damaged thumbnail never blocks a load.
- Header-only bump policy: the previous version loads as "no thumbnail,
  empty name"; a later payload bump rejects older files (Table T3). New
  header offsets are pinned like 46's.
- The text field owns typing while editing (rebound letters type, nothing
  reaches the router, F2 included, documented). Text input starts and stops
  from a per-frame claim, so no state can leave it running; frames that
  cannot render keep the current state. Editing is by code point, not
  grapheme (documented). SDL text-input calls stay in `src/platform/`
  (`.claude/rules/input-state.md`, `.claude/rules/engine-design.md`).
- Draw reservation for a field is fixed at build time, never live text
  (`.claude/rules/budgets-capacities.md`).
- Capture, readback, editing, and the claim run on the main thread; slot
  scan and write stay on 46's lane with lent buffers
  (`.claude/rules/threading.md`). Warmed edits, claims, and repeat captures
  allocate nothing.
- Requires of 46: save-mode menus use `render_below` policies so the world
  renders under them (folded into Slice 46).
- VoidLight reference: `createInputField` / focused-field capture and the
  slot API concept; not its `std::string` buffers, always-on text input,
  missing IME handling, or swapchain pictures.

### Checklist

- [ ] Thumbnail capture: retained swapchain format, domain-filtered draw-list
      replay, download + fence + poll, pure state machine and 2× box
      downsample, facades, deinit release; tests for every transition, both
      channel orders, the format gate, and world-only group selection.
- [ ] Pure logical→window mapping and a renderer rect facade; round-trip
      tests at each scale mode and HiDPI.
- [ ] Save header bump: fields, offset asserts, previous-version acceptance,
      validation into `SaveCorrupt`, payload offset after the thumbnail,
      non-fatal thumbnail CRC; tests including a previous-version fixture
      and the amended payload-purity test.
- [ ] Engine save flow waits a bounded number of frames for the picture,
      otherwise saves without it; shutdown finalizes a pending save;
      inline-lane tests.
- [ ] Slot catalog thumbnails (scan writes cells, upload on completion,
      placeholder); CPU-side tests.
- [ ] Toolkit image widget accepts a texture region; Save/Load rows show
      thumbnail and name; the request happens once; a pause-stack test
      proves world groups reach the draw list.
- [ ] Save-name dialog replacing 46's overwrite confirm (default name, trim,
      one-press gamepad commit, Escape ends editing then cancels, click on
      Save commits first); keyboard, gamepad, and pointer tests.
- [ ] Pure UTF-8 edit helpers with tests (partial fit, invalid input,
      controls filtered, multi-byte delete, caret moves, preedit mapping).
- [ ] `text_field` widget: edit session, committed event, capacity build
      error, input precedence, preedit display, horizontal scroll, caret
      blink; 53A substring-offset query (cold); fake-backend tests.
- [ ] Text-edit event resolution in `Engine`; tests with synthetic text,
      editing, and repeating key events.
- [ ] Text-input controller with the per-frame claim and pure next-action
      table; platform wrappers; IME hint before SDL init; tests.
- [ ] `FailingAllocator` proofs: warmed edit session + render, claim diff,
      second capture cycle, header encode/validate.
- [ ] gpu-smoke: a world quad and a UI rect; the thumbnail holds the world
      color exactly and not the UI; text input starts and stops.
- [ ] 46's `save-encode` bench gains a thumbnail case.
- [ ] Docs: `docs/architecture.md` save boundary (bump policy, thumbnail
      outside the checksum, no swapchain readback);
      `docs/rendering-assets-shaders.md` thumbnail capture;
      `docs/state-stack-and-input.md` text input, IME, named saves;
      Table T3; `src/tests.zig`.

### Acceptance checks

- [ ] `zig build verify` passes.
- [ ] `zig build gpu-smoke` captures a world-only thumbnail without an idle
      wait on the capture path.
- [ ] Manual (display): slots show the paused world without menus or HUD; a
      renamed slot keeps its name after restart; a previous-version save
      loads with a placeholder; a corrupted thumbnail byte still loads.
- [ ] Manual (fcitx5 or IBus Japanese; Windows IME when available):
      composition renders inline with an underline, candidates appear near
      the field, commit inserts the converted text.
- [ ] `save-encode` runs with the thumbnail case.
- [ ] Review: no `src/game/` file calls SDL text input; `src/game/` stores no
      thumbnail pixels; `DataSystem` holds no `TextureId`.
