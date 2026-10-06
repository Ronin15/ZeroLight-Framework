## Slice 39: Sensory Stimulus Ecosystem

**Status: landed.** Multi-producer world sensory bus feeding existing AI hearing
(dig + footstep same-step; collision impact deferred one step). No
`StimulusController`; cognition does not depend on `AudioController`.

Goal: expand the world sensory bus so hearing and curiosity are not permanently
tied to a single dig producer — without turning stimuli into a second event
stream or audio-playback service.

### Landed behavior

- `WorldStimulus.kind`: `.dig`, `.footstep`, `.impact` with fixed default
  intensities and `stimulusHearingScore` soft ranking in `PerceptionSystem`.
- **Same-step producers (before perception):** pipeline promotes prior-step
  deferred impacts, `DigController.process`, player footstep (≤1 when velocity
  is non-trivial).
- **Deferred producer:** after `collision_respond`, player-involving contacts
  enqueue `.impact` into pipeline-owned `[stimulus_deferred_capacity]`; promoted
  at the next `update` start. Landing carve still does not emit (Slice 29).
- Fixed capacities and drop policy in `simulation.zig`; demo warms
  `stimuli` to `stimulus_live_capacity`.

### Checklist

- [x] Document producer-phase rule in `docs/simulation-tiers-and-pipeline.md`
      and `architecture.md` (must precede perception or be next-step delayed).
- [x] Extend `WorldStimulus.kind` with dig + footstep + collision impact.
- [x] Wire multi-producer pipeline + perception tests (ranking, deferred impact,
      footstep same-step, capacity drops).
- [x] Intensity ranking via fixed `stimulus_hearing_falloff_k` (Slice 39).
- [x] Reserve stimulus capacity from demo config; capacity + drop policy tests.
- [x] Dig causal tests unchanged; `appendStimulus`/`tryAppendStimulus`
      FailingAllocator proofs in `simulation.zig`.

### Acceptance checks

- [x] Hearing acquires non-dig stimuli; arbitration investigate path already
      consumes `heard_stimulus` XY (perception + arbitration tests).
- [x] No cognition → audio service dependency for stimulus emission.
- [x] `zig build verify` passes.

