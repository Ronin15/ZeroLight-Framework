## Slice 66D: SteamPipe Upload Automation

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66A](slice-66a.md) (gated on a Steamworks app ID) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on a Steamworks app ID existing** (Steam Direct
fee paid, app created in Steamworks). After **66A**; uses 66B's targets and
66C's notarized app when those have landed. Until then it uploads whatever
`release.yml` produces.

Goal: tags and an explicit dispatch upload every package to the game's Steam
depots with `steamcmd`, setting a fixed branch live: prereleases → `beta`,
releases → `staging`. Promotion to `default` stays a human action in
Steamworks after the Release Checklist.

### Current foundation

- 52C/66A produce `package-<os>-<arch>` artifacts. Archives preserve Unix
  modes (`tar`; macOS `ditto` zips record Unix attributes), and
  `actions/upload-artifact` alone would not.
- 52C builds Linux in Valve's Steam Runtime 3 "sniper" SDK container, so the
  Linux depot targets "Steam Linux Runtime 3.0 (sniper)".
- No Steam configuration exists in either framework.

### Architecture notes

**Owners:** `platforms/steam/steam.json` (per-game config, committed),
`tools/steam_build.py` (stdlib Python), and the `steam-config` and
`steam-upload` jobs in `.github/workflows/release.yml`. No `build.zig` or
`src/` change. ZeroLight has no Steamworks API integration, so no
`steam_appid.txt`.

**Config: `platforms/steam/steam.json`.** App and depot IDs are not secret
(they appear on the store), so they are committed build config that each game
fork edits:

```json
{
  "app_id": 0,
  "depots": {
    "linux_x86_64": 0,
    "windows_x86_64": 0,
    "macos": 0,
    "linux_aarch64": 0,
    "windows_aarch64": 0
  },
  "branches": { "prerelease": "beta", "release": "staging", "dispatch": ["internal", "beta"] }
}
```

- `app_id: 0` disables Steam upload. A depot ID of `0` is skipped.
- `macos` maps to `package-macos-universal2` once 66B lands, and to
  `package-macos-aarch64` before that.
- `tools/steam_build.py validate` rejects:
  - unknown keys;
  - a non-zero depot with `app_id` 0;
  - duplicate depot IDs;
  - branch names outside `[a-z0-9_-]` (1..32 bytes);
  - any use of `default` as a branch, because steamcmd cannot set the default
    branch live (Valve restriction).

**Secrets** (GitHub Environment `steam`, deployment rule: tags `v*` and
`main`):

| Name | Purpose |
| --- | --- |
| `STEAM_BUILD_USERNAME`, `STEAM_BUILD_PASSWORD` | Dedicated builder account. Its only Steamworks permissions on this app are "Edit App Metadata" and "Publish App Changes To Steam". |
| `STEAM_BUILD_TOTP_SECRET` | The builder account's Steam Guard mobile-authenticator `shared_secret`. CI derives the 5-character code. This avoids `config.vdf` login tokens that expire. |

**`tools/steam_build.py` subcommands:**
- `config-check`: prints `enabled=true|false` for `$GITHUB_OUTPUT`.
- `guard-code`: Steam Guard TOTP. It computes `HMAC-SHA1(base64decode(secret),
  u64_be(unix_time / 30))`, applies dynamic truncation at offset `hmac[19] &
  0xF` with mask `0x7fffffff`, then emits 5 characters from
  `23456789BCDFGHJKMNPQRTVWXY` by repeated `% 26`.
- `render --content <dir> --branch <name> --desc <text> --out <dir>`: writes
  `app_build_<app_id>.vdf` with inline depot entries:
  - `ContentRoot` = `<dir>`;
  - per depot, `FileMapping { LocalPath "<depot_key>/*" DepotPath "."
    recursive "1" }` plus `FileExclusion "*.pdb"`, `"*.debug"`, and
    `"*.dSYM"` (defense in depth; 66A keeps symbols out of staging);
  - `SetLive "<branch>"`, `Preview "0"`, `BuildOutput "<out>/logs"`;
  - `Desc "<app_name> <version> <tag> <short sha>"`.
- `--self-test`:
  - a VDF golden for a two-depot config;
  - `validate` rejections;
  - a TOTP known-answer test. Its expected code is produced at landing by an
    independent implementation (node `steam-totp`
    `generateAuthCode(secret, 1700000000)`) and recorded with a provenance
    comment.
  - Appended to 66A's `zig build tools-selftest`.

**Jobs (`release.yml`):**
- `steam-config` (`ubuntu-24.04`, no secrets): `validate` + `config-check` →
  output `enabled`.
- `steam-upload` (`ubuntu-24.04`, `environment: steam`):
  - `needs` every `package-*` job plus `steam-config`.
  - Runs when `needs.steam-config.outputs.enabled == 'true'` and either the
    ref is a `v*` tag, or the run is a `workflow_dispatch` from `main` with
    input `steam_branch != 'none'`.
  - A skipped job is not red.
  - Steps:
    1. Download `package-*` artifacts. Extract each into
       `steam-content/<depot_key>/` (`tar -xzf`, `unzip -q`).
    2. Assert `test -x` on the Linux exe and on
       `<app>.app/Contents/MacOS/<app-name>`.
    3. Bootstrap steamcmd: `dpkg --add-architecture i386`, `apt-get install
       lib32gcc-s1`, download
       `https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz`,
       run `steamcmd +quit` once. steamcmd self-updates by design, so it is
       the one unpinned tool; this is documented as the exception to 52C's
       pinning rule.
    4. `render`.
    5. `steamcmd +login "$USER" "$PASS" "$(steam_build.py guard-code)"
       +run_app_build <vdf> +quit`.
    6. Upload `steam-build-logs` (the `BuildOutput` dir) with `if: always()`.
  - Uploading from Linux keeps the executable flags SteamPipe records.
- `workflow_dispatch` input `steam_branch`: choice `none` (default) or one of
  `branches.dispatch`.

**Branch mapping:**

| Trigger | GitHub Release (52C/66C) | Steam `SetLive` |
| --- | --- | --- |
| push to `main`, PRs | none | none |
| `workflow_dispatch` from `main` | artifacts only | input `steam_branch` (`none` default; `internal` or `beta`) |
| tag `vX.Y.Z-<pre>` | prerelease | `branches.prerelease` (`beta`) |
| tag `vX.Y.Z` | release (signed per 66C) | `branches.release` (`staging`); a human sets the build live on `default` in Steamworks after the Release Checklist |

**One-time Steamworks setup** (documented, not automated):
- Create the depots with OS/arch settings.
- Create the private branches `beta`, `staging`, and `internal`, each with a
  password.
- Set launch options: `<app-name>` (Linux), `<app-name>.exe` (Windows),
  `<app-name>.app` (macOS).
- Select "Steam Linux Runtime 3.0 (sniper)" for the Linux launch.
- Create the builder account with the restricted permissions above and a
  mobile authenticator.

### Checklist

- [ ] `platforms/steam/steam.json` (all IDs 0) and `tools/steam_build.py`
      (`validate`, `config-check`, `guard-code`, `render`, `--self-test`
      wired into `tools-selftest`).
- [ ] `release.yml` `steam-config` + `steam-upload` jobs, the `steam`
      environment, the `steam_branch` dispatch input, the build-log artifact.
- [ ] Docs: `docs/development-workflow.md` "Steam Upload" (config file,
      secrets, branch mapping table, one-time Steamworks setup, the manual
      `default` promotion, the steamcmd pinning exception) and the Release
      Checklist line ("Steam `staging` build installed and launched on Linux,
      Windows, macOS, and a Steam Deck before promoting to `default`").

### Acceptance checks

- [ ] With `app_id: 0`, a tag run shows `steam-upload` skipped (not failed).
- [ ] With real IDs, a `workflow_dispatch` from `main` with
      `steam_branch=internal` uploads one build. It is visible on the
      Steamworks Builds page with the rendered `Desc`, live on `internal`, and
      installs and launches through the Steam client on Linux (sniper), a
      Steam Deck, Windows, and macOS.
- [ ] A prerelease tag lands on `beta` and a release tag lands on `staging`.
      `default` is unchanged until it is promoted manually.
- [ ] `zig build verify` passes (self-test); the docs are updated.

### VoidLight reference

VoidLight has no Steam integration or upload tooling. 66D is net-new.

