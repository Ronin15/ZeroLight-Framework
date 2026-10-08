## Slice 52B: Platform Packaging Layouts

> [Roadmap index](../../framework-implementation-slices.md) · Depends on: [Slice 52A](slice-52a.md) · Track: [VoidLight port](../tracks/voidlight-port.md)

**Status: not started.** Depends on **52A**, which provides the pinned SDL libs
to bundle, the rpaths, the committed shaders, and the zon version import. 52C's
tag job consumes it.

Goal: `zig build package --release=fast` produces one self-contained
distributable staging directory per OS, at
`zig-out/package/<app-name>-<version>-<os>-<arch>/`. It bundles the pinned SDL,
assets, the target's shaders, an icon, licenses, and platform metadata. The
`package` step refuses configurations that are not distributable, and it
validates its own layout before the build passes.

### Current foundation

- `build.zig:263-264`: `package` is just the install step.
  `docs/development-workflow.md:32-38` describes it: exe plus assets, with
  Windows SDL DLLs beside the exe and no gpu-smoke.
- LTO:
  - `build.zig:97-100`, `:139-146`, `:170-174`, and `:739-742` turn on full LTO
    for the app exe on non-Mach-O ReleaseFast, with LLVM+LLD forced.
  - macOS gets none: Zig 0.17 LTO requires LLD, and LLD rejects Mach-O
    (re-verified in `zig_0_17_upgrade.md:42-44`).
- Identity today:
  - `build.zig:78-79` has `-Dapp-name` (default `my-sdl3-game`) and
    `-Dwindow-title`.
  - `build.zig.zon:9` has `.version = "0.0.0"`.
  - ZeroLight has no icons, no platform templates, and no `SDL_SetAppMetadata`
    call.
- `src/assets/assets.zig:38-74` resolves assets from the configured root
  relative to the cwd. It falls back to the exe directory only when that root
  is absent. In a macOS bundle this finds nothing: the exe sits in
  `Contents/MacOS`, Finder launches with cwd `/`, and resources belong in
  `Contents/Resources`.
- Shaders and fonts also load through `AssetStore`
  (`src/render/gpu/sprite_pipeline.zig:196-206`,
  `src/render/text.zig:199-228`), so one fallback covers every runtime file.
- Zig 0.17 build APIs available:
  - `Compile.subsystem: ?std.zig.Subsystem` (`.console`, `.windows`);
  - `Module.addWin32ResourceFile`, using Zig's built-in resource compiler,
    which works when cross-compiling from Linux;
  - `Module.addRPathSpecial`;
  - `addConfigHeader(.{ .style = .{ .cmake = … } })` (`${VAR}`/`@VAR@`
    substitution);
  - `addWriteFiles`, `addInstallFile`, `addInstallDirectory`, `addCheckFile`,
    and `addFail`.
- The only third-party license currently shipped is
  `assets/fonts/NotoSansMono-LICENSE.txt`.

### Architecture notes

- **Owners:**
  - `build.zig` owns the `package` step graph.
  - The new `platforms/` dir holds packaging templates and icons, not runtime
    assets.
  - `src/assets/assets.zig` owns the bundle fallback.
  - `src/app/engine.zig` owns the startup app metadata and Windows icon hint,
    as a main-thread cold path before window creation.
  - No gameplay or pipeline changes.
- **Identity:**
  - `-Dapp-name` names the exe, files, and the `.app` folder.
  - `-Dwindow-title` is the display name: CFBundleName/CFBundleDisplayName,
    `.desktop` `Name`, and FileDescription.
  - The version is zon `.version`, read through the 52A import.
  - `-Dapp-name` is validated at configure to 1..64 bytes of `[A-Za-z0-9_-]`
    (no spaces), because it becomes file, folder, `.desktop`, and pref-path
    names. A bad value is a configure-time `std.debug.panic` with a fix-it.
    Slice 54's `AppConfig.validate` enforces the same set at runtime.
  - New `-Dbundle-id=<reverse-dns>`. It feeds CFBundleIdentifier, the SDL
    app identifier, and the Wayland `app_id` / `.desktop` `StartupWMClass`.
    Its default is derived from the identity strings:
    `com.<org>.<app>`, where each segment is lowercased with spaces removed
    and `_` mapped to `-` (CFBundleIdentifier allows only alphanumerics, `-`,
    and `.`). 52B lands before Slice 54, so `<org>` is the literal
    `hammerforgedgames` here. When Slice 54 adds `-Dorg-name`, it switches the
    `-Dbundle-id` default to derive from `org_name` (54 lands second, so it
    owns that edit).
  - **App identity table.** `docs/development-workflow.md` gains one "App
    identity" table: org (human string), `app_name`, `bundle_id`, version,
    with each one's source option, default, allowed characters, and every
    consumer (file names, `.desktop`, Info.plist, VERSIONINFO,
    `SDL_SetAppMetadata`, and Slice 54's `SDL_GetPrefPath`). 52B creates it;
    Slice 54 adds the org row's option.
  - New build options `app_version` and `app_identifier`.
  - `Engine.init` calls
    `SDL_SetAppMetadata(window_title, app_version, app_identifier)` before
    `SDL_Init`. This ties Wayland/X11 windows to the `.desktop` entry.
- **Refusals:** `addFail` on the `package` step only, so other steps are
  unaffected.
  - `optimize == .debug`: "package requires --release=fast (ship) or
    --release=safe (soak candidate)".
  - `.system` SDL on Linux/macOS: "a package must bundle the pinned SDL; drop
    -Dsystem-sdl".
  - A macOS target on a non-macOS host: already a 52A source-mode error.
  - A resolved `native` CPU baseline or an explicit `-Dcpu=`: the 52A
    dev/bench-only refusal, kept here.
- **Staging:** `zig-out/package/<stage>/`, an install dir of type `.custom`.
  It is separate from the dev `zig-out/bin` layout, which `run`, `dev`, and
  `gpu-smoke` keep using unchanged. Archiving is 52C's job, using
  `tar`/`zip`/`ditto`; Zig has no archive step.
- **Layouts** (`<stage>` = `<app-name>-<version>-<os>-<arch>`):

  | OS | Layout |
  | --- | --- |
  | Linux | `<app-name>` (RUNPATH `$ORIGIN/lib`), `lib/libSDL3.so.0`, `lib/libSDL3_ttf.so.0`, `lib/libSDL3_mixer.so.0`, `assets/…` (shaders `*.spv`), `<app-name>.desktop`, `<app-name>.png` (256×256), `licenses/` |
  | Windows | `<app-name>.exe` (icon + VERSIONINFO; GUI subsystem in ship modes), `SDL3.dll`, `SDL3_ttf.dll`, `SDL3_mixer.dll`, `assets/…` (shaders `*.dxil`), `licenses/`. The `.pdb` is not staged; it is installed to `zig-out/package-symbols/<stage>/<app-name>.pdb` instead, and 52C uploads it as a separate symbols artifact. |
  | macOS | `<app-name>.app/Contents/{Info.plist, MacOS/<app-name>, Frameworks/libSDL3.0.dylib + libSDL3_ttf.0.dylib + libSDL3_mixer.0.dylib, Resources/<app-name>.icns, Resources/assets/… (shaders *.msl), Resources/licenses/}`, inside `<stage>/` |

- **Linux:**
  - The `.desktop` file comes from `platforms/linux/app.desktop.in`, rendered
    with ConfigHeader cmake style. Fields:
    - `Type=Application`
    - `Name=${WINDOW_TITLE}`
    - `Exec=${APP_NAME}`
    - `Icon=${APP_NAME}`
    - `StartupWMClass=${APP_IDENTIFIER}`
    - `Categories=Game;`
  - **Format decision: tarball directory, not AppImage.** Steam depots and
    itch.io both take a plain directory or tarball. 52C builds inside Steam's
    sniper runtime container. AppImage would add appimagetool, a FUSE
    dependency, and a second runtime, with no gain on Steam. AppImage is
    Slice 66C.
- **Windows:**
  - **PDB.** For windows-gnu, `Compile.producesPdbFile` is true when
    `use_llvm != false`, and Zig's default ReleaseFast selection uses the
    LLVM backend, so `producesPdbFile()` is true and the PDB is emitted
    (Windows LTO is off per 52A). When `exe.producesPdbFile()`, the
    `package` step adds an `addInstallFile(exe.getEmittedPdb(), …)` into a `.custom`
    `package-symbols/<stage>/` install dir, outside the staging dir, and a
    `CheckFile` that the PDB exists there. It is never copied into
    `zig-out/package/<stage>/`.
  - `exe.subsystem = .windows` unless `-Dwindows-console=<bool>` is true.
    `-Dwindows-console` defaults to
    `optimize == .debug or optimize == .safe`.
  - Unlike VoidLight, ReleaseSafe keeps the console: Safe's auto log level is
    `debug` and it prints perf dumps (`build.zig:744-751`), and soaks need that
    stderr.
  - The resource file is generated with `addWriteFiles` from a template in
    `build.zig`. It contains:
    - `1 ICON "app.ico"`;
    - a `VS_VERSION_INFO` block with numeric FileVersion/ProductVersion
      `M,m,p,0` from the zon semver, plus ProductName, FileDescription, and
      OriginalFilename strings.
  - It is added with
    `exe.root_module.addWin32ResourceFile(.{ .file = rc, .include_paths = &.{b.path("platforms/windows")} })`.
  - `Engine.init` sets `SDL_HINT_WINDOWS_INTRESOURCE_ICON` and `_SMALL` to
    `"1"` on Windows before creating the window, so the window and taskbar use
    resource 1.
- **macOS:**
  - `platforms/macos/Info.plist.in` is VoidLight's template, ported verbatim
    via ConfigHeader cmake style. It adds `LSMinimumSystemVersion`, set to the
    resolved target's macOS minimum (11.0 for the release target, 52C).
  - The exe gets the `@executable_path/../Frameworks` rpath from 52A.
  - Ad-hoc signing is a Run step `codesign --force --deep --sign - <app-name>.app`.
    It runs with cwd at the install prefix, sets `has_side_effects = true`,
    depends on every bundle install step, and runs on macOS hosts only.
  - Re-signing after assembly is required: Apple Silicon will not run unsigned
    code, and changing a signed bundle invalidates the linker's ad-hoc
    signature on the exe.
  - Developer ID signing, notarization, and `.dmg` are Slice 66C.
- **AssetStore macOS bundle fallback:**
  - A third resolution candidate after the exe-relative one, compiled only when
    `builtin.os.tag == .macos`. If the exe dir ends in `Contents/MacOS`, try
    `<…>/Contents/Resources/<root>/<relative>`.
  - New pure helper `bundleContentsDir(exe_dir: []const u8) ?[]const u8`. It
    returns the `…/Contents` prefix slice and does not allocate.
  - It keeps the existing semantics: it fires only when the configured root is
    absent, and it is logged at debug through `logging.assets`, like
    `assets.zig:72`.
- **Licenses:** `licenses/` contains:
  - ZeroLight's `LICENSE`;
  - `LICENSE.txt` from each pinned SDL package (source tarball on Linux/macOS,
    VC zip on Windows);
  - FreeType's `docs/FTL.TXT` from SDL_ttf's vendored `external/freetype` on
    Linux/macOS, because the FTL requires credit in documentation;
  - the Noto font license, which already ships under `assets/fonts/`.
- **macOS LTO stays off.** This is unchanged and re-checked at each Zig upgrade
  under the 52A policy.
  - The cost is bounded: Zig emits all Zig code as one LLVM module, so
    `-flto=full` on Linux only adds inlining across the
    compiler_rt/libc boundary.
  - There is no LTO toggle to A/B today. Measure in the upgrade that makes
    Mach-O LTO possible.
- **No symbol stripping.** ReleaseFast panic traces need DWARF/PDB. Linux
  keeps DWARF in the binary; macOS DWARF lives only in the build cache's
  `_zcu.o` (N_OSO stabs), so `dsymutil` extracts it at package time; Windows
  uses the PDB. Slice 66A strips and stores them.
- **Self-validation:** the `package` step depends on `CheckFile` steps for:
  - every expected staging file (the exe, each bundled lib, and
    `assets/shaders/<stem>.<target-ext>` for all four stages);
  - `Info.plist` and `.desktop`, with `expected_matches` on the substituted
    identifier and version.

  A broken layout fails the build, not a player's machine.
- **Icons:** `platforms/linux/app-256.png`, `platforms/windows/app.ico`, and
  `platforms/macos/app.icns`.
  - The initial placeholders are VoidLight's `res/img/icon.{png,ico,icns}`
    (same owner, Hammer Forged Games).
  - Each game replaces these three files; this is documented.
  - Add `platforms` to `build.zig.zon` `.paths`.

### Checklist

- [ ] **Identity options.** Add the `-Dapp-name` charset check,
      `-Dbundle-id` with its derived default, the `app_version` and
      `app_identifier` build options, and the `SDL_SetAppMetadata` call in
      `Engine.init`.
- [ ] **Package graph.** Build the per-OS staging install graph under
      `zig-out/package/<stage>/`, add the Debug and system-SDL refusals, and
      add the self-validating `CheckFile`s.
- [ ] **Linux.** Install `lib/` SONAME files, render the `.desktop` from its
      template, add the PNG icon, and add `licenses/`.
- [ ] **Windows.**
  - Add `-Dwindows-console` and set the subsystem from it.
  - Generate the `.rc` (icon plus VERSIONINFO) and wire it with
    `addWin32ResourceFile`.
  - Set the `SDL_HINT_WINDOWS_INTRESOURCE_ICON` hints.
  - Install the PDB from `exe.getEmittedPdb()` to
    `zig-out/package-symbols/<stage>/`, never into staging, with its
    `CheckFile`.
- [ ] **macOS.**
  - Assemble the `.app` (Info.plist template, icns, Frameworks dylibs,
    Resources/assets, licenses).
  - Add the ad-hoc `codesign` Run step.
  - Add the `bundleContentsDir` fallback in `AssetStore`, with unit tests
    covering a bundle path, a trailing separator, a non-bundle path, and a
    `MacOS` dir not under `Contents`.
- [ ] **Placeholders and paths.** Add the `platforms/` templates and
      placeholder icons, and add `platforms` to the zon `.paths`.
- [ ] **Docs.**
  - `docs/development-workflow.md` Packaging section: layouts, the App
    identity table, refusals, local versus distributable packages, the
    symbols dir, and icon replacement.
  - `docs/architecture.md`: asset resolution order including the macOS
    bundle, and `platforms/` ownership.
  - `README.md` package line.
- [ ] (added by Slice 66) Replace the Windows PDB note's "full LTO forces LLVM
      (`build.zig:144`), so every ReleaseFast Windows package emits one"
      with "Zig's default ReleaseFast selection uses the LLVM backend, so
      `producesPdbFile()` is true and the PDB is emitted (Windows LTO is off
      per 52A)". Replace the "macOS LTO stays off" bullet's "`-flto=full` on
      Linux/Windows" with "on Linux".
- [ ] (added by Slice 66) Commit the placeholder `platforms/linux/app-256.png` at 256×256: a
      one-time nearest-neighbour upscale of VoidLight's 128×128
      `res/img/icon.png` (`magick icon.png -filter point -resize 256x256
      app-256.png`; no build-time tool). The layout table promises
      256×256, and 66A's icon test asserts it. Acceptance: `file
      platforms/linux/app-256.png` reports `256 x 256`.
- [ ] (added by Slice 66) **dsymutil at package time (macOS hosts).** A Run step `dsymutil
      <exe> -o <out-dir>/<app-name>.dSYM` (`addOutputDirectoryArg`) on the
      linked exe, installed to `zig-out/package-symbols/<stage>/`, with a
      `CheckFile` on `<app-name>.dSYM/Contents/Resources/DWARF/<app-name>`.
      The bundle install and the ad-hoc `codesign` step depend on it. Replace
      the "No symbol stripping … Split symbols go to Scaling Gaps" bullet
      with "No symbol stripping. Linux keeps DWARF in the binary; macOS
      DWARF lives only in the build cache's `_zcu.o` (N_OSO stabs), so
      `dsymutil` extracts it at package time; Windows uses the PDB. Slice
      66A strips and stores them." Acceptance (on a Mac): `dwarfdump --uuid`
      is identical for the bundle exe and the dSYM.

### Acceptance checks

- [ ] Linux `zig build package --release=fast`:
  - `readelf -d` shows RUNPATH `$ORIGIN/lib` and no `.zig-cache` path.
  - `ldd` resolves all three SDL libs from `<stage>/lib`.
  - Run manually on a display, the exe launches from an unrelated cwd
    (`cd /tmp && <stage>/<app-name>`) and renders.
- [ ] Windows (`zig build package --release=fast -Dtarget=x86_64-windows`,
      cross-built from Linux):
  - Staging contains the exe plus three DLLs, with `.dxil` shaders and no
    `.pdb`.
  - `zig-out/package-symbols/<stage>/<app-name>.pdb` exists.
  - The PE optional header reports subsystem `WINDOWS_GUI` (2).
  - With `--release=safe` it reports `WINDOWS_CUI` (3).
  - Manual, on a Windows host: the icon shows in Explorer and on the taskbar,
    and the game runs.
- [ ] macOS (on a Mac):
  - `codesign --verify --deep --strict <app-name>.app` passes.
  - `otool -L` shows `@rpath/libSDL3.0.dylib`.
  - `otool -l` lists `@executable_path/../Frameworks`.
  - Launched from Finder (cwd `/`), the app finds its assets through the bundle
    fallback.
- [ ] `package` with Debug, with `-Dsystem-sdl=true` on Linux/macOS, or with a
      `native` baseline or explicit `-Dcpu`, fails with its fix-it.
- [ ] `-Dapp-name="My Game"` fails at configure with the charset fix-it, and
      the default `-Dbundle-id` for `-Dapp-name=my_game` is
      `com.hammerforgedgames.my-game`.
- [ ] `bundleContentsDir` tests pass.
- [ ] `zig build verify` passes.
- [ ] The docs listed in the Checklist are updated.

### VoidLight reference

- `CMakeLists.txt:581-630` is the macOS release bundle:
  - `MACOSX_BUNDLE` with `platforms/macos/Info.plist.in`;
  - rpath `@executable_path/../Frameworks;@executable_path`;
  - SDL dylibs copied by SONAME into `Contents/Frameworks` (`:600-615`);
  - `res` copied into `Contents/Resources/res` (`:618-623`);
  - `codesign --force --deep --sign -` (`:626-629`).
  - **Port all of it.** ZeroLight adds the AssetStore bundle fallback, because
    its resolver does not know bundles. VoidLight also skips the bundle in
    Debug (`:553-580`); ZeroLight's dev layout is the plain `zig-out/bin`.
- `platforms/macos/Info.plist.in:1-30` sets `NSHighResolutionCapable`,
  `LSApplicationCategoryType = public.app-category.games`, and
  `LSSupportsGameMode`.
  - **Port verbatim**, plus `LSMinimumSystemVersion`.
- `CMakeLists.txt:502-531` handles icons: Windows uses
  `platforms/windows/windows_icon.rc.in:1-5` (`1 ICON "@APP_ICON_RESOURCE_WINDOWS@"`),
  and macOS uses `MACOSX_BUNDLE_ICON_FILE icon.icns`.
  - **Port**, extended with VERSIONINFO.
- `CMakeLists.txt:539-550` makes Windows console-only in Debug and
  `WIN32_EXECUTABLE` in Release.
  - **Port with one change:** ReleaseSafe keeps the console.
- `CMakeLists.txt:648-667` handles Windows DLL copy and install. ZeroLight
  already does this (`build.zig:583-629`).
- **No CPack.** VoidLight has no CPack (grep finds none) and no archive step.
  Its packaging is the bundle POST_BUILD plus the Windows `install(FILES)`.
  Archiving is net-new in 52C.

