#!/usr/bin/env python3
"""Lint Zig sources for idiom/currency regressions.

Enforces a small set of high-signal, low-false-positive rules so the properties
that make this codebase idiomatic stay guaranteed by the build rather than by
reviewer diligence:

1. Current standard-library spellings (no deprecated/removed aliases).
2. snake_case struct fields and function parameters (Zig names non-callables
   snake_case); no C++-style camelCase `kFoo` constants.
3. `catch unreachable` / `orelse unreachable` only where it cannot swallow a
   recoverable failure into ReleaseFast UB: on a sanctioned generational-handle
   constructor, inside a `test` block (not shipped), or with an explicit
   `// lint:allow catch-unreachable: <reason>` justification at the site.

Run via `zig build idiom-lint` (also part of `zig build verify`).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"

# Fallible constructors that fail only on inputs already guarded at every call
# site (index == maxInt / generation == 0), so `X.init(...) catch unreachable`
# is provably infallible by construction. Keep this list in sync with the
# generational-handle types; adding a new one is a deliberate, reviewed change.
HANDLE_CTOR = re.compile(
    r"\b(?:TextureId|FontId|TextTextureId|EntityId|LeaseHandle)\.init\s*\("
)
CATCH_UNREACHABLE = re.compile(r"\b(?:catch|orelse)\s+unreachable\b")
ALLOW_ANNOTATION = "lint:allow catch-unreachable"

# (pattern, message). Matched against comment-stripped code only.
FORBIDDEN_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"\bstd\.ArrayListUnmanaged\b"),
        "std.ArrayListUnmanaged is the deprecated alias; use std.ArrayList (init `= .empty`)",
    ),
    (
        re.compile(r"\busingnamespace\b"),
        "usingnamespace is removed in Zig 0.16; use explicit declaration imports",
    ),
    (
        re.compile(r"\bstd\.mem\.(?:copy|set)\s*\("),
        "std.mem.copy/set are removed; use @memcpy/@memset",
    ),
    (
        re.compile(r"\bstd\.BoundedArray\b"),
        "std.BoundedArray is removed; use a fixed array + len or std.ArrayList",
    ),
    (
        re.compile(r"\b(?:pub\s+)?const\s+k[A-Z][A-Za-z0-9]*\b"),
        "C++-style camelCase `k` constant; use k_snake_case to match the codebase convention",
    ),
]

# A struct field or function parameter declared camelCase (`ident: Type`). Zig
# names fields/vars snake_case; callables stay camelCase but are never declared
# with a leading `ident:` type annotation. Function-pointer-typed fields (type
# contains `fn (`) are exempt: naming them for the callable they store is a
# defensible convention and flagging them would push toward snake_case function
# names. Data fields/params (e.g. `assetStore: AssetStore`) are still caught.
CAMEL_FIELD_OR_PARAM = re.compile(r"^\s*([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)\s*:")
FN_POINTER_TYPE = re.compile(r"\bfn\s*\(")

TEST_DECL = re.compile(r"^test\b")


def strip_line_comment(line: str) -> str:
    idx = line.find("//")
    return line if idx < 0 else line[:idx]


def lint_file(path: Path) -> list[tuple[str, int, str, str]]:
    issues: list[tuple[str, int, str, str]] = []
    rel = str(path.relative_to(REPO_ROOT))
    in_test = False
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        code = strip_line_comment(raw)

        # Track top-level `test` blocks. `zig fmt` closes top-level decls with a
        # `}` in column 0, so this state machine is exact for formatted sources.
        if TEST_DECL.match(raw):
            in_test = True
        elif raw.startswith("}"):
            in_test = False

        for pattern, message in FORBIDDEN_PATTERNS:
            if pattern.search(code):
                issues.append((rel, lineno, message, raw.strip()))

        camel = CAMEL_FIELD_OR_PARAM.match(code)
        if camel:
            after_colon = code.split(":", 1)[1]
            if not FN_POINTER_TYPE.search(after_colon):
                issues.append(
                    (rel, lineno, f"camelCase field/parameter `{camel.group(1)}`; Zig fields/params use snake_case", raw.strip())
                )

        if CATCH_UNREACHABLE.search(code):
            allowed = in_test or HANDLE_CTOR.search(code) or ALLOW_ANNOTATION in raw
            if not allowed:
                issues.append(
                    (
                        rel,
                        lineno,
                        "`catch/orelse unreachable` can swallow a recoverable failure into ReleaseFast UB; "
                        "use a sanctioned handle constructor, propagate the error, or annotate "
                        "`// lint:allow catch-unreachable: <reason>`",
                        raw.strip(),
                    )
                )
    return issues


def main() -> None:
    if not SRC_DIR.is_dir():
        print(f"idiom-lint: source directory not found: {SRC_DIR}", file=sys.stderr)
        raise SystemExit(1)

    files = sorted(SRC_DIR.rglob("*.zig"))
    issues: list[tuple[str, int, str, str]] = []
    for path in files:
        issues.extend(lint_file(path))

    if issues:
        for rel, lineno, message, snippet in issues:
            print(f"{rel}:{lineno}: {message}\n    {snippet}", file=sys.stderr)
        print(f"\nidiom-lint: {len(issues)} issue(s) across {len(files)} files", file=sys.stderr)
        raise SystemExit(1)

    print(f"idiom-lint: {len(files)} Zig sources clean")


if __name__ == "__main__":
    main()
