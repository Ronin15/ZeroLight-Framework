// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");

const shader_format_spirv: u32 = 1 << 1;
const shader_format_msl: u32 = 1 << 4;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_name = b.option([]const u8, "app-name", "Executable name") orelse "my-sdl3-game";
    const window_title = b.option([]const u8, "window-title", "SDL window title") orelse "SDL3 Zig Game";
    const asset_root = b.option([]const u8, "asset-root", "Runtime asset directory") orelse "assets";
    const gpu_debug = b.option(bool, "gpu-debug", "Enable SDL_GPU debug validation") orelse (optimize == .Debug);
    const shader_compiler = b.option([]const u8, "shader-compiler", "GLSL to SPIR-V compiler") orelse "glslc";
    const shader_cross_compiler = b.option([]const u8, "shader-cross-compiler", "SPIR-V to platform shader compiler") orelse "spirv-cross";
    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay rendering") orelse true;
    const gpu_shader_formats = shaderFormatsForTarget(target.result.os.tag);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_name", app_name);
    build_options.addOption([]const u8, "window_title", window_title);
    build_options.addOption([]const u8, "asset_root", asset_root);
    build_options.addOption(bool, "gpu_debug", gpu_debug);
    build_options.addOption(bool, "debug_overlay", debug_overlay);
    build_options.addOption(u32, "gpu_shader_formats", gpu_shader_formats);

    const exe_mod = createGameModule(b, target, optimize, build_options);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = exe_mod,
    });

    const gpu_smoke_mod = createSdlModule(b, target, optimize, build_options, "src/gpu_smoke.zig");
    const gpu_smoke_exe = b.addExecutable(.{
        .name = "gpu-smoke",
        .root_module = gpu_smoke_mod,
    });

    const unit_tests_mod = createSdlModule(b, target, optimize, build_options, "src/tests.zig");
    const unit_tests = b.addTest(.{
        .root_module = unit_tests_mod,
    });

    b.installArtifact(exe);
    b.installDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = asset_root,
        .exclude_extensions = &.{ ".glsl", ".spv", ".msl", ".gitkeep" },
    });

    const shader_outputs = addShaderSteps(b, target.result.os.tag, shader_compiler, shader_cross_compiler, asset_root);

    const check_step = b.step("check", "Compile without installing");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&gpu_smoke_exe.step);

    const fmt_step = b.step("fmt", "Format Zig source files");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{
            "build.zig",
            "build.zig.zon",
            "src",
        },
    }).step);

    const shaders_step = b.step("shaders", "Compile and install platform GPU shaders");
    for (shader_outputs.install_steps) |install_step| {
        shaders_step.dependOn(install_step);
        b.getInstallStep().dependOn(install_step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const dev_step = b.step("dev", "Build shaders, install assets, and run the app");
    dev_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const verify_step = b.step("verify", "Run non-interactive checks for local development");
    verify_step.dependOn(check_step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(shaders_step);

    const gpu_smoke_run = b.addRunArtifact(gpu_smoke_exe);
    const gpu_smoke_install = b.addInstallArtifact(gpu_smoke_exe, .{});
    gpu_smoke_run.step.dependOn(&gpu_smoke_install.step);
    gpu_smoke_run.step.dependOn(b.getInstallStep());
    gpu_smoke_run.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    const gpu_smoke_step = b.step("gpu-smoke", "Create an SDL_GPU device and submit one frame");
    gpu_smoke_step.dependOn(&gpu_smoke_run.step);

    const package_step = b.step("package", "Install binaries and runtime assets for the selected optimize mode");
    package_step.dependOn(b.getInstallStep());
}

fn createGameModule(
    b: *std.Build,
    target: anytype,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
) *std.Build.Module {
    return createSdlModule(b, target, optimize, build_options, "src/main.zig");
}

fn createSdlModule(
    b: *std.Build,
    target: anytype,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    root_source_file: []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", build_options);
    mod.linkSystemLibrary("SDL3", .{});
    mod.linkSystemLibrary("SDL3_ttf", .{});
    return mod;
}

const ShaderOutputs = struct {
    install_steps: []const *std.Build.Step,
};

fn shaderFormatsForTarget(os_tag: std.Target.Os.Tag) u32 {
    return switch (os_tag) {
        .macos => shader_format_msl,
        .linux => shader_format_spirv,
        else => @panic("unsupported SDL_GPU shader target: add shader generation for this OS"),
    };
}

fn addShaderSteps(
    b: *std.Build,
    os_tag: std.Target.Os.Tag,
    shader_compiler: []const u8,
    shader_cross_compiler: []const u8,
    asset_root: []const u8,
) ShaderOutputs {
    return switch (os_tag) {
        .macos => addMslShaderSteps(b, shader_compiler, shader_cross_compiler, asset_root),
        .linux => addSpirvShaderSteps(b, shader_compiler, asset_root),
        else => @panic("unsupported SDL_GPU shader target: add shader generation for this OS"),
    };
}

fn addSpirvShaderSteps(b: *std.Build, shader_compiler: []const u8, asset_root: []const u8) ShaderOutputs {
    const allocator = b.allocator;
    const install_steps = allocator.alloc(*std.Build.Step, 2) catch @panic("OOM");

    const vert_cmd = b.addSystemCommand(&.{ shader_compiler, "-fshader-stage=vert" });
    vert_cmd.addFileArg(b.path("assets/shaders/sprite.vert.glsl"));
    vert_cmd.addArg("-o");
    const vert_spv = vert_cmd.addOutputFileArg("sprite.vert.spv");
    install_steps[0] = &b.addInstallBinFile(vert_spv, b.fmt("{s}/shaders/sprite.vert.spv", .{asset_root})).step;

    const frag_cmd = b.addSystemCommand(&.{ shader_compiler, "-fshader-stage=frag" });
    frag_cmd.addFileArg(b.path("assets/shaders/sprite.frag.glsl"));
    frag_cmd.addArg("-o");
    const frag_spv = frag_cmd.addOutputFileArg("sprite.frag.spv");
    install_steps[1] = &b.addInstallBinFile(frag_spv, b.fmt("{s}/shaders/sprite.frag.spv", .{asset_root})).step;

    return .{ .install_steps = install_steps };
}

fn addMslShaderSteps(
    b: *std.Build,
    shader_compiler: []const u8,
    shader_cross_compiler: []const u8,
    asset_root: []const u8,
) ShaderOutputs {
    const allocator = b.allocator;
    const install_steps = allocator.alloc(*std.Build.Step, 2) catch @panic("OOM");

    const vert_spv_cmd = b.addSystemCommand(&.{ shader_compiler, "-fshader-stage=vert" });
    vert_spv_cmd.addFileArg(b.path("assets/shaders/sprite.vert.glsl"));
    vert_spv_cmd.addArg("-o");
    const vert_spv = vert_spv_cmd.addOutputFileArg("sprite.vert.spv");

    const vert_msl_cmd = b.addSystemCommand(&.{shader_cross_compiler});
    vert_msl_cmd.addFileArg(vert_spv);
    vert_msl_cmd.addArgs(&.{ "--msl", "--stage", "vert", "--output" });
    const vert_msl = vert_msl_cmd.addOutputFileArg("sprite.vert.msl");
    install_steps[0] = &b.addInstallBinFile(vert_msl, b.fmt("{s}/shaders/sprite.vert.msl", .{asset_root})).step;

    const frag_spv_cmd = b.addSystemCommand(&.{ shader_compiler, "-fshader-stage=frag" });
    frag_spv_cmd.addFileArg(b.path("assets/shaders/sprite.frag.glsl"));
    frag_spv_cmd.addArg("-o");
    const frag_spv = frag_spv_cmd.addOutputFileArg("sprite.frag.spv");

    const frag_msl_cmd = b.addSystemCommand(&.{shader_cross_compiler});
    frag_msl_cmd.addFileArg(frag_spv);
    frag_msl_cmd.addArgs(&.{ "--msl", "--stage", "frag", "--output" });
    const frag_msl = frag_msl_cmd.addOutputFileArg("sprite.frag.msl");
    install_steps[1] = &b.addInstallBinFile(frag_msl, b.fmt("{s}/shaders/sprite.frag.msl", .{asset_root})).step;

    return .{ .install_steps = install_steps };
}
