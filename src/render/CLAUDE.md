# src/render

- Game and app code use the `Renderer` facade. Never import `src/render/gpu/*`
  outside the render/platform boundary (CS § Zig Style).
- SDL_GPU resource lifetimes: pair every creation with its release at the
  owning site, `errdefer` partial init, never hold the swapchain texture
  across substantial CPU prep, and skip a frame deterministically when
  swapchain acquire fails (CS § Resources And Error Handling;
  `docs/rendering-assets-shaders.md`).
- Shader/host sync: a GLSL resource or layout change follows
  `docs/rendering-assets-shaders.md` § Adding A Shader (binding sets,
  `msl_entry_signature`), and host constants that size shader arrays stay
  test-tied to the GLSL (e.g. `layer_offsets` vs
  `k_max_tilemap_window_layers`).
- Presentation pools that no simulation reads (particles, text labels) may be
  fixed-capacity with deterministic overflow drop (CS § Budgets, Capacities,
  And Thresholds).
- No per-draw lookup, validation, or allocation (CS § Dispatch And Lookup).
