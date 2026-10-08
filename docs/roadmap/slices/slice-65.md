## Slice 65: Threading Layout Cleanup And Background-Lane Heavy Consumers

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 50](slice-50.md), [Slice 51](slice-51.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella over 65A, 65B, 65C).**

Slice 65 is split into three subslices. Each one verifies on its own and has
different prerequisites:

| Subslice | Scope | Hard prerequisites |
| --- | --- | --- |
| **65A** | One shared `thread_shared_record_alignment`, `WorkerRecord` line padding, and lowered OS priority on the lane thread. Fixes the pool-size rule (no core reservation). | 50, 51 |
| **65B** | Large nav patches and full relabels run on the lane as a deferred rebuild into a back graph. The swap is step-keyed at `submit + k`. The front graph is frozen while the job runs. | 51, 65A, 64E (49 for the checksum trace test; 64B for `normalize`) |
| **65C** | Load-time worldgen streamed on the lane in chunk batches, with a fixed per-step commit budget on the main thread. | 58, 53B, 65B (the frozen-borrow clause) |

65C is separate from 65B because Slice 58 lands much later than 51. Keeping
them together would block nav offload behind worldgen.

### Cross-slice additions (folded into the owning slices)

| Owner | What landed there |
| --- | --- |
| [46](slice-46.md) | (65B) Round-trip trace test, mid-job variant (Checklist, verbatim) |
| [51](slice-51.md) | (65B) Frozen-borrow job-input clause (Architecture + Checklist); Consumer decision bullets point to 65B/65C; thread-policy bullets and the bench-gate acceptance point to 65A |
| [50](slice-50.md) | `WorkerRecord` padding is 65A |
| [49](slice-49.md) | Deferred nav state is part of `PathfindingSystem`, classified `normalized` by 64B |
| [58](slice-58.md) | Status and "Worldgen off the main thread" name 65C |

The "Roadmap cross-edits (same change)" Checklist items in 65A/65B/65C were
applied to the roadmap text when it was split into per-slice files; at landing
they reduce to confirming the edited text still matches the code.
