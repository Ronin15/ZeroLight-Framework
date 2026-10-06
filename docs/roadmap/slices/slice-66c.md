## Slice 66C: Signing, Notarization, .dmg, And Linux AppImage

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 66A](slice-66a.md) (gated on the first public non-Steam release) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started — gated on the first non-prerelease public release
outside Steam** (a `vX.Y.Z` tag published to GitHub Releases, itch.io, or a
website). Steam-delivered builds carry no Mark-of-the-Web or quarantine
attribute, so SmartScreen and Gatekeeper do not block them. After **66A**.

Goal: on release tags, Windows PE files carry an Authenticode signature with
an RFC 3161 timestamp; the macOS `.app` is Developer ID signed with the
hardened runtime, notarized, and stapled, and also ships as a signed,
notarized, stapled `.dmg`; Linux additionally ships a single-file AppImage.
Release tags refuse to publish unsigned Windows or un-notarized macOS
packages. Flatpak is a recorded "no".

### Current foundation (do not rebuild)

- 52B signs the macOS bundle ad-hoc (`codesign --force --deep --sign -`) as
  the last package step; Linux ships a tarball directory; the `.desktop` has
  `Exec`, `Icon`, `StartupWMClass`, `Categories=Game;`; `<app-name>.png` sits
  at the stage root.
- 52C: release archives (`tar`, `zip`, `ditto`), `publish` on tags via
  `softprops/action-gh-release`; third-party actions pinned by SHA.
- 66A: composite package actions, symbols archives.
- Since June 2023 CA/B Forum rules require OV/EV code-signing keys to live in
  an HSM, so an exportable `.pfx` in a CI secret is no longer obtainable;
  Windows CI signing goes through a cloud HSM service. Apple Developer ID
  certificates still export as `.p12`.
- `AssetStore` resolves the asset root against the cwd first and falls back to
  the exe dir only when the root is absent (`assets.zig:37-61`).

### Architecture notes

**Owners:** `.github/workflows/release.yml`, the 66A composite actions,
`tools/sign_windows.py`, `tools/macos_release.py`, `tools/make_appimage.py`
(stdlib Python wrappers that run locally too), `platforms/macos/entitlements.plist`.
No `build.zig` or `src/` change: signing needs secrets and network, so it is
CI-only; local `zig build package` output stays unsigned/ad-hoc.

**Secrets and variables** (GitHub Environment `release-signing`, deployment
rule: tags `v*`; jobs set `environment: ${{ startsWith(github.ref,
'refs/tags/v') && 'release-signing' || '' }}`):

| Name | Kind | Used for |
| --- | --- | --- |
| `ZL_SIGNING_ENABLED` | repo variable (`true`/`false`) | master switch; signing runs only on `v*` tags when `true` |
| `ZL_SIGNING_PROVIDER` | repo variable (`azure`/`esigner`, default `azure`) | Windows provider selection |
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | secrets | `azure/login` OIDC (federated credential subject `repo:<owner>/<repo>:environment:release-signing`; no client secret) |
| `ZL_AZSIGN_ENDPOINT`, `ZL_AZSIGN_ACCOUNT`, `ZL_AZSIGN_PROFILE` | env variables | Azure Artifact Signing endpoint host, account, certificate profile |
| `MACOS_DEVELOPER_ID_P12_BASE64`, `MACOS_DEVELOPER_ID_P12_PASSWORD` | secrets | "Developer ID Application" identity |
| `MACOS_SIGNING_IDENTITY` | env variable | e.g. `Developer ID Application: Hammer Forged Games (TEAMID)` |
| `APPLE_NOTARY_KEY_P8_BASE64`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` | secrets | App Store Connect API key for `notarytool` |
| `ESIGNER_USERNAME`, `ESIGNER_PASSWORD`, `ESIGNER_TOTP_SECRET`, `ESIGNER_CREDENTIAL_ID` | secrets | fallback Windows provider (below); absent unless used |

**Windows Authenticode**
- **Provider: Azure Artifact Signing (formerly Trusted Signing)**, the lowest
  cost HSM-backed option with a public RFC 3161 timestamp service.
  **Fallback** if the publisher is not eligible for Azure identity validation:
  SSL.com eSigner, using the `ESIGNER_*` secrets. The pipeline is the same;
  `tools/sign_windows.py --provider esigner` swaps the keystore arguments and
  skips `azure/login`:
  `java -jar jsign.jar --storetype ESIGNER --keystore https://cs.ssl.com
  --storepass "$ESIGNER_USERNAME|$ESIGNER_PASSWORD" --keypass
  "$ESIGNER_TOTP_SECRET" --alias "$ESIGNER_CREDENTIAL_ID" --tsaurl
  http://ts.ssl.com --tsmode RFC3161 --alg SHA-256 --name "<window title>"
  <files…>`. The provider is selected by the repo variable
  `ZL_SIGNING_PROVIDER` (`azure` default, or `esigner`).
- **Tool: jsign** (single Java jar, runs on the Linux cross-build runner,
  supports both providers), pinned by `JSIGN_VERSION` + `JSIGN_SHA256` in the
  workflow env (release ≥ 6.0, the first with `TRUSTEDSIGNING`; the newest at
  landing). `osslsigncode` is rejected: it signs only with local keys or
  PKCS#11, and neither provider offers those to a hosted runner.
- **What is signed:** every PE in the staging dir, i.e. `<app-name>.exe`,
  `SDL3.dll`, `SDL3_ttf.dll`, `SDL3_mixer.dll` (redistributed binaries signed
  by the publisher). Signing appends a certificate table and updates the PE
  checksum; it does not change the RSDS record, `TimeDateStamp`, or
  `SizeOfImage`, so 66A's unsigned symbol copies still match minidumps.
- `tools/sign_windows.py <staging dir>`: `az account get-access-token
  --resource https://codesigning.azure.net --query accessToken -o tsv`, then
  `java -jar jsign.jar --storetype TRUSTEDSIGNING --keystore
  "$ZL_AZSIGN_ENDPOINT" --storepass "<token>" --alias
  "$ZL_AZSIGN_ACCOUNT/$ZL_AZSIGN_PROFILE" --tsaurl
  http://timestamp.acs.microsoft.com --tsmode RFC3161 --alg SHA-256 --name
  "<window title>" <files…>`. Runs between `zig build package` and the zip.
  The job outputs `signed=true` when it ran.
- **Verification job** `verify-windows-signatures` on `windows-2025`:
  downloads each `package-windows-*` zip, and for every PE requires
  `(Get-AuthenticodeSignature $f).Status -eq 'Valid'` and a non-null
  `TimeStamperCertificate`. Linux-side `osslsigncode verify` is rejected
  because the Microsoft signing roots are not in Ubuntu's CA bundle.

**macOS Developer ID, notarization, `.dmg`**
- `platforms/macos/entitlements.plist`:
  `com.apple.security.cs.disable-library-validation` and
  `com.apple.security.cs.allow-dyld-environment-variables`, both `true`. The
  Steam overlay injects `gameoverlayrenderer.dylib` through
  `DYLD_INSERT_LIBRARIES`, which the hardened runtime otherwise blocks. Both
  keys are notarization-compatible. A non-Steam game may drop them in its
  fork.
- `tools/macos_release.py` subcommands, run in this order on `macos-15`:
  1. `import-identity`: temp keychain under `$RUNNER_TEMP` with a random
     password (`secrets.token_hex`), `security import` of the `.p12` with
     `-T /usr/bin/codesign`, `set-key-partition-list -S apple-tool:,apple:`,
     added to the search list, unlocked.
  2. `sign --app`: inside-out with no `--deep`. First `codesign --force
     --timestamp --options runtime --sign "$ID"` on each
     `Contents/Frameworks/*.dylib`, then the bundle with `--entitlements`.
     Then `codesign --verify --strict --deep -vv`. This replaces 52B's ad-hoc
     signature.
  3. `notarize --path <app zip>`: `ditto -c -k --keepParent` the app, then
     `xcrun notarytool submit --key <p8> --key-id --issuer --wait --timeout
     45m --output-format json`. It requires `status == "Accepted"`; otherwise
     it prints `notarytool log <id>` and fails.
  4. `staple --path <app>`: `xcrun stapler staple`, then `stapler validate`.
     The release zip and the Steam depot (66D) are built from this stapled
     app.
  5. `make-dmg`: a dmg root holding the app plus an `Applications ->
     /Applications` symlink, `hdiutil create -volname "<window title>"
     -srcfolder <root> -fs HFS+ -format UDZO -ov <stage>.dmg`, then
     `codesign --timestamp --sign "$ID" <dmg>`.
  6. `notarize --path <dmg>`, then `staple --path <dmg>`.
  7. `spctl --assess --type execute -vv <app>` must report `source=Notarized
     Developer ID`; `spctl --assess --type open --context
     context:primary-signature -vv <dmg>` must accept.
  8. `cleanup` (`if: always()`): delete the temp keychain.
- Notarizing both the app and the dmg is deliberate. Steam and the zip ship
  the stapled app (offline first launch works). The dmg ticket covers direct
  downloads.
- The job outputs `notarized=true` when it ran.

**Publish rule**
- `publish` reads the package jobs' outputs. For a release tag (no `-`), it
  fails with "release tags require signed Windows and notarized macOS
  packages (set ZL_SIGNING_ENABLED and the release-signing secrets)" unless
  every Windows package job has `signed == 'true'` and the macOS job has
  `notarized == 'true'`.
- Prerelease tags publish with `prerelease: true` whether signed or not.
  `workflow_dispatch` never publishes (52C).

**Linux AppImage**
- **Tool: `appimagetool` + the static `type2-runtime`**, not `linuxdeploy`.
  52B's staging dir is already self-contained: RUNPATH `$ORIGIN/lib` with the
  three SDL libraries. SDL `dlopen`s the system X11, Wayland, ALSA,
  PipeWire/Pulse, and Vulkan libraries, which must come from the host. So
  linuxdeploy's `DT_NEEDED` bundling adds nothing and risks bundling host
  graphics libraries.
- The static runtime needs no `libfuse2` on the player's machine. Without FUSE
  the AppImage still runs with `--appimage-extract-and-run`; the docs say so.
- Pins in the workflow env: `APPIMAGETOOL_URL` + `APPIMAGETOOL_SHA256` and
  `APPIMAGE_RUNTIME_URL_<arch>` + `APPIMAGE_RUNTIME_SHA256_<arch>`, each
  pointing at a **tagged** upstream release asset (never `continuous`). If
  upstream publishes only `continuous` at landing, the landing PR mirrors the
  assets to this repo's `ci-tools` GitHub Release and pins those URLs.
- `tools/make_appimage.py <stage dir> --tool <appimagetool> --runtime
  <runtime> --arch x86_64|aarch64 --out <stage>.AppImage`:
  - Copies the stage to `<stage>.AppDir`.
  - Writes `AppRun` (mode 0755). AppRun is a POSIX `sh` script that `cd`s to
    its own directory (`$(dirname "$(readlink -f "$0")")`) and `exec`s
    `./<app-name> "$@"`. The `cd` pins the asset root inside the AppDir, so a
    `assets/` folder in the user's cwd can never shadow the packaged assets.
  - Links `.DirIcon -> <app-name>.png`.
  - Runs the tool with `ARCH=<arch>`, `APPIMAGE_EXTRACT_AND_RUN=1` (no FUSE
    in containers), `--runtime-file`, and `--no-appstream`.
- There is no AppImageUpdate/zsync info. Updates are a re-download, or Steam.
- It runs inside the 66A `package-linux` composite action, so every Linux
  package job (x86_64 in the sniper container, aarch64 from 66B) produces
  `<stage>.AppImage` into its `package-linux-<arch>` artifact. `publish`
  attaches it.

**Flatpak: rejected (decision, not deferred).**
- Flathub builds from source inside `flatpak-builder` with no network. That
  needs a Zig SDK extension, vendored `zig fetch` dependencies, and SDL built
  against the Freedesktop runtime instead of 52A's pinned build. The result is
  a second build system to maintain.
- The sandbox needs `--device=all` (gamepads), `--socket=wayland`,
  `--socket=fallback-x11`, `--socket=pulseaudio`, and `--device=dri`, which
  removes most of its benefit for a game.
- Linux players are covered by Steam (the sniper runtime, which includes the
  Steam Deck), the tarball, and the AppImage.
- Revisiting this requires a business need for a Flathub listing, and would be
  a new numbered slice.

### Checklist

- [ ] **Windows signing:** `tools/sign_windows.py`, the jsign pin, the
      `azure/login` OIDC step (`permissions: id-token: write`), signing in
      the `package-windows` composite action gated on tag +
      `vars.ZL_SIGNING_ENABLED == 'true'`, the `signed` output, the
      `--provider esigner` path with the full eSigner argument set and the
      `ZL_SIGNING_PROVIDER` switch. `tools/sign_windows.py --self-test`
      (appended to `tools-selftest`) asserts the exact jsign argv for both
      providers with dummy credentials (no network).
- [ ] **`verify-windows-signatures`** job on `windows-2025`.
- [ ] **macOS:** `platforms/macos/entitlements.plist`,
      `tools/macos_release.py` (all eight subcommands), the gated steps in
      the `package-macos` composite action (zip and dmg built from the
      stapled app), the `notarized` output, and the `<stage>.dmg` in
      `package-macos-<arch>`.
- [ ] **Publish rule:** release tags require `signed`/`notarized`;
      prerelease tags set `prerelease: true`; attach `*.dmg` and
      `*.AppImage`.
- [ ] **AppImage:** `tools/make_appimage.py`, tool/runtime pins, the step in
      the `package-linux` composite action, publish attachment.
- [ ] **Docs:** `docs/development-workflow.md` "Signing And Notarization"
      (the secrets table, one-time setup: Azure Artifact Signing account +
      identity validation + certificate profile + federated credential, Apple
      Developer ID certificate export + App Store Connect API key, the
      eSigner fallback, why signing is CI-only), "Linux AppImage" (FUSE note,
      `--appimage-extract-and-run`), the Flatpak decision, and the Release
      Checklist lines (signature job green; `spctl` output recorded).

### Acceptance checks

- [ ] On a `v0.0.0-ci.2` prerelease tag with `ZL_SIGNING_ENABLED=true`:
      `verify-windows-signatures` is green; the macOS job logs `source=Notarized
      Developer ID` and `stapler validate` success for the app and the dmg.
- [ ] A release tag with `ZL_SIGNING_ENABLED=false` fails `publish` with the
      fix-it, and a prerelease tag publishes unsigned with `prerelease: true`.
- [ ] Manual: the signed zip downloaded with a browser on a clean Windows VM
      shows the publisher name in the SmartScreen/UAC dialog; the dmg
      downloaded on a clean Mac opens and the app launches with only the
      standard "downloaded from the Internet" confirmation, offline included.
- [ ] Manual: the AppImage launches on the reference Arch host and on an
      Ubuntu 22.04 VM; `--appimage-extract-and-run` works with FUSE absent;
      launching it from a directory that contains an `assets/` folder still
      loads the packaged assets.
- [ ] `zig build verify` passes; the docs are updated.

### VoidLight reference

- VoidLight's macOS release bundle ends with `codesign --force --deep --sign
  -` (`CMakeLists.txt:626-629`). It has no Developer ID, notarization, dmg,
  Windows signing, AppImage, or Flatpak. **Do not port** `--deep` signing to
  Developer ID: Apple requires inside-out signing for notarization-grade
  bundles. 52B keeps ad-hoc `--deep` for local packages only.

