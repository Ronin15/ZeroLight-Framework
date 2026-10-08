## Slice 71A: AI Behavior Parity — Patrol, Follow, Guard

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 73](slice-73.md), [Slice 55](slice-55.md), [Slice 56](slice-56.md), [Slice 61](slice-61.md), [Slice 62](slice-62.md), [Slice 63](slice-63.md) · Track: [VoidLight port](../tracks/voidlight-port.md) · [Emergent AI](../tracks/emergent-ai.md)

**Status: not started.** Composes with 68A and 68B in either order.

Goal: an agent can **patrol** an authored route of `patrol` interest
markers, **follow** a designated leader, and **guard** a home (its route or
its Slice 62 spawn anchor): beyond a fixed leash its pursue, investigate, and
forage scores drop to zero and a return-home behavior brings it back, and a
help call raises allied guards' drives and leaves an `alarm` stimulus that
gives hearers an investigate goal. Patrol, follow, and return home are Slice
73 behavior content over new signal and goal primitives (route target,
leader, home, leash); guard is a gain pattern, not a behavior. At zero gain
every existing agent is byte-identical.

### Current foundation

- Arbitration (`src/game/systems/arbitration.zig`): `Signals` with
  "no signal" defaults, `scoreBehaviors` (gain × weighted terms),
  `selectSticky` with a lowest-index tie-break, `GoalResolution`,
  `resolveGoal`.
- AI processor (`src/game/systems/ai.zig`): grouped MAL gather rows, the
  gain-gated main-thread gather, the threaded marker scan, the invalid-goal
  path degrading a row to wander, `priorityForBehavior`.
  `writeAiIntentsJob` never writes `NavigationIntent.goal_level` (default 0),
  so a level-1 agent's own-level goal is sent as a surface goal; the row
  level is already gathered.
- Interest markers (`src/game/world_interest.zig`): `InterestMarkerStore`
  with generational ids (fixed-capacity today; 58 grows it with content);
  the `patrol` kind is reserved with no consumer.
- Stimuli: `StimulusKind` and the `SensoryBus` deferred and sticky buffers
  (`src/game/simulation.zig`, `src/game/sensory_bus.zig`).
- Events: `EntityPerceivedEvent {observer, target}`.
- From earlier slices: 73's behavior catalog; 55's coast class and alert
  inputs; 56's `entity_damaged` and step helpers; 61's affect-impulse
  substrate and `harvest_completed` ownership facts; 62's spawn anchors and
  `guard` / `merchant` / `villager` archetypes; 63's `social_react` stage.

### Architecture notes

- Per-agent post data is one optional component; home and alert level are
  derived, never stored.
- Route count and length are content-sized
  (`.claude/rules/budgets-capacities.md`); 71A adds route data to markers,
  whose store 58 grows with content.
- The leash has hysteresis read from the agent's active behavior, so a
  target at the boundary cannot cause flapping; flee is never leashed.
- Post goals carry the row's level and are own-level; off-level homes,
  leaders, and routes read as absent. Cross-level goals are 73's task layer,
  per archetype.
- Posts are path followers and never coast; a gain-relevant post assignment
  is an alert input to Slice 55.
- Help call: a serial pipeline-owned stage turns perceived intruders inside
  a guard's leash, damaged guards, and theft of owned nodes into alarms;
  each alarm sends affect impulses to the nearest same-faction, same-level
  allies through the shared spatial index under a fixed per-query budget,
  plus one deferred `alarm` stimulus heard by every stagger cohort.
  Over-budget alarms defer to the next step, never drop
  (`.claude/rules/budgets-capacities.md`). A guard is a homed agent that can
  fight (gain rule, not a content list).
- Spatial rows map to entities through the index's own entity column, never
  halo positions (rows are compacted).
- Hashed state (post store, route fields on markers, anchor routes) is
  classified in Slice 49's lists and saved by Slice 46 with relative bumps;
  the alarm controller's scratch is excluded (64B).
- With 68B: the leash suppresses retaliation pursuit; with 68A: post signals
  are gathered through its decide-only walk. Whichever lands second adds the
  composition test.
- VoidLight reference: port guard radius as home + leash + return home,
  alert levels as the help call and derived alert level, follow's offset
  position, and patrol waypoint cycling as authored routes; not thread-local
  RNG, delta-time timers, message-queue dispatch, or per-entity state
  sidecars.

### Checklist

- [ ] Post component end to end with validation (no self-leader) and store
      `FailingAllocator` proof.
- [ ] Patrol routes on markers: route and sequence fields, validation
      (unique sequence, one level per route), content-sized route storage,
      step-derived target.
- [ ] Pure post helpers (route goal, home precedence, leash hysteresis,
      alert level) with unit tests.
- [ ] Patrol, follow, and return-home as Slice 73 behavior content with
      their signal and goal primitives; leash suppression; gain-0 parity
      sweep.
- [ ] AI gather for post signals (gain-gated), spawn-anchor input, and
      own-level `goal_level` on post goals.
- [ ] Slice 55 hooks: posts non-coastable, post alert input.
- [ ] `alarm` stimulus with sticky linger and deferred enqueue.
- [ ] Help-call stage with its contract, `.guard_alarm` impulse producer,
      deferral of over-budget alarms, and the spatial index entity column.
- [ ] Archetype content: post gains for `guard` and `merchant`, an `escort`
      archetype; parity table updated.
- [ ] Spawn anchors carry a patrol route; spawn templates attach posts;
      Slice 58 anchor key.
- [ ] Demo content: a route, posted guards, a leader with escorts.
- [ ] Persistence: classification, save sections, relative bumps; 64B row.
- [ ] Composition with 68A / 68B in whichever lands second.
- [ ] Bench `ai-post`.
- [ ] Docs: `docs/architecture.md`, `docs/simulation-tiers-and-pipeline.md`,
      archetype schema and route authoring note; Emergent AI track row.

### Acceptance checks

- [ ] Guards visit route markers in cursor order; an escort stays within
      follow distance of a moving leader and degrades to wander when the
      leader changes level; a level-1 patroller next to a ramp never takes
      it and every post intent carries level 1.
- [ ] A guard lured beyond its leash returns home, does not resume pursuit
      until inside the release radius, and never flaps at the boundary.
- [ ] Help call end to end: a hostile entering a leash raises one alarm;
      allied guards' aggression rises at the commit; they hear the alarm and
      investigate or pursue within the linger window; a hostile nearby gets
      no impulse; a burst of alarms past the budget lands on later steps.
- [ ] Gain-0 parity: the arbitration sweep matches and a 120-step checksum
      over pre-71A archetypes is unchanged.
- [ ] Serial == threaded intents, decide lists, and pipeline checksums with
      posts and alarms active; the composite pipeline allocates nothing
      after reserve.
- [ ] `ai-post` recorded; `ai`, `ai-idle-coast`, `ai-affect` show no
      regression.
- [ ] `zig build verify` passes.
