// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

const shader_format_spirv: u32 = 1 << 1;
const shader_format_dxil: u32 = 1 << 3;
const shader_format_msl: u32 = 1 << 4;

const windows_sdl_dependencies = [_]WindowsSdlDependency{
    .{
        .name = "SDL3",
        .dependency_name = "sdl3_windows_vc",
        .root_dir = "SDL3-3.4.10",
        .headers = &.{ "include/SDL3/SDL.h", "include/SDL3/SDL_gpu.h" },
        .library = "SDL3.lib",
        .dll = "SDL3.dll",
    },
    .{
        .name = "SDL3_ttf",
        .dependency_name = "sdl3_ttf_windows_vc",
        .root_dir = "SDL3_ttf-3.2.2",
        .headers = &.{"include/SDL3_ttf/SDL_ttf.h"},
        .library = "SDL3_ttf.lib",
        .dll = "SDL3_ttf.dll",
    },
    .{
        .name = "SDL3_mixer",
        .dependency_name = "sdl3_mixer_windows_vc",
        .root_dir = "SDL3_mixer-3.2.4",
        .headers = &.{"include/SDL3_mixer/SDL_mixer.h"},
        .library = "SDL3_mixer.lib",
        .dll = "SDL3_mixer.dll",
    },
};

const shader_programs = [_]ShaderProgram{
    .{
        .name = "sprite",
        .stages = .{
            .{
                .stage = .vertex,
                .source_path = "assets/shaders/sprite.vert.glsl",
                .output_stem = "sprite.vert",
                .msl_entry_signature = "main0(main0_in in [[stage_in]], constant FrameUniform& u [[buffer(0)]])",
            },
            .{
                .stage = .fragment,
                .source_path = "assets/shaders/sprite.frag.glsl",
                .output_stem = "sprite.frag",
                .msl_entry_signature = "main0(main0_in in [[stage_in]], texture2d<float> sprite_texture [[texture(0)]], sampler sprite_textureSmplr [[sampler(0)]])",
            },
        },
    },
    .{
        .name = "tilemap",
        .stages = .{
            .{
                .stage = .vertex,
                .source_path = "assets/shaders/tilemap.vert.glsl",
                .output_stem = "tilemap.vert",
                .msl_entry_signature = "main0(main0_in in [[stage_in]], constant FrameUniform& u [[buffer(0)]])",
            },
            .{
                .stage = .fragment,
                .source_path = "assets/shaders/tilemap.frag.glsl",
                .output_stem = "tilemap.frag",
                .msl_entry_signature = "main0(main0_in in [[stage_in]], constant TilemapUniform& tm [[buffer(0)]], const device TileData& tiles [[buffer(1)]], texture2d<float> atlas_texture [[texture(0)]], sampler atlas_textureSmplr [[sampler(0)]])",
            },
        },
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app-name", "Executable name") orelse "my-sdl3-game";
    const window_title = b.option([]const u8, "window-title", "SDL window title") orelse "SDL3 Zig Game";
    const asset_root = b.option([]const u8, "asset-root", "Runtime asset directory") orelse "assets";
    const gpu_debug = b.option(bool, "gpu-debug", "Enable SDL_GPU debug validation") orelse (optimize == .debug);
    const shader_compiler = b.option([]const u8, "shader-compiler", "GLSL to SPIR-V compiler") orelse "glslc";
    const shader_cross_compiler = b.option([]const u8, "shader-cross-compiler", "SPIR-V to platform shader compiler") orelse "spirv-cross";
    const dxil_compiler = b.option([]const u8, "dxil-compiler", "HLSL to DXIL compiler") orelse "dxc";
    const system_sdl = b.option(bool, "system-sdl", "Use system SDL libraries instead of pinned Zig package SDL on Windows") orelse (target.result.os.tag != .windows);
    const sdl_root = b.option([]const u8, "sdl-root", "Custom Windows SDL root containing SDL3-* directories");
    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay rendering") orelse true;
    const log_level_arg = b.option([]const u8, "log-level", "Log level: auto, err, warn, info, or debug") orelse "auto";
    const log_level = parseLogLevel(log_level_arg, optimize);
    // Benchmarks default quieter than the game (auto -> .warn regardless of optimize mode):
    // per-case debug logging (e.g. ThreadSystem re-init chatter, once per benchmark case that
    // uses threads) adds real overhead across the many cases/items a bench run sweeps and isn't
    // useful for reading a benchmark table. An explicit -Dlog-level=debug still overrides this
    // for bench troubleshooting, same as it does for the game build.
    const bench_log_level = parseLogLevel(log_level_arg, .fast);
    const gpu_shader_formats = shaderFormatsForTarget(target.result.os.tag);
    // Full LTO needs LLVM+LLD. Linux ships with `-flto=full`; Darwin and
    // Windows do not (see `ltoSupportedForTarget`).
    // Every other artifact and mode uses Zig's default backend/linker selection.
    const release_lto = optimize == .fast and ltoSupportedForTarget(target.result);
    const windows_sdl = configureWindowsSdl(b, target.result, system_sdl, sdl_root);
    const windows_sdl_checks = windowsSdlValidateSteps(windows_sdl);

    const buildOptions = b.addOptions();
    buildOptions.addOption([]const u8, "app_name", app_name);
    buildOptions.addOption([]const u8, "window_title", window_title);
    buildOptions.addOption([]const u8, "asset_root", asset_root);
    buildOptions.addOption(bool, "gpu_debug", gpu_debug);
    buildOptions.addOption(bool, "debug_overlay", debug_overlay);
    buildOptions.addOption(u8, "log_level", @backingInt(log_level));
    buildOptions.addOption(u32, "gpu_shader_formats", gpu_shader_formats);

    const benchBuildOptions = b.addOptions();
    benchBuildOptions.addOption([]const u8, "app_name", app_name);
    benchBuildOptions.addOption([]const u8, "window_title", window_title);
    benchBuildOptions.addOption([]const u8, "asset_root", asset_root);
    benchBuildOptions.addOption(bool, "gpu_debug", gpu_debug);
    benchBuildOptions.addOption(bool, "debug_overlay", debug_overlay);
    benchBuildOptions.addOption(u8, "log_level", @backingInt(bench_log_level));
    benchBuildOptions.addOption(u32, "gpu_shader_formats", gpu_shader_formats);

    const fetch_sdl_step = b.step("fetch-sdl", "Fetch pinned Windows SDL packages into zig-pkg/ and validate them");
    if (target.result.os.tag != .windows) {
        fetch_sdl_step.dependOn(&b.addFail("fetch-sdl is only needed for Windows targets").step);
    } else switch (windows_sdl) {
        .packages => for (windows_sdl_checks) |check| fetch_sdl_step.dependOn(check),
        .pending => {},
        .local => fetch_sdl_step.dependOn(&b.addFail("fetch-sdl is bypassed when -Dsdl-root is provided").step),
        .system => fetch_sdl_step.dependOn(&b.addFail("fetch-sdl is only needed for Windows package SDL; remove -Dsystem-sdl=true").step),
    }

    // One shared TranslateC step for the SDL headers (Zig 0.17 removed `@cImport`); every
    // SDL-linked module imports the same translated `sdl_c` module.
    const sdl_translate_c = createSdlTranslateC(b, target, optimize, windows_sdl);
    const sdl_c_module = sdl_translate_c.createModule();

    const exeModule = createGameModule(b, target, optimize, buildOptions, windows_sdl, sdl_c_module);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = exeModule,
        // LTO requires LLVM+LLD; force them explicitly rather than relying on
        // the ReleaseFast default. Otherwise use Zig's default selection.
        .use_llvm = if (release_lto) true else null,
        .use_lld = if (release_lto) true else null,
    });

    const gpuSmokeModule = createSdlModule(b, target, optimize, buildOptions, "src/gpu_smoke.zig", windows_sdl, sdl_c_module);
    const gpu_smoke_exe = b.addExecutable(.{
        .name = "gpu-smoke",
        .root_module = gpuSmokeModule,
    });

    const benchModule = createSdlModule(b, target, optimize, benchBuildOptions, "src/benchmark_runner.zig", windows_sdl, sdl_c_module);
    const bench_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_module = benchModule,
    });

    const unitTestsModule = createSdlModule(b, target, optimize, buildOptions, "src/tests.zig", windows_sdl, sdl_c_module);
    const unit_tests = b.addTest(.{
        .root_module = unitTestsModule,
    });

    // Ship/package mode: full LTO (`-flto=full`) for cross-module inlining and
    // dead-code elimination when the target supports it (see `release_lto`).
    if (release_lto) {
        exe.lto = .full;
    }

    b.installArtifact(exe);
    const windows_sdl_runtime = addWindowsSdlRuntimeDependencies(b, windows_sdl, windows_sdl_checks, &.{
        &sdl_translate_c.step,
        &exe.step,
        &gpu_smoke_exe.step,
        &bench_exe.step,
        &unit_tests.step,
    });
    const assets_install = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = asset_root,
        .exclude_extensions = &.{ ".glsl", ".spv", ".msl", ".dxil", ".hlsl", ".gitkeep" },
    });
    b.getInstallStep().dependOn(&assets_install.step);

    const shader_outputs = addShaderSteps(b, target.result.os.tag, shader_compiler, shader_cross_compiler, dxil_compiler, asset_root);

    const check_step = b.step("check", "Compile without installing");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&gpu_smoke_exe.step);
    check_step.dependOn(&bench_exe.step);

    const fmt_paths: []const std.Build.LazyPath = &.{
        b.path("build.zig"),
        b.path("build.zig.zon"),
        b.path("src"),
    };
    const fmt_step = b.step("fmt", "Format Zig source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);
    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });

    const shaders_step = b.step("shaders", "Compile and install platform GPU shaders");
    for (shader_outputs.install_steps) |install_step| {
        shaders_step.dependOn(install_step);
        b.getInstallStep().dependOn(install_step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    addWindowsSdlRunRuntime(run_cmd, windows_sdl_runtime);
    run_cmd.setCwd(.{ .relative = .{ .base = .install_bin } });
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const dev_step = b.step("dev", "Build shaders, install assets, and run the app");
    dev_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_run = b.addRunArtifact(unit_tests);
    addWindowsSdlRunRuntime(test_run, windows_sdl_runtime);
    test_step.dependOn(&test_run.step);

    const bench_run = b.addRunArtifact(bench_exe);
    addWindowsSdlRunRuntime(bench_run, windows_sdl_runtime);
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run CPU gameplay processor benchmarks");
    bench_step.dependOn(&bench_run.step);

    const assets_lint_cmd = b.addSystemCommand(&.{ "python3", "tools/lint_assets_if_changed.py" });
    const assets_lint_step = b.step("assets-lint", "Lint registered runtime atlases and source sprite consistency");
    assets_lint_step.dependOn(&assets_lint_cmd.step);

    const idiom_lint_cmd = b.addSystemCommand(&.{ "python3", "tools/lint_idioms.py" });
    const idiom_lint_step = b.step("idiom-lint", "Lint Zig sources for idiom/currency regressions (naming, deprecated stdlib, unsafe catch unreachable)");
    idiom_lint_step.dependOn(&idiom_lint_cmd.step);

    const verify_step = b.step("verify", "Run non-interactive checks for local development");
    verify_step.dependOn(check_step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(shaders_step);
    verify_step.dependOn(&assets_lint_cmd.step);
    verify_step.dependOn(&idiom_lint_cmd.step);
    verify_step.dependOn(&fmt_check.step);

    const gpu_smoke_run = b.addRunArtifact(gpu_smoke_exe);
    addWindowsSdlRunRuntime(gpu_smoke_run, windows_sdl_runtime);
    const gpu_smoke_install = b.addInstallArtifact(gpu_smoke_exe, .{});
    gpu_smoke_run.step.dependOn(&gpu_smoke_install.step);
    gpu_smoke_run.step.dependOn(&assets_install.step);
    for (shader_outputs.install_steps) |install_step| {
        gpu_smoke_run.step.dependOn(install_step);
    }
    gpu_smoke_run.setCwd(.{ .relative = .{ .base = .install_bin } });
    const gpu_smoke_step = b.step("gpu-smoke", "Create an SDL_GPU device and submit one frame");
    gpu_smoke_step.dependOn(&gpu_smoke_run.step);

    const package_step = b.step("package", "Install binaries and runtime assets for the selected optimize mode");
    package_step.dependOn(b.getInstallStep());
}

fn createGameModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    build_options: *std.Build.Step.Options,
    windows_sdl: WindowsSdlConfig,
    sdl_c_module: *std.Build.Module,
) *std.Build.Module {
    return createSdlModule(b, target, optimize, build_options, "src/main.zig", windows_sdl, sdl_c_module);
}

/// Translates `src/platform/sdl_c.h` (SDL3, SDL3_ttf, SDL3_mixer) once for the whole build.
/// Header search paths and C macros live here, not on the Zig modules: since Zig 0.17
/// replaced `@cImport` with a build-graph TranslateC step, no module compiles C itself.
fn createSdlTranslateC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    windows_sdl: WindowsSdlConfig,
) *std.Build.Step.TranslateC {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/sdl_c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) {
        // Zig's Windows GNU target uses bundled MinGW-w64 headers; their release-mode
        // fortify wrappers do not translate cleanly through translate-c.
        translate_c.defineCMacro("_FORTIFY_SOURCE", "0");
    }
    switch (windows_sdl) {
        .local => |local| {
            for (windows_sdl_dependencies) |dependency| {
                translate_c.addIncludePath(windowsSdlLocalPath(b, local.root, dependency.root_dir, "include"));
            }
        },
        .packages => |packages| {
            for (packages.packages) |package| {
                translate_c.addIncludePath(windowsSdlPackagePath(package, "include"));
            }
        },
        .system => {
            // System SDL headers may only be reachable through pkg-config `--cflags`
            // (custom prefix + PKG_CONFIG_PATH, MacPorts, Homebrew). TranslateC applies
            // pkg-config only for libraries linked on the step itself. Limited to `.system`:
            // pkg-config has no cross-target guard, so the Windows `.local`/`.packages` arms
            // would leak host include paths into a cross translation.
            translate_c.linkSystemLibrary("SDL3", .{});
            translate_c.linkSystemLibrary("SDL3_ttf", .{});
            translate_c.linkSystemLibrary("SDL3_mixer", .{});
        },
        .pending => {},
    }
    return translate_c;
}

fn createSdlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    build_options: *std.Build.Step.Options,
    root_source_file: []const u8,
    windows_sdl: WindowsSdlConfig,
    sdl_c_module: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", build_options);
    mod.addImport("sdl_c", sdl_c_module);
    switch (windows_sdl) {
        .local => |local| {
            for (windows_sdl_dependencies) |dependency| {
                mod.addLibraryPath(windowsSdlLocalLibPath(b, local, dependency));
            }
        },
        .packages => |packages| {
            for (packages.packages) |package| {
                mod.addLibraryPath(windowsSdlPackageLibPath(b, package, packages.arch_subdir));
            }
        },
        .system, .pending => {},
    }
    mod.linkSystemLibrary("SDL3", .{});
    mod.linkSystemLibrary("SDL3_ttf", .{});
    mod.linkSystemLibrary("SDL3_mixer", .{});
    return mod;
}

const ShaderOutputs = struct {
    install_steps: []const *std.Build.Step,
};

const WindowsSdlConfig = union(enum) {
    system,
    pending,
    local: WindowsSdlLocalConfig,
    packages: WindowsSdlPackageConfig,
};

const WindowsSdlDependency = struct {
    name: []const u8,
    dependency_name: []const u8,
    root_dir: []const u8,
    headers: []const []const u8,
    library: []const u8,
    dll: []const u8,
};

const WindowsSdlLocalConfig = struct {
    root: []const u8,
    arch_subdir: []const u8,
    validate_steps: []const *std.Build.Step,
};

const WindowsSdlPackageConfig = struct {
    arch_subdir: []const u8,
    packages: []const WindowsSdlPackage,
    validate_steps: []const *std.Build.Step,
};

const WindowsSdlPackage = struct {
    metadata: WindowsSdlDependency,
    dependency: *std.Build.Dependency,
};

const WindowsSdlRuntimeDependencies = struct {
    install_steps: []const *std.Build.Step,
    /// Full PATH value for Run steps (SDL DLL dirs prepended), or null when the host is
    /// not Windows or SDL comes from the system.
    path_env: ?[]const u8,
};

const WindowsSdlValidationEntry = struct {
    name: []const u8,
    path: std.Build.LazyPath,
};

// Fix-it hints carried in each check step's name, so a missing file fails on a step line
// that says how to recover instead of on a later translate-c/link error.
const windows_sdl_package_hint = "if missing: run 'zig build fetch-sdl', or pass -Dsystem-sdl=true or -Dsdl-root=<path>";
const windows_sdl_local_hint = "if missing: fix -Dsdl-root=<path>, or pass -Dsystem-sdl=true";

/// One `CheckFile` step per required header/import library/DLL. Zig 0.17 has no custom
/// build steps (`Step.init` takes a closed tag set with no `makeFn`), so the old single
/// validation step is expressed as stock CheckFile steps that fail when the file is missing.
fn createWindowsSdlFileChecks(
    b: *std.Build,
    entries: []const WindowsSdlValidationEntry,
    hint: []const u8,
) []const *std.Build.Step {
    const checks = b.allocator.alloc(*std.Build.Step, entries.len) catch @panic("OOM");
    for (entries, checks) |entry, *check_step| {
        const check = b.addCheckFile(entry.path, .{});
        check.setName(b.fmt("check Windows {s} ({s})", .{ entry.name, hint }));
        check_step.* = &check.step;
    }
    return checks;
}

fn windowsSdlValidateSteps(windows_sdl: WindowsSdlConfig) []const *std.Build.Step {
    return switch (windows_sdl) {
        .local => |local| local.validate_steps,
        .packages => |packages| packages.validate_steps,
        .system, .pending => &.{},
    };
}

fn configureWindowsSdl(
    b: *std.Build,
    target: std.Target,
    system_sdl: bool,
    sdl_root: ?[]const u8,
) WindowsSdlConfig {
    if (target.os.tag != .windows or system_sdl) {
        return .system;
    }

    const arch_subdir = windowsSdlArchSubdir(target.cpu.arch);
    if (sdl_root) |root| {
        return .{ .local = .{
            .root = b.dupe(root),
            .arch_subdir = arch_subdir,
            .validate_steps = createWindowsSdlLocalChecks(b, root, arch_subdir),
        } };
    }

    const packages = b.allocator.alloc(WindowsSdlPackage, windows_sdl_dependencies.len) catch @panic("OOM");
    var all_available = true;
    for (windows_sdl_dependencies, 0..) |dependency, index| {
        if (b.lazyDependency(dependency.dependency_name, .{})) |package| {
            packages[index] = .{
                .metadata = dependency,
                .dependency = package,
            };
        } else {
            all_available = false;
        }
    }

    if (!all_available) {
        return .pending;
    }

    return .{ .packages = .{
        .arch_subdir = arch_subdir,
        .packages = packages,
        .validate_steps = createWindowsSdlPackageChecks(b, packages, arch_subdir),
    } };
}

fn windowsSdlArchSubdir(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => std.debug.panic("unsupported Windows SDL package architecture: {}", .{arch}),
    };
}

fn createWindowsSdlLocalChecks(b: *std.Build, root: []const u8, arch_subdir: []const u8) []const *std.Build.Step {
    const entries = b.allocator.alloc(WindowsSdlValidationEntry, windowsSdlValidationEntryCount()) catch @panic("OOM");
    var index: usize = 0;
    for (windows_sdl_dependencies) |dependency| {
        for (dependency.headers) |header| {
            entries[index] = .{
                .name = b.fmt("{s} header {s}", .{ dependency.name, header }),
                .path = windowsSdlLocalPath(b, root, dependency.root_dir, header),
            };
            index += 1;
        }
        entries[index] = .{
            .name = b.fmt("{s} import library", .{dependency.name}),
            .path = windowsSdlLocalPath(b, root, dependency.root_dir, b.pathJoin(&.{ "lib", arch_subdir, dependency.library })),
        };
        index += 1;
        entries[index] = .{
            .name = b.fmt("{s} DLL", .{dependency.name}),
            .path = windowsSdlLocalPath(b, root, dependency.root_dir, b.pathJoin(&.{ "lib", arch_subdir, dependency.dll })),
        };
        index += 1;
    }
    return createWindowsSdlFileChecks(b, entries, windows_sdl_local_hint);
}

fn createWindowsSdlPackageChecks(
    b: *std.Build,
    packages: []const WindowsSdlPackage,
    arch_subdir: []const u8,
) []const *std.Build.Step {
    const entries = b.allocator.alloc(WindowsSdlValidationEntry, windowsSdlValidationEntryCount()) catch @panic("OOM");
    var index: usize = 0;
    for (packages) |package| {
        const dependency = package.metadata;
        for (dependency.headers) |header| {
            const package_header = if (std.mem.startsWith(u8, header, "include/")) header else b.pathJoin(&.{ "include", header });
            entries[index] = .{
                .name = b.fmt("{s} header {s}", .{ dependency.name, header }),
                .path = windowsSdlPackagePath(package, package_header),
            };
            index += 1;
        }
        entries[index] = .{
            .name = b.fmt("{s} import library", .{dependency.name}),
            .path = windowsSdlPackagePath(package, b.pathJoin(&.{ "lib", arch_subdir, dependency.library })),
        };
        index += 1;
        entries[index] = .{
            .name = b.fmt("{s} DLL", .{dependency.name}),
            .path = windowsSdlPackagePath(package, b.pathJoin(&.{ "lib", arch_subdir, dependency.dll })),
        };
        index += 1;
    }
    return createWindowsSdlFileChecks(b, entries, windows_sdl_package_hint);
}

fn windowsSdlValidationEntryCount() usize {
    var count: usize = 0;
    for (windows_sdl_dependencies) |dependency| {
        count += dependency.headers.len + 2;
    }
    return count;
}

fn windowsSdlLocalPath(
    b: *std.Build,
    root: []const u8,
    dependency_root: []const u8,
    sub_path: []const u8,
) std.Build.LazyPath {
    return b.graph.cwdRelativePath(b.pathJoin(&.{ root, dependency_root, sub_path }));
}

fn windowsSdlPackagePath(package: WindowsSdlPackage, sub_path: []const u8) std.Build.LazyPath {
    return package.dependency.path(sub_path);
}

fn windowsSdlLocalLibPath(
    b: *std.Build,
    local: WindowsSdlLocalConfig,
    dependency: WindowsSdlDependency,
) std.Build.LazyPath {
    return windowsSdlLocalPath(b, local.root, dependency.root_dir, b.pathJoin(&.{ "lib", local.arch_subdir }));
}

fn windowsSdlPackageLibPath(
    b: *std.Build,
    package: WindowsSdlPackage,
    arch_subdir: []const u8,
) std.Build.LazyPath {
    return windowsSdlPackagePath(package, b.pathJoin(&.{ "lib", arch_subdir }));
}

fn addWindowsSdlRuntimeDependencies(
    b: *std.Build,
    windows_sdl: WindowsSdlConfig,
    validate_steps: []const *std.Build.Step,
    sdl_consumer_steps: []const *std.Build.Step,
) WindowsSdlRuntimeDependencies {
    switch (windows_sdl) {
        .local, .packages => {},
        .system, .pending => return .{ .install_steps = &.{}, .path_env = null },
    }

    for (sdl_consumer_steps) |consumer_step| {
        for (validate_steps) |check| consumer_step.dependOn(check);
    }

    const install_steps = b.allocator.alloc(*std.Build.Step, windows_sdl_dependencies.len) catch @panic("OOM");
    const path_dirs = b.allocator.alloc([]const u8, windows_sdl_dependencies.len) catch @panic("OOM");
    switch (windows_sdl) {
        .local => |local| {
            for (windows_sdl_dependencies, 0..) |dependency, index| {
                path_dirs[index] = b.pathJoin(&.{ local.root, dependency.root_dir, "lib", local.arch_subdir });
                const install_dll = b.addInstallBinFile(
                    windowsSdlLocalPath(b, local.root, dependency.root_dir, b.pathJoin(&.{ "lib", local.arch_subdir, dependency.dll })),
                    dependency.dll,
                );
                for (validate_steps) |check| install_dll.step.dependOn(check);
                b.getInstallStep().dependOn(&install_dll.step);
                install_steps[index] = &install_dll.step;
            }
        },
        .packages => |packages| {
            for (packages.packages, 0..) |package, index| {
                path_dirs[index] = package.dependency.builder.root.joinString(b.allocator, b.pathJoin(&.{ "lib", packages.arch_subdir })) catch @panic("OOM");
                const install_dll = b.addInstallBinFile(
                    windowsSdlPackagePath(package, b.pathJoin(&.{ "lib", packages.arch_subdir, package.metadata.dll })),
                    package.metadata.dll,
                );
                for (validate_steps) |check| install_dll.step.dependOn(check);
                b.getInstallStep().dependOn(&install_dll.step);
                install_steps[index] = &install_dll.step;
            }
        },
        .system, .pending => unreachable,
    }

    return .{ .install_steps = install_steps, .path_env = windowsSdlRunPath(b, path_dirs) };
}

/// PATH for Run steps that load the SDL DLLs straight from their source dirs, or null when
/// the host is not Windows (cross builds never run the binaries; DLLs are also installed
/// next to the executables). Zig 0.17 removed `Run.addPathDir`, and
/// `Run.setEnvironmentVariable` snapshots the configure-time environment into the step, so
/// the full PATH is computed here. The configure cache key does not include the environment,
/// so reading PATH and the cwd poisons the configure cache: Windows hosts re-run build.zig
/// on every `zig build` invocation.
fn windowsSdlRunPath(b: *std.Build, dirs: []const []const u8) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return null;
    b.graph.poisonCache();

    const cwd = std.process.currentPathAlloc(b.graph.io, b.allocator) catch |err|
        std.debug.panic("unable to read the current directory for the SDL DLL PATH: {t}", .{err});
    var path_env: std.ArrayList(u8) = .empty;
    for (dirs) |dir| {
        const absolute_dir = std.fs.path.resolveAlloc(b.allocator, &.{ cwd, dir }) catch @panic("OOM");
        path_env.appendSlice(b.allocator, absolute_dir) catch @panic("OOM");
        path_env.append(b.allocator, ';') catch @panic("OOM");
    }
    if (b.graph.environ_map.get("PATH")) |existing_path| {
        path_env.appendSlice(b.allocator, existing_path) catch @panic("OOM");
    } else {
        _ = path_env.pop();
    }
    return path_env.items;
}

fn addWindowsSdlRunRuntime(run: *std.Build.Step.Run, runtime: WindowsSdlRuntimeDependencies) void {
    for (runtime.install_steps) |install_step| {
        run.step.dependOn(install_step);
    }
    if (runtime.path_env) |path_env| {
        run.setEnvironmentVariable("PATH", path_env);
    }
}

const ShaderProgram = struct {
    name: []const u8,
    stages: [2]ShaderStageSource,
};

const ShaderStageSource = struct {
    stage: ShaderStage,
    source_path: []const u8,
    output_stem: []const u8,
    /// Exact generated MSL entry-point parameter list, `main0(` through `)`. Pins
    /// SDL_GPU's Metal slot layout (uniform buffers, then storage buffers, in
    /// [[buffer]]; textures/samplers from 0): Metal binds a mismatched slot silently
    /// and only rejects duplicate indices at shader creation.
    msl_entry_signature: []const u8,
};

const ShaderStage = enum {
    vertex,
    fragment,

    fn compilerArg(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "-fshader-stage=vert",
            .fragment => "-fshader-stage=frag",
        };
    }

    fn spirvCrossArg(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vert",
            .fragment => "frag",
        };
    }

    fn hlslTarget(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vs_6_0",
            .fragment => "ps_6_0",
        };
    }
};

fn shaderFormatsForTarget(os_tag: std.Target.Os.Tag) u32 {
    return switch (os_tag) {
        .macos => shader_format_msl,
        .linux => shader_format_spirv,
        .windows => shader_format_dxil,
        else => @panic("unsupported SDL_GPU shader target: add shader generation for this OS"),
    };
}

// Verify at build-compile time that the three currently supported targets each
// produce a format the runtime selectShaderSetFromFormats accepts (MSL > DXIL >
// SPIR-V). Adding a fourth OS requires updating this array as well.
comptime {
    const runtime_accepted: u32 = shader_format_spirv | shader_format_dxil | shader_format_msl;
    for ([_]std.Target.Os.Tag{ .macos, .linux, .windows }) |os_tag| {
        const built = shaderFormatsForTarget(os_tag);
        if ((built & runtime_accepted) == 0)
            @compileError("shaderFormatsForTarget produces a format the runtime cannot select");
    }
}

comptime {
    for (shader_programs) |program| {
        for (program.stages) |stage_source| {
            if (!std.mem.startsWith(u8, stage_source.msl_entry_signature, "main0("))
                @compileError("msl_entry_signature must be the generated MSL entry-point parameter list starting with main0(: " ++ stage_source.output_stem);
        }
    }
}

/// Zig 0.17 LTO requires LLD; LLD cannot link Mach-O object files.
/// Windows (COFF) is also excluded: under Zig 0.17, full and thin LTO with
/// `link_libc` fail at `lld-link` with undefined mingw libc/libm symbols
/// (`frexpf`, `lrintl`, `modfl`, `wmemcpy`, `strndup`, ...) for x86_64 and
/// aarch64 windows-gnu. Without LTO, ReleaseFast links and emits the PDB.
fn ltoSupportedForTarget(target: std.Target) bool {
    return switch (target.ofmt) {
        .macho, .coff => false,
        else => true,
    };
}

fn parseLogLevel(value: []const u8, optimize: std.builtin.Optimize) std.log.Level {
    if (std.mem.eql(u8, value, "auto")) {
        return switch (optimize) {
            // Debug + ReleaseSafe: full diagnostics and runtime perf dumps (see
            // runtime_perf_log.enabled). Fast/Small stay quiet for ship/package.
            .debug, .safe => .debug,
            .fast, .small => .warn,
        };
    }
    if (std.mem.eql(u8, value, "err")) return .err;
    if (std.mem.eql(u8, value, "warn")) return .warn;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "debug")) return .debug;

    std.debug.panic("unsupported -Dlog-level={s}; expected auto, err, warn, info, or debug", .{value});
}

fn addShaderSteps(
    b: *std.Build,
    os_tag: std.Target.Os.Tag,
    shader_compiler: []const u8,
    shader_cross_compiler: []const u8,
    dxil_compiler: []const u8,
    asset_root: []const u8,
) ShaderOutputs {
    return switch (os_tag) {
        .macos => addMslShaderSteps(b, shader_compiler, shader_cross_compiler, asset_root),
        .linux => addSpirvShaderSteps(b, shader_compiler, asset_root),
        .windows => addDxilShaderSteps(b, shader_compiler, shader_cross_compiler, dxil_compiler, asset_root),
        else => @panic("unsupported SDL_GPU shader target: add shader generation for this OS"),
    };
}

fn addSpirvShaderSteps(b: *std.Build, shader_compiler: []const u8, asset_root: []const u8) ShaderOutputs {
    const allocator = b.allocator;
    const install_steps = allocator.alloc(*std.Build.Step, shader_programs.len * 2) catch @panic("OOM");
    var install_index: usize = 0;

    for (shader_programs) |program| {
        for (program.stages) |stage_source| {
            const cmd = b.addSystemCommand(&.{ shader_compiler, stage_source.stage.compilerArg() });
            cmd.addFileArg(b.path(stage_source.source_path));
            cmd.addArg("-o");
            const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{stage_source.output_stem}));
            const check = b.addCheckFile(spv, .{});
            const install = b.addInstallBinFile(spv, b.fmt("{s}/shaders/{s}.spv", .{ asset_root, stage_source.output_stem }));
            install.step.dependOn(&check.step);
            install_steps[install_index] = &install.step;
            install_index += 1;
        }
    }

    return .{ .install_steps = install_steps };
}

fn addMslShaderSteps(
    b: *std.Build,
    shader_compiler: []const u8,
    shader_cross_compiler: []const u8,
    asset_root: []const u8,
) ShaderOutputs {
    const allocator = b.allocator;
    const install_steps = allocator.alloc(*std.Build.Step, shader_programs.len * 2) catch @panic("OOM");
    var install_index: usize = 0;

    for (shader_programs) |program| {
        for (program.stages) |stage_source| {
            const spv_cmd = b.addSystemCommand(&.{ shader_compiler, stage_source.stage.compilerArg() });
            spv_cmd.addFileArg(b.path(stage_source.source_path));
            spv_cmd.addArg("-o");
            const spv = spv_cmd.addOutputFileArg(b.fmt("{s}.spv", .{stage_source.output_stem}));

            const msl_cmd = b.addSystemCommand(&.{shader_cross_compiler});
            msl_cmd.addFileArg(spv);
            // Decoration binding pins MSL indices to the SPIR-V bindings. Without it
            // spirv-cross numbers [[buffer(n)]] by SPIR-V id order, which drifts with
            // shader code shape and can put a storage buffer in SDL's uniform slot.
            msl_cmd.addArgs(&.{ "--msl", "--msl-decoration-binding", "--stage", stage_source.stage.spirvCrossArg(), "--output" });
            const msl = msl_cmd.addOutputFileArg(b.fmt("{s}.msl", .{stage_source.output_stem}));
            const check = b.addCheckFile(msl, .{ .expected_matches = &.{stage_source.msl_entry_signature} });
            const install = b.addInstallBinFile(msl, b.fmt("{s}/shaders/{s}.msl", .{ asset_root, stage_source.output_stem }));
            install.step.dependOn(&check.step);
            install_steps[install_index] = &install.step;
            install_index += 1;
        }
    }

    return .{ .install_steps = install_steps };
}

fn addDxilShaderSteps(
    b: *std.Build,
    shader_compiler: []const u8,
    shader_cross_compiler: []const u8,
    dxil_compiler: []const u8,
    asset_root: []const u8,
) ShaderOutputs {
    const allocator = b.allocator;
    const install_steps = allocator.alloc(*std.Build.Step, shader_programs.len * 2) catch @panic("OOM");
    var install_index: usize = 0;

    for (shader_programs) |program| {
        for (program.stages) |stage_source| {
            const spv_cmd = b.addSystemCommand(&.{ shader_compiler, stage_source.stage.compilerArg() });
            spv_cmd.addFileArg(b.path(stage_source.source_path));
            spv_cmd.addArg("-o");
            const spv = spv_cmd.addOutputFileArg(b.fmt("{s}.spv", .{stage_source.output_stem}));

            const hlsl_cmd = b.addSystemCommand(&.{shader_cross_compiler});
            hlsl_cmd.addFileArg(spv);
            hlsl_cmd.addArgs(&.{ "--hlsl", "--shader-model", "60", "--output" });
            const hlsl = hlsl_cmd.addOutputFileArg(b.fmt("{s}.hlsl", .{stage_source.output_stem}));

            const dxil_cmd = b.addSystemCommand(&.{dxil_compiler});
            dxil_cmd.addArgs(&.{ "-E", "main", "-T", stage_source.stage.hlslTarget(), "-Fo" });
            const dxil = dxil_cmd.addOutputFileArg(b.fmt("{s}.dxil", .{stage_source.output_stem}));
            dxil_cmd.addFileArg(hlsl);

            const check = b.addCheckFile(dxil, .{});
            const install = b.addInstallBinFile(dxil, b.fmt("{s}/shaders/{s}.dxil", .{ asset_root, stage_source.output_stem }));
            install.step.dependOn(&check.step);
            install_steps[install_index] = &install.step;
            install_index += 1;
        }
    }

    return .{ .install_steps = install_steps };
}
