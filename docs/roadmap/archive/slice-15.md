## Slice 15: SDL3_mixer Audio Service

Goal: add app-owned SFX and music support so gameplay states can request
immersive audio without owning SDL_mixer resources or moving audio calls into
threaded processors.

Current foundation:

- SDL3_mixer is a required system dependency beside SDL3 and SDL3_ttf.
- `AudioService` owns SDL_mixer initialization, the mixer device, reusable SFX
  tracks, one music track, loaded audio assets, failed-load memoization, bus
  gains, and pause ducking.
- `AudioCommandBuffer` carries state-owned audio intent through `UpdateContext`.
  States queue copied, traversal-safe relative paths during fixed-step updates;
  `Engine` drains commands on the main thread after state updates and transition
  application.
- The demo starts looping music once, updates the listener from the player, and
  emits debounced positional collision SFX from completed contact streams.

Checklist:

- [x] Link SDL3_mixer and include its C API through the platform SDL import.
- [x] Add audio config validation for track count, command cap, gains, and
      spatial scale.
- [x] Add an app-owned audio service and fixed-step command buffer.
- [x] Pass audio intent through `UpdateContext` without putting SDL_mixer handles
      in gameplay state or `DataSystem`.
- [x] Add demo music and collision SFX assets under `assets/audio/`.
- [x] Add tests for command validation, command caps, load caching, failed-load
      memoization, music idempotence, pause ducking, and spatial positioning.
- [x] Update architecture, setup, workflow, and repository guidance docs.

Acceptance checks:

- [x] Gameplay states can request SFX and music without owning mixer handles.
- [x] Audio commands are bounded per fixed step and drained on the main thread.
- [x] Pause stops active SFX and ducks/resumes music gain.
- [x] Missing audio assets warn once per path instead of retrying every frame.
- [x] The demo proves music plus collision SFX through installed runtime assets.

