## Slice 52B: Platform Packaging Layouts

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52A](slice-52a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Needs 52A's pinned SDL libraries, rpaths, committed
shaders, and zon version import. 52C's tag job consumes it.

Goal: `zig build package --release=fast` produces one self-contained
distributable staging directory per OS at
`zig-out/package/<app-name>-<version>-<os>-<arch>/`, bundling the pinned SDL,
assets, the target's shaders, an icon, licenses, and platform metadata. The
step refuses configurations that are not distributable and validates its own
layout before the build passes.

### Current foundation

- `package` is just the install step: exe plus assets, Windows SDL DLLs beside
  the exe, no gpu-smoke (`build.zig`, DW).
- Full LTO applies to the app exe on Linux ReleaseFast only; Darwin and
  Windows build without it (52A).
- Identity: `-Dapp-name` (default `my-sdl3-game`) and `-Dwindow-title`; zon
  `.version = "0.0.0"`. No icons, platform templates, or `SDL_SetAppMetadata`
  call exist.
- `AssetStore` (`src/assets/assets.zig`) resolves assets from the configured
  root relative to the cwd, falling back to the exe directory only when that
  root is absent. In a macOS bundle this finds nothing (exe in
  `Contents/MacOS`, Finder cwd `/`, resources in `Contents/Resources`).
  Shaders and fonts also load through `AssetStore`, so one fallback covers
  every runtime file.
- Zig 0.17 offers `Compile.subsystem`, `Module.addWin32ResourceFile` (built-in
  resource compiler, works cross from Linux), `addRPathSpecial`, cmake-style
  `addConfigHeader`, and the install/check/fail steps needed here.
- The only third-party license shipped today is the Noto font license.

### Architecture notes

- Owners: `build.zig` owns the package graph; a new `platforms/` dir holds
  templates and icons (not runtime assets); `assets.zig` owns the bundle
  fallback; `Engine.init` sets app metadata and the Windows icon hint before
  window creation (cold, main thread). No gameplay or pipeline change.
- Identity: `-Dapp-name` names files and folders and is validated at configure
  to 1..64 bytes of `[A-Za-z0-9_-]` (54 enforces the same set at runtime);
  `-Dwindow-title` is the display name; the version is zon `.version`; a new
  `-Dbundle-id` defaults to `com.<org>.<app>` derived from the identity
  strings (org is the literal `hammerforgedgames` until 54 adds `-Dorg-name`
  and owns that default). One "App identity" table in DW lists each identity
  string's source, default, charset, and every consumer.
- Refusals on the `package` step only: Debug, system SDL on Linux/macOS, and
  52A's `native` / `-Dcpu` refusal.
- Staging is separate from the dev `zig-out/bin` layout, which `run`, `dev`,
  and `gpu-smoke` keep. Archiving is 52C's.
- Linux (decision): a tarball directory with RUNPATH `$ORIGIN/lib`, the three
  SONAME libs, a rendered `.desktop`, and a 256×256 icon. Steam depots and
  itch.io take a plain directory, and 52C builds in Steam's sniper container;
  AppImage is Slice 66C.
- Windows: GUI subsystem in ship builds, console in Debug and ReleaseSafe
  (soaks need stderr); icon plus numeric VERSIONINFO from zon semver; the PDB
  goes to `zig-out/package-symbols/<stage>/`, never into staging.
- macOS: an `.app` from a ported Info.plist template (plus
  `LSMinimumSystemVersion`), Frameworks dylibs, Resources assets and licenses,
  re-signed ad hoc after assembly (Apple Silicon will not run unsigned code);
  `dsymutil` extracts DWARF at package time. Developer ID, notarization, and
  `.dmg` are 66C. LTO stays off and is re-checked at each Zig upgrade.
- The `AssetStore` macOS fallback adds a third candidate,
  `Contents/Resources/<root>`, only when the exe dir ends in `Contents/MacOS`,
  through a pure non-allocating helper, logged at debug.
- Licenses: ZeroLight's, each pinned SDL package's, FreeType's FTL, and Noto's.
- No symbol stripping; Slice 66A strips and stores symbols.
- Placeholder icons are VoidLight's (same owner); each game replaces them.
- VoidLight: port its macOS bundle, Info.plist keys, icon resources, and
  Release-only GUI subsystem (with ReleaseSafe keeping the console); it has no
  CPack or archive step, so archiving is net-new in 52C.

### Checklist

- [ ] Identity options: `-Dapp-name` charset check, derived `-Dbundle-id`,
      version and identifier build options, `SDL_SetAppMetadata` in
      `Engine.init`.
- [ ] Per-OS staging graph under `zig-out/package/<stage>/` with the Debug and
      system-SDL refusals and self-validating `CheckFile`s for every expected
      file and substituted metadata.
- [ ] Linux: `lib/` SONAME files, rendered `.desktop`, 256×256 PNG icon,
      `licenses/`.
- [ ] Windows: `-Dwindows-console`, generated resource file (icon +
      VERSIONINFO), icon hints, PDB to `package-symbols` with its check.
- [ ] macOS: `.app` assembly, ad-hoc `codesign` step, and the `AssetStore`
      bundle fallback with tests (bundle path, trailing separator, non-bundle
      path, `MacOS` not under `Contents`).
- [ ] `platforms/` templates and placeholder icons, `platforms` in zon
      `.paths`.
- [ ] (added by Slice 66) Placeholder `platforms/linux/app-256.png` committed at
      256×256 (one-time upscale of VoidLight's icon; no build-time tool).
- [ ] (added by Slice 66) `dsymutil` at package time on macOS hosts into
      `package-symbols`, checked, before the bundle install and `codesign`.
- [ ] Docs: DW Packaging (layouts, App identity table, refusals, local vs
      distributable, symbols dir, icon replacement); `docs/architecture.md`
      asset resolution order and `platforms/` ownership; `README.md`.

### Acceptance checks

- [ ] Linux package: RUNPATH `$ORIGIN/lib` and no `.zig-cache` path; `ldd`
      resolves all three SDL libs from `<stage>/lib`; manual on a display, it
      launches from an unrelated cwd and renders.
- [ ] Windows cross package: exe, three DLLs, `.dxil` shaders, no `.pdb` in
      staging; the PDB is in `package-symbols`; PE subsystem is GUI for
      `--release=fast` and console for `--release=safe`; manual on Windows, the
      icon shows and the game runs.
- [ ] macOS (on a Mac): `codesign --verify --deep --strict` passes, `otool`
      shows the `@rpath` SDL and the Frameworks rpath, the Finder-launched app
      finds its assets, and the dSYM UUID matches the bundle exe.
- [ ] `package` with Debug, system SDL, a `native` baseline, or `-Dcpu` fails
      with its fix-it; `-Dapp-name="My Game"` fails the charset check; the
      default bundle ID for `my_game` is `com.hammerforgedgames.my-game`.
- [ ] `bundleContentsDir` tests pass; `zig build verify` passes; docs updated.
