## Slice 66D: SteamPipe Upload Automation

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66A](slice-66a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on a Steamworks app ID existing** (Steam
Direct fee paid, app created). Uses 66B's targets and 66C's notarized app
when those have landed; until then it uploads whatever releases produce.

Goal: tags and an explicit dispatch upload every package to the game's
Steam depots with `steamcmd`, setting a fixed branch live: prereleases →
`beta`, releases → `staging`. Promotion to `default` stays a human action in
Steamworks after the Release Checklist.

### Current foundation

- 52C/66A produce `package-<os>-<arch>` artifacts; the archives preserve
  Unix modes (bare workflow artifacts would not).
- 52C builds Linux in the Steam Runtime 3 sniper SDK container, so the Linux
  depot targets "Steam Linux Runtime 3.0 (sniper)".
- No Steam configuration or Steamworks API integration exists.
- steamcmd cannot set the `default` branch live (Valve restriction) and
  self-updates by design.

### Architecture notes

- Build config and CI only; no `build.zig` or `src/` change, no
  `steam_appid.txt`.
- App and depot IDs are public, so they are committed per-game config that
  each fork edits; app ID 0 disables upload and depot 0 skips a depot.
  Config validation rejects unknown keys, inconsistent IDs, invalid branch
  names, and `default` as a target.
- Credentials are a dedicated builder account with only metadata-edit and
  publish permissions on the app; CI derives its Steam Guard code from the
  authenticator secret, so no expiring login token is stored.
- steamcmd is the one unpinned tool, documented as the exception to 52C's
  pinning rule.
- Symbols never reach a depot (66A keeps them out of staging; the upload
  also excludes them).
- Branch mapping: `main`/PRs upload nothing; a dispatch from `main` may set
  `internal` or `beta`; a prerelease tag sets `beta`; a release tag sets
  `staging`.
- VoidLight has no Steam tooling; 66D is net-new.

### Checklist

- [ ] Committed Steam config (all IDs 0) and a stdlib-Python tool
      (validate, enabled check, guard code, build-script render) with a
      self-test in `tools-selftest`, including a known-answer guard-code
      vector from an independent implementation.
- [ ] Release jobs: config check (no secrets) and upload (Steam
      environment), the dispatch branch input, executable-bit assertions,
      the build-log artifact.
- [ ] Docs: `docs/development-workflow.md` Steam Upload (config, secrets,
      branch mapping, one-time Steamworks setup, manual promotion, pinning
      exception) and the Release Checklist line.

### Acceptance checks

- [ ] With app ID 0, a tag run shows the upload job skipped, not failed.
- [ ] With real IDs, a dispatch to `internal` uploads one build that
      installs and launches through Steam on Linux (sniper), a Steam Deck,
      Windows, and macOS.
- [ ] A prerelease tag lands on `beta`, a release tag on `staging`;
      `default` is unchanged until promoted by hand.
- [ ] `zig build verify` passes; docs updated.
