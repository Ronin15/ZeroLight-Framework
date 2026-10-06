## Slice 66: Distribution, Signing, Symbols, And Store Delivery

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52B](slice-52b.md), [Slice 52C](slice-52c.md), [Slice 54](slice-54.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Umbrella for **66A → 66B / 66C / 66D / 66E**. 66A
depends on 52B (staging layouts, `package-symbols/`), 52C (`release.yml`), and
54 (`UserStorage` pref dir). 66B–66E each carry their own gate in their Status
line. Everything here is build/CI/app-layer work: no `SimulationPipeline` stage,
no `DataSystem`/`WorldSystem` store, no hot-path change.

Goal: a shipped ZeroLight game binary can be triaged when it crashes on a
player's machine, ships on every platform its storefront lists, is trusted by
Windows SmartScreen and macOS Gatekeeper when downloaded directly, reaches
Steam without a manual upload, and has release performance numbers that come
from fixed hardware instead of shared CI VMs.

**Why five sub-slices.** Each has disjoint owner files, its own evidence, and
(except 66A) its own external trigger.

| Sub-slice | Owns | Gate |
| --- | --- | --- |
| **66A** | Split symbols for all three OSes, `tools/symbols.py` store/symbolize, `src/platform/crash_report*.zig`, Linux runtime window icon | none external; after 52B, 52C, 54; land before the first build leaves the developer's machines |
| **66B** | macOS universal2 (lipo, two per-arch SDL builds), aarch64-linux, aarch64-windows packages + CI | first game whose store page lists the platform (per target) |
| **66C** | Windows Authenticode (jsign + Azure Artifact Signing), macOS Developer ID + notarization + `.dmg`, Linux AppImage; Flatpak rejected | first non-prerelease public release outside Steam |
| **66D** | SteamPipe upload via `steamcmd`, `platforms/steam/steam.json`, branch mapping | Steamworks app ID exists |
| **66E** | Authoritative perf runner: `--records`, `tools/perf_gate.py`, `perf.yml`, committed baseline | first release-candidate tag of a game |

**Release-wide decisions shared by 66A–66E (one owner each):**

| Decision | Value | Owner |
| --- | --- | --- |
| Artifact names | `package-<os>-<arch>` and `symbols-<os>-<arch>`; `os` ∈ `linux`/`windows`/`macos`, `arch` ∈ `x86_64`/`aarch64`/`universal2`. Replaces 52C's `package-linux`/`package-windows`/`package-macos`/`symbols-windows`. | 66A |
| Release assets | `<stage>.tar.gz` (Linux), `<stage>.zip` (Windows, macOS ditto), `symbols-<stage>.tar.gz`/`.zip`, plus `<stage>.AppImage` and `<stage>.dmg` from 66C | 66A, 66C |
| Durable symbol storage | Symbols archives are attached to the GitHub Release of each tag (permanent; private repos keep them private). Workflow artifacts (90 days) are never the store. | 66A |
| Package composite actions | `.github/actions/package-{linux,windows,macos}/action.yml` run `zig build package` + archive + symbols archive; jobs keep checkout/pins/setup-zig/cache (52C pattern). 66B adds jobs that call them; 66C adds signing/AppImage/dmg steps inside them. | 66A |
| Secrets and variables | Table in 66C (signing) and 66D (Steam); the perf runner needs none | 66C, 66D |
| Prerelease vs release | A tag containing `-` (`v0.4.0-beta.1`) is a prerelease. A tag without `-` is a release. | 66C (publish rule), 66D (Steam branch) |
| Release checklist | One "Release Checklist" section in `docs/development-workflow.md`: 52C soak → tag → 66E perf run green on the tag → 66C signature checks green → 66D Steam `staging` → manual promotion to `default` | 66A creates it; each later sub-slice appends its line |

**Prerequisite defects found while designing 66 (routed to their owning slices
as Checklist items marked "(added by Slice 66)" in [52A](slice-52a.md), [52B](slice-52b.md), and [52C](slice-52c.md)):**

- **Windows ReleaseFast LTO does not link in Zig 0.17.** On the live tree
  (`99e6959`, isolated `--cache-dir`), `zig build check -Dtarget=x86_64-windows
  -Doptimize=ReleaseFast` fails: `compile exe my-sdl3-game fast x86_64-windows
  54 errors`, all `lld-link: undefined symbol` against the mingw libc/libm
  (`frexpf, frexpl, lrintl, lroundl, modfl, rintl, atanl, copysignl, fdiml,
  nanl, wmemchr, wmemcmp, wmemcpy, wmempcpy, wmemmove, wmemset, strndup,
  mempcpy`, each referenced from several objects). A hello-world
  (`zig build-exe -target x86_64-windows-gnu -O ReleaseFast -lc -flto`)
  reproduces it (`undefined symbol: nanl`) for both `x86_64-windows` and
  `aarch64-windows`, full or thin LTO. The same hello-world **without**
  `-flto` links and emits `m.pdb` next to `m.exe` (re-probed 2026-10-05), so
  Zig's default ReleaseFast selection (LLVM backend, LLD) keeps the PDB that
  52B installs. Linux full LTO links. 52A's acceptance check and 52C's
  `ci.yml` step run exactly the failing command, and 52B/52C's Windows package
  uses it. Owner: **52A** (`ltoSupportedForTarget`, `build.zig:739-742`,
  returns false for `.coff` as well as `.macho` under Zig 0.17, re-checked each
  upgrade). 66B's aarch64-windows package inherits it.
- **52B's placeholder Linux icon is the wrong size.** 52B stages
  `<app-name>.png` "(256×256)" from VoidLight's `res/img/icon.png`, which is
  128×128 (`file`: "PNG image data, 128 x 128"; the `.ico` is also a single
  128×128 image). 66A's window-icon test asserts 256×256. Owner: **52B**
  (commit a 256×256 nearest-neighbour upscale as the placeholder).
- **52B's macOS package loses its DWARF.** 52B's "No symbol stripping" note
  assumes the DWARF is inside the binary. A Zig 0.17 Mach-O exe carries only
  N_OSO stabs pointing at `.zig-cache/o/<hash>/<name>_zcu.o` (see 66A Current
  foundation), so a 52C release built on a hosted runner ships a macOS binary
  whose symbols are gone when the runner is recycled. Owner: **52B** (run
  `dsymutil` at package time into `package-symbols/<stage>/`) and **52C**
  (upload it as `symbols-macos`). 66A then adds only `strip -S`.

