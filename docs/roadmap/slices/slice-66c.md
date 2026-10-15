## Slice 66C: Signing, Notarization, .dmg, And Linux AppImage

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66A](slice-66a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first non-prerelease public release
outside Steam** (a `vX.Y.Z` tag published to GitHub Releases, itch.io, or a
website). Steam-delivered builds carry no Mark-of-the-Web or quarantine
attribute, so SmartScreen and Gatekeeper do not block them.

Goal: on release tags, every Windows PE carries an Authenticode signature
with an RFC 3161 timestamp; the macOS `.app` is Developer ID signed with the
hardened runtime, notarized, and stapled, and also ships as a signed,
notarized, stapled `.dmg`; Linux also ships a single-file AppImage. Release
tags refuse to publish unsigned Windows or un-notarized macOS packages;
prerelease tags may publish unsigned.

### Current foundation

- 52B signs the macOS bundle ad-hoc with `--deep` as the last package step;
  Linux ships a self-contained tarball directory (RUNPATH `$ORIGIN/lib`,
  `.desktop`, stage-root icon).
- 52C archives and publishes on tags with third-party actions pinned by
  SHA; 66A adds the package composite actions and symbols archives.
- Since June 2023 CA/B Forum rules require OV/EV code-signing keys to live
  in an HSM, so a CI-held `.pfx` is no longer obtainable; Windows CI signing
  needs a cloud HSM service. Apple Developer ID certificates still export
  as `.p12`.
- SDL `dlopen`s host X11, Wayland, audio, and Vulkan libraries, so they must
  come from the player's system.
- `AssetStore` resolves the asset root against the cwd first and falls back
  to the exe dir only when it is absent.

### Architecture notes

- Recorded decisions: Azure Artifact Signing as the Windows provider with
  SSL.com eSigner as the fallback, through one signing tool that runs on the
  Linux cross-build runner; the macOS app and the dmg are both notarized
  (offline first launch for the zip and Steam, dmg ticket for direct
  downloads); AppImage uses the static runtime and bundles nothing beyond
  52B's stage; no AppImage self-update. Flatpak is rejected (a second
  source-build system for little sandbox benefit to a game); revisiting it
  is a new slice.
- Signing needs secrets and network, so it is CI-only and gated by a repo
  switch; local `zig build package` output stays unsigned/ad-hoc. No
  `build.zig` or `src/` change.
- Developer ID signing is inside-out (no `--deep`); hardened-runtime
  entitlements allow the Steam overlay's injected library.
- Signing never changes the PE identity 66A's symbol store keys on, so
  unsigned symbol copies still match minidumps.
- The AppImage launcher pins the asset root inside the image so a cwd
  `assets/` folder can never shadow packaged assets.
- Third-party tools are pinned by version and checksum to tagged upstream
  releases (52C pinning rule).
- VoidLight signs ad-hoc with `--deep` only; do not port `--deep` to
  Developer ID.

### Checklist

- [ ] Windows signing script for both providers with a credential-free
      argv self-test in `tools-selftest`; signing step in the Windows
      package action gated on tag + switch; a `signed` output.
- [ ] Windows signature verification job on a Windows runner (valid
      signature and timestamp on every PE).
- [ ] macOS release script (temp keychain, inside-out sign, notarize,
      staple, dmg, assess, cleanup) and entitlements; gated steps in the
      macOS package action; a `notarized` output.
- [ ] Publish rule: release tags require signed and notarized packages;
      prereleases publish as prerelease; `.dmg` and `.AppImage` attached.
- [ ] AppImage script, pinned tool and runtime, step in the Linux package
      action for every Linux arch.
- [ ] Docs: `docs/development-workflow.md` Signing And Notarization
      (secrets, one-time provider setup, fallback, why CI-only), Linux
      AppImage (FUSE note), the Flatpak decision, Release Checklist lines.

### Acceptance checks

- [ ] On a prerelease tag with signing enabled: the Windows verification job
      is green; macOS logs `source=Notarized Developer ID` and stapler
      success for the app and the dmg.
- [ ] A release tag with signing disabled fails publish with a fix-it; a
      prerelease tag publishes unsigned as a prerelease.
- [ ] Manual: a browser-downloaded signed zip shows the publisher on a clean
      Windows VM; the dmg on a clean Mac launches with only the standard
      download confirmation, offline included.
- [ ] Manual: the AppImage launches on the reference Arch host and an
      Ubuntu 22.04 VM, works without FUSE via extract-and-run, and loads its
      packaged assets from a directory containing `assets/`.
- [ ] `zig build verify` passes; docs updated.
