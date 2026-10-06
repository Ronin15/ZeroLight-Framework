## Slice 3: Render Resource Layer

Goal: replace long-lived raw texture indices with a resource layer that can grow
into caching, reload, and ownership tracking.

Current foundation:

- Renderer owns GPU textures in a generational slot table.
- Public renderer APIs use `TextureId` instead of long-lived raw texture indices.
- `resources.zig` defines generational `TextureId` and resource descriptors.

Architecture notes:

- Future atlas and tile rendering should reuse one atlas `TextureId` with
  per-sprite or per-tile source rectangles. Slice 3 intentionally stops at
  stable texture identity, descriptor lookup, and stale-ID rejection; it does not
  add atlas metadata, tilemap storage, or tile renderer batching.

Checklist:

- [x] Add a slot table for textures with generation, alive state, and descriptor.
- [x] Add `TextureId` creation, validation, lookup, and destruction helpers.
- [x] Keep draw submission lookup array-backed and allocation-free.
- [x] Preserve the white texture as an internal renderer resource.
- [x] Keep renderer texture creation centered on decoded pixel uploads through
      `createTextureFromPixels` and `replaceTextureFromPixels`.
- [x] Add tests for stale IDs, destroyed IDs, invalid generation, and descriptor
      validation.
- [x] Add a focused compatibility note for the `TextureHandle` to `TextureId`
      rename.

Acceptance checks:

- [x] Destroyed or stale texture IDs are skipped or rejected deterministically.
- [x] Existing demo and debug text still render.
- [x] Texture upload validation still rejects bad dimensions, pitch, and buffer
      lengths before GPU work.
- [x] No hash map lookup is introduced into per-sprite draw submission.

