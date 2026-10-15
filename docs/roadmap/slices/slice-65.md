## Slice 65: Threading Layout Cleanup And Background-Lane Heavy Consumers

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 50](slice-50.md), [Slice 51](slice-51.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella over 65A, 65B, 65C).** Closes when all three
are archived.

Goal: thread-shared layout has one owner, the lane runs below fork-join
priority, and the lane's heavy consumers keep dense nav changes and world
generation off the step's critical path without changing any outcome.

| Subslice | Scope | Hard prerequisites |
| --- | --- | --- |
| [**65A**](slice-65a.md) | One owner for the thread-shared record quantum, padded worker and per-range records, lowered lane OS priority, fixed pool rule | 50, 51 |
| [**65B**](slice-65b.md) | Dense nav batches rebuilt off the step over 64G's dirty chunks and published at a fixed later step | 51, 65A, 64G, 49, 64B |
| [**65C**](slice-65c.md) | World generation streamed on the lane with a fixed per-step commit budget, at load and for worlds created in play | 58, 53B, 51 (in-play path after 74) |

65C is separate from 65B so worldgen (58, late in the order) never blocks nav
offload, and 65C needs only 51's frozen-borrow clause, not 65B.
