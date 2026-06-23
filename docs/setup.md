# Setup

This project expects system SDL3 libraries on Linux and macOS. Windows defaults
to pinned SDL packages fetched by Zig's package manager, so the repo does not
carry SDL binaries or custom fetch scripts. Default Windows builds use Zig's
native target and do not require an external MinGW or Visual Studio toolchain.

## Required Tools

- Zig 0.16.0 or a compatible 0.16.x build
- SDL3 development files (system packages on Linux/macOS, Zig-fetched packages on Windows)
- SDL3_ttf development files (system packages on Linux/macOS, Zig-fetched packages on Windows)
- SDL3_mixer development files (system packages on Linux/macOS, Zig-fetched packages on Windows)
- `glslc` for GLSL to SPIR-V compilation
- `spirv-cross` on macOS for SPIR-V to Metal shader conversion
- `spirv-cross` and `dxc` on Windows for SPIR-V to HLSL to DXIL shader conversion
- Python 3 plus Pillow for atlas packing, source-art export, and placeholder generation

The app uses core SDL3 PNG loading through `SDL_LoadPNG`; it does not require
`SDL3_image`.

Normal Zig builds and runtime atlas lint do not require Pillow unless
`source_assets/` is present and source-to-runtime atlas comparison runs.

## macOS

With Homebrew, install:

```sh
brew install sdl3 sdl3_ttf sdl3_mixer shaderc spirv-cross
```

SDL_GPU should select Metal when the build provides installed MSL shaders.

## Windows

Windows builds use pinned SDL development archives through `build.zig.zon`:

- SDL 3.4.10, `SDL3-devel-3.4.10-VC.zip`
- SDL_ttf 3.2.2, `SDL3_ttf-devel-3.2.2-VC.zip`
- SDL_mixer 3.2.4, `SDL3_mixer-devel-3.2.4-VC.zip`

Fetch or validate those packages with:

```sh
zig build fetch-sdl
```

Zig fetches only packages missing from its package cache, verifies the pinned
package hashes, and reuses the same cache for debug and release builds. The
`-VC.zip` archive names are SDL's published binary package names, not a
requirement to install Visual Studio. Normal Windows builds use the fetched
package paths automatically. If you already have SDL installed globally, pass
`-Dsystem-sdl=true`. If you have custom extracted SDL archives, pass
`-Dsdl-root=<path>` where that directory contains the
`SDL3-3.4.10`, `SDL3_ttf-3.2.2`, and `SDL3_mixer-3.2.4` directories.

Windows shader builds require `glslc`, `spirv-cross`, and `dxc` on `PATH` or
passed with `-Dshader-compiler`, `-Dshader-cross-compiler`, and
`-Ddxil-compiler`.

SDL_GPU should select D3D12 when the build provides installed DXIL shaders.

## Linux

On Arch Linux, install:

```sh
sudo pacman -S sdl3 sdl3_ttf sdl3_mixer shaderc vulkan-headers vulkan-loader
```

Also install a working Mesa or proprietary Vulkan driver for your GPU. Other
Linux distributions use different package names, but the required pieces are
SDL3 development files, SDL3_ttf development files, `glslc`, Vulkan loader and
headers, SDL3_mixer development files, and a Vulkan-capable driver.

SDL_GPU should select Vulkan when the build provides installed SPIR-V shaders.
