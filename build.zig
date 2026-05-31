// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;
    const app_name = b.option([]const u8, "app-name", "Executable name") orelse "my-sdl3-game";
    const window_title = b.option([]const u8, "window-title", "SDL window title") orelse "SDL3 Zig Game";
    const asset_root = b.option([]const u8, "asset-root", "Runtime asset directory") orelse "assets";
    const gpu_debug = b.option(bool, "gpu-debug", "Enable SDL_GPU debug validation") orelse (optimize == .Debug);
    const shader_compiler = b.option([]const u8, "shader-compiler", "GLSL to SPIR-V compiler") orelse "glslc";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_name", app_name);
    build_options.addOption([]const u8, "window_title", window_title);
    build_options.addOption([]const u8, "asset_root", asset_root);
    build_options.addOption(bool, "gpu_debug", gpu_debug);

    const lib_mod = b.addModule("sdl3_Template", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = createGameModule(b, target, optimize, lib_mod, build_options);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = exe_mod,
    });

    const gpu_smoke_mod = createSdlModule(b, target, optimize, lib_mod, build_options, "src/gpu_smoke.zig");
    const gpu_smoke_exe = b.addExecutable(.{
        .name = "gpu-smoke",
        .root_module = gpu_smoke_mod,
    });

    const root_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const assets_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/assets.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const camera_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/camera.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const scene_unit_tests_mod = createSdlModule(b, target, optimize, lib_mod, build_options, "src/scene.zig");
    const scene_unit_tests = b.addTest(.{
        .root_module = scene_unit_tests_mod,
    });

    const frame_pacer_unit_tests_mod = createSdlModule(b, target, optimize, lib_mod, build_options, "src/frame_pacer.zig");
    const frame_pacer_unit_tests = b.addTest(.{
        .root_module = frame_pacer_unit_tests_mod,
    });

    const time_loop_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/time_loop.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const exe_unit_tests_mod = createGameModule(b, target, optimize, lib_mod, build_options);
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_unit_tests_mod,
    });

    b.installArtifact(exe);
    b.installArtifact(gpu_smoke_exe);
    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });

    const shader_outputs = addShaderSteps(b, shader_compiler);

    const check_step = b.step("check", "Compile without installing");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&gpu_smoke_exe.step);

    const fmt_step = b.step("fmt", "Format Zig source files");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{
            "build.zig",
            "src",
        },
    }).step);

    const shaders_step = b.step("shaders", "Compile and install SPIR-V shaders");
    for (shader_outputs.install_steps) |install_step| {
        shaders_step.dependOn(install_step);
        b.getInstallStep().dependOn(install_step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const dev_step = b.step("dev", "Build shaders, install assets, and run the app");
    dev_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(root_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(assets_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(camera_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(scene_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(frame_pacer_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(time_loop_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);

    const verify_step = b.step("verify", "Run non-interactive checks for local development");
    verify_step.dependOn(check_step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(shaders_step);

    const gpu_smoke_run = b.addRunArtifact(gpu_smoke_exe);
    gpu_smoke_run.step.dependOn(b.getInstallStep());
    const gpu_smoke_step = b.step("gpu-smoke", "Create an SDL_GPU device and submit one frame");
    gpu_smoke_step.dependOn(&gpu_smoke_run.step);

    const package_step = b.step("package", "Install binaries and runtime assets for the selected optimize mode");
    package_step.dependOn(b.getInstallStep());
}

fn createGameModule(
    b: *std.Build,
    target: anytype,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    build_options: *std.Build.Step.Options,
) *std.Build.Module {
    return createSdlModule(b, target, optimize, lib_mod, build_options, "src/main.zig");
}

fn createSdlModule(
    b: *std.Build,
    target: anytype,
    optimize: std.builtin.OptimizeMode,
    lib_mod: *std.Build.Module,
    build_options: *std.Build.Step.Options,
    root_source_file: []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("sdl3_Template", lib_mod);
    mod.addOptions("build_options", build_options);
    mod.linkSystemLibrary("SDL3", .{});
    return mod;
}

const ShaderOutputs = struct {
    install_steps: []const *std.Build.Step,
};

fn addShaderSteps(b: *std.Build, shader_compiler: []const u8) ShaderOutputs {
    const allocator = b.allocator;
    const install_steps = allocator.alloc(*std.Build.Step, 2) catch @panic("OOM");

    const vert_cmd = b.addSystemCommand(&.{ shader_compiler, "-fshader-stage=vert" });
    vert_cmd.addFileArg(b.path("assets/shaders/sprite.vert.glsl"));
    vert_cmd.addArg("-o");
    const vert_spv = vert_cmd.addOutputFileArg("sprite.vert.spv");
    install_steps[0] = &b.addInstallBinFile(vert_spv, "assets/shaders/sprite.vert.spv").step;

    const frag_cmd = b.addSystemCommand(&.{ shader_compiler, "-fshader-stage=frag" });
    frag_cmd.addFileArg(b.path("assets/shaders/sprite.frag.glsl"));
    frag_cmd.addArg("-o");
    const frag_spv = frag_cmd.addOutputFileArg("sprite.frag.spv");
    install_steps[1] = &b.addInstallBinFile(frag_spv, "assets/shaders/sprite.frag.spv").step;

    return .{ .install_steps = install_steps };
}
