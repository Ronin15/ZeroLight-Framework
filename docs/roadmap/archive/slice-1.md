## Slice 1: Input Routing

Goal: let modal UI, gameplay, and debug commands control which actions receive
input without broad special cases in `Engine`.

Current foundation:

- [x] `InputState` tracks held gameplay actions.
- [x] `FrameCommands` tracks one-frame commands.
- [x] `input_router.zig` defines context-oriented routing contracts.
- [x] `StatePolicy` carries the active named-action routing policy.
- [x] `StatePolicy` explicitly marks modal and opaque states that block held
      gameplay input in the active event path.
- [x] Pause and modal routing intentionally release held gameplay movement; keys
      pressed while gameplay is blocked are not synthesized on resume.
- [x] Engine logs the low-frequency gameplay-routing block transition at app
      debug scope when held movement is released.

Checklist:

- [x] Add a routing policy field to the active state policy or derive it from the
      active state stack entry.
- [x] Route SDL key events through `InputRoutingPolicy` before mutating
      `InputState` or `FrameCommands`.
- [x] Keep debug commands available unless explicitly disabled.
- [x] Ensure modal overlays can block gameplay held input.
- [x] Ensure pass-through overlays do not tunnel gameplay input through modal or
      opaque blockers in the active event path.
- [x] Release held gameplay movement when a modal policy starts blocking gameplay.
- [x] Add tests for gameplay-only, modal UI, pass-through overlay, and debug
      command behavior.
- [x] Update README input guidance after behavior is wired.

Acceptance checks:

- [x] A gameplay state still receives WASD movement by default.
- [x] A modal state can prevent gameplay movement from being latched underneath.
- [x] A pass-through overlay above a modal state still leaves gameplay movement
      blocked.
- [x] F2 debug overlay toggle still works while gameplay is active.
- [x] `zig build test` covers routing behavior without opening a window.

