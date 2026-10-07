# docs/roadmap

Process rules are in `docs/framework-implementation-slices.md` (IDX).

- Work a slice: read IDX, that one `slices/slice-<id>.md`, and only the track
  files it links (IDX § Agent Workflow: Implementing A Slice).
- Slice files follow IDX § Standard slice file shape (Goal, Current foundation,
  Architecture notes, Checklist, Acceptance checks, Status). Status reflects
  only integrated work; completed slices move to `archive/`.
- No backlog dumping: every follow-up becomes a Checklist item in its owning
  slice or a decision-complete new slice (Status may be "gated on
  <trigger>"). "Out of scope" names the owning slice (IDX § Ground Rules).
- **Deferred By Owner** (IDX § Deferred By Owner): only the owner adds
  entries.
- `scaling-gaps.md` holds only measured pressure points awaiting a benchmark.
- Version numbers, `stage_order` positions, and component tags follow Tables
  T1–T6 in `tracks/voidlight-port.md`.
