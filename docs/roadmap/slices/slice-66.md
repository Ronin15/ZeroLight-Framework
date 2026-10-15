## Slice 66: Distribution, Signing, Symbols, And Store Delivery

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52B](slice-52b.md), [Slice 52C](slice-52c.md), [Slice 54](slice-54.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started (umbrella).** 66A is ungated; 66B–66E each carry their
own trigger in their Status line. Closes when all five are archived.

Goal: a shipped game binary can be triaged when it crashes on a player's
machine, ships on every platform its storefront lists, is trusted by Windows
SmartScreen and macOS Gatekeeper when downloaded directly, reaches Steam
without a manual upload, and has release performance numbers from fixed
hardware rather than shared CI VMs.

| Sub-slice | Outcome | Gate |
| --- | --- | --- |
| [**66A**](slice-66a.md) | Split symbols on every OS, a symbol store and symbolizer, in-process crash reports, Linux runtime window icon | none; land before the first build leaves the developer's machines |
| [**66B**](slice-66b.md) | macOS universal2, aarch64-linux, aarch64-windows packages and CI | per target, when a storefront lists it |
| [**66C**](slice-66c.md) | Windows Authenticode, macOS Developer ID + notarization + `.dmg`, Linux AppImage; Flatpak rejected | first non-prerelease public release outside Steam |
| [**66D**](slice-66d.md) | SteamPipe upload automation with fixed branch mapping | a Steamworks app ID exists |
| [**66E**](slice-66e.md) | Authoritative perf runner on fixed reference hardware | first release-candidate tag |

### Architecture notes

- Build, CI, tooling, and platform/app-layer work only: no pipeline stage,
  `DataSystem`/`WorldSystem` store, or hot-path change.
- Release-wide conventions have one owner each: artifact names and durable
  symbol storage on GitHub Releases (66A), the prerelease-vs-release tag
  rule (66C publish, 66D Steam branch), and one Release Checklist in
  `docs/development-workflow.md` that 66A creates and each later sub-slice
  extends.
- Prerequisite defects found while designing 66 were routed to their owners
  as "(added by Slice 66)" items: Windows LTO off under Zig 0.17 (52A,
  landed), a correctly sized Linux icon and package-time `dsymutil` (52B),
  and the macOS symbols upload (52C).

### Checklist

- [ ] 66A, 66B, 66C, 66D, 66E archived.

### Acceptance checks

- [ ] Each sub-slice's Acceptance checks pass.
