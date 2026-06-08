# Setup

This project expects system SDL3 libraries and local shader tools. Zig package
dependencies are intentionally empty in `build.zig.zon`.

## Required Tools

- Zig 0.16.0 or a compatible 0.16.x build
- SDL3 development headers and library
- SDL3_ttf development headers and library
- SDL3_mixer development headers and library
- `glslc` for GLSL to SPIR-V compilation
- `spirv-cross` on macOS for SPIR-V to Metal shader conversion

The app uses core SDL3 PNG loading through `SDL_LoadPNG`; it does not require
`SDL3_image`.

## macOS

With Homebrew, install:

```sh
brew install sdl3 sdl3_ttf sdl3_mixer shaderc spirv-cross
```

SDL_GPU should select Metal when the build provides installed MSL shaders.

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
