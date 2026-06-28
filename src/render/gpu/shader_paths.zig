// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Comptime path derivation for installed GPU shader bytecode files.
//!
//! Paths follow the naming convention produced by the build system:
//! `shaders/{name}.{stage}.{ext}` (e.g. `shaders/sprite.vert.spv`).
//! Use these instead of writing path strings in material descriptors to
//! eliminate per-descriptor typos within a material's six path fields.

pub fn vertex(comptime name: []const u8, comptime ext: []const u8) []const u8 {
    return "shaders/" ++ name ++ ".vert." ++ ext;
}

pub fn fragment(comptime name: []const u8, comptime ext: []const u8) []const u8 {
    return "shaders/" ++ name ++ ".frag." ++ ext;
}
